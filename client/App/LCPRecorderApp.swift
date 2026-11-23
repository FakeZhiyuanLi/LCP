import AppKit
import Combine
import SwiftUI

/// The production menu bar host for the LCP recorder.
///
/// The recorder deliberately owns all microphone and file-finalization work.
/// This app only provides the small menu bar surface used to start and stop a
/// local recording. Syncthing is responsible for transporting the resulting
/// files to the server.
@main
@MainActor
struct LCPRecorderApp: App {
    @NSApplicationDelegateAdaptor(RecorderApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RecorderMenuView(model: appDelegate.model)
        } label: {
            if let recorder = appDelegate.model.recorder {
                RecorderMenuBarLabel(recorder: recorder)
            } else {
                Label("LCP", systemImage: "exclamationmark.triangle")
                    .help(appDelegate.model.initializationError ?? "The recorder could not initialize")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class RecorderApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = RecorderAppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.capture?.deferApplicationTermination() == true ? .terminateLater : .terminateNow
    }
}

@MainActor
private final class RecorderAppModel: ObservableObject {
    let capture: CaptureCoordinator?
    let recorder: AudioRecorder?
    let initializationError: String?

    @Published var isStarting = false
    @Published private(set) var availableClasses: [CaptureDestination]
    @Published private(set) var selectedCourse = ""
    @Published private(set) var manifestError: String?
    @Published private(set) var classesAreUsable = false
    private var subscriptions = Set<AnyCancellable>()

    var canStartRecording: Bool {
        guard classesAreUsable,
              capture?.state == .idle,
              let recorder,
              !recorder.isRecording,
              !recorder.isFinishing,
              !recorder.isMonitoring,
              !isStarting,
              recorder.courseCode == selectedCourse,
              IngestManager.isValidCourseCode(recorder.courseCode) else {
            return false
        }
        return availableClasses.contains { $0.courseCode == selectedCourse }
    }

    init(classManifestStore: ClassManifestStore = ClassManifestStore()) {
        availableClasses = []

        do {
            let live = CaptureConfiguration.live
            let capture = try CaptureCoordinator(configuration: CaptureConfiguration(
                stagingDirectory: live.stagingDirectory, catalogURL: classManifestStore.manifestURL,
                leaseURL: live.leaseURL, legacyBundleURLs: live.legacyBundleURLs
            ))
            self.capture = capture
            self.recorder = capture.engine
            initializationError = nil
        } catch {
            capture = nil
            recorder = nil
            initializationError = error.localizedDescription
        }

        refreshClasses()
        capture?.$statusMessage.sink { [weak self] in self?.manifestError = $0 }.store(in: &subscriptions)
        capture?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    func start() {
        guard canStartRecording, let capture else { return }

        isStarting = true
        Task { @MainActor [weak self, weak capture] in
            guard let self, let capture else { return }
            defer { self.isStarting = false }
            do {
                try await capture.start(destinationID: self.selectedCourse)
            } catch {
                // AudioRecorder publishes the localized error for the view.
                // Keep the catch so the task always clears its busy state.
            }
        }
    }

    func stop() {
        capture?.stop()
    }

    func startMonitoring() throws { try capture?.startMonitoring() }
    func stopMonitoring() { capture?.stopMonitoring() }

    /// Reloads the server-published local snapshot. This intentionally reads
    /// only a local file; Google Drive access belongs to the server/sync side.
    func refreshClasses() {
        if let capture {
            capture.reloadDestinations()
            let classes = capture.destinations
            availableClasses = classes
            manifestError = capture.statusMessage
            classesAreUsable = capture.catalogIsUsable

            let stillSelected = classes.contains { $0.courseCode == selectedCourse }
            // Never alter the course attached to an active recording.
            // If Drive removes that class during a recording, canStartRecording
            // remains false after stop until the user selects a current entry.
            // When the previous selection is absent (including first launch),
            // leave the picker empty so a keyboard shortcut cannot silently
            // file a lecture under the first alphabetical class.
            if recorder?.isRecording != true {
                let course = stillSelected ? selectedCourse : ""
                selectCourse(course)
            }
        }
    }

    func selectCourse(_ selection: String) {
        guard recorder?.isRecording != true, recorder?.isFinishing != true, !isStarting,
              selection.isEmpty || availableClasses.contains(where: { $0.courseCode == selection }) else {
            return
        }
        selectedCourse = selection
        recorder?.courseCode = selection
    }
}

@MainActor
private struct RecorderMenuBarLabel: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        Label {
            Text(recorder.isFinishing ? "Saving…" : (recorder.isRecording ? elapsedTime(recorder.duration) : "LCP"))
                .monospacedDigit()
        } icon: {
            Image(systemName: recorder.isFinishing ? "hourglass" : (recorder.isRecording ? "record.circle.fill" : "mic.fill"))
        }
        .help(recorder.isFinishing ? "Saving lecture recording" : (recorder.isRecording ? "Lecture recording in progress" : "Open Lecture Capture"))
    }
}

@MainActor
private struct RecorderMenuView: View {
    @ObservedObject var model: RecorderAppModel

    var body: some View {
        if let recorder = model.recorder {
            RecorderControls(
                recorder: recorder,
                model: model,
                isStarting: $model.isStarting,
                onStart: model.start,
                onStop: model.stop
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label("LCP Recorder", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(model.initializationError ?? "The recorder could not initialize.")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Text("Quit and relaunch after fixing the configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                QuitButton()
            }
            .padding()
            .frame(width: 340)
        }
    }
}

@MainActor
private struct RecorderControls: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var model: RecorderAppModel
    @Binding var isStarting: Bool

    let onStart: () -> Void
    let onStop: () -> Void

    @State private var panel: Panel = .recorder
    @State private var pendingMicCheck: UUID?

    private enum Panel {
        case recorder, diagnostics
    }

    private var microphoneIsAvailable: Bool {
        if recorder.selectedMicrophoneID.isEmpty { return recorder.defaultMicrophoneName != nil }
        return recorder.microphoneDevices.contains { $0.id == recorder.selectedMicrophoneID }
    }

    private var selectedMicrophoneName: String {
        if recorder.selectedMicrophoneID.isEmpty {
            return recorder.defaultMicrophoneName ?? "No system input"
        }
        return recorder.microphoneDevices.first { $0.id == recorder.selectedMicrophoneID }?.name
            ?? "Selected microphone unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: recorder.isFinishing ? "hourglass" : (recorder.isRecording ? "record.circle.fill" : "mic.fill"))
                    .foregroundStyle(recorder.isRecording ? .red : .primary)
                Text("Lecture Capture")
                    .font(.headline)
                Spacer(minLength: 8)
                if recorder.isFinishing {
                    Text("Saving…").foregroundStyle(.secondary)
                } else if recorder.isRecording {
                    Text(elapsedTime(recorder.duration))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }

            Picker("View", selection: $panel) {
                Text("Recorder").tag(Panel.recorder)
                Text("Diagnostics").tag(Panel.diagnostics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if panel == .recorder {
                recorderPanel
            } else {
                diagnosticsPanel
            }

            HStack {
                Button(action: onStart) {
                    Label(isStarting ? "Requesting access…" : "Start recording", systemImage: "record.circle")
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(
                    recorder.isRecording
                        || recorder.isFinishing
                        || recorder.isMonitoring
                        || isStarting
                        || pendingMicCheck != nil
                        || !microphoneIsAvailable
                        || !model.canStartRecording
                )

                Button(action: onStop) {
                    Label(recorder.isFinishing ? "Saving…" : "Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!recorder.isRecording || recorder.isFinishing)
            }

            if let error = recorder.errorMessage ?? (panel == .recorder ? model.manifestError : nil) {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()
            QuitButton()
                .disabled(isStarting || pendingMicCheck != nil)
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            model.refreshClasses()
            recorder.refreshMicrophones()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                model.refreshClasses()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                recorder.refreshMicrophones()
            }
        }
    }

    private var recorderPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Class", selection: Binding(
                get: { model.selectedCourse },
                set: { model.selectCourse($0) }
            )) {
                Text(model.availableClasses.isEmpty ? "No classes available…" : "Choose a class…")
                    .tag("")
                ForEach(model.availableClasses) { entry in
                    Text(entry.name).tag(entry.courseCode)
                }
            }
            .pickerStyle(.menu)
            .disabled(recorder.isRecording || recorder.isFinishing || isStarting || !model.classesAreUsable)

            HStack {
                Text("Classes sync from Google Drive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh", action: model.refreshClasses)
                    .buttonStyle(.borderless)
                    .disabled(recorder.isRecording || isStarting)
            }

            Picker("Microphone", selection: Binding(
                get: { recorder.selectedMicrophoneID },
                set: { recorder.selectMicrophone($0) }
            )) {
                Text(recorder.defaultMicrophoneName.map { "System Default (\($0))" } ?? "System Default").tag("")
                if !recorder.selectedMicrophoneID.isEmpty && !microphoneIsAvailable {
                    Text("Selected microphone unavailable").tag(recorder.selectedMicrophoneID)
                }
                ForEach(recorder.microphoneDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(recorder.isRecording || recorder.isFinishing || recorder.isMonitoring || isStarting || pendingMicCheck != nil)

            if !microphoneIsAvailable && !recorder.isRecording {
                Label("Reconnect the microphone or choose another input.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if recorder.isRecording {
                Text("Recording \(recorder.courseCode) · \(recorder.activeMicrophoneName ?? selectedMicrophoneName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(!model.classesAreUsable
                    ? "Waiting for the synced Google Drive class list."
                    : (model.selectedCourse.isEmpty
                        ? "Choose a class before recording."
                        : "Files: ~/Lectures/Incoming"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Text(recorder.activeMicrophoneName ?? selectedMicrophoneName)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Microphone", systemImage: "mic")
            }
            .font(.subheadline)

            if !recorder.isFinishing && (recorder.isRecording || recorder.isMonitoring) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    AudioLevelMeter(levels: recorder.sampleAudioLevels())
                }
            } else {
                AudioLevelMeter(levels: nil)
            }

            if recorder.isFinishing {
                Text("Finishing the recording…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if recorder.isRecording {
                Label("Live · \(recorder.courseCode)", systemImage: "record.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if recorder.isMonitoring {
                HStack {
                    Label("Mic check · audio isn’t saved", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("End mic check", action: model.stopMonitoring)
                }
            } else {
                HStack {
                    Text(microphoneIsAvailable ? "Check your levels before recording." : "Choose an available mic in Recorder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(pendingMicCheck == nil ? "Start mic check" : "Requesting access…") {
                        pendingMicCheck = UUID()
                    }
                    .disabled(isStarting || pendingMicCheck != nil || !microphoneIsAvailable)
                }
            }
        }
        .task(id: pendingMicCheck) {
            guard let request = pendingMicCheck else { return }
            defer {
                if pendingMicCheck == request { pendingMicCheck = nil }
            }
            guard await recorder.requestPermission(),
                  !Task.isCancelled,
                  pendingMicCheck == request,
                  panel == .diagnostics,
                  !recorder.isRecording,
                  !recorder.isFinishing,
                  !isStarting else { return }
            do {
                try model.startMonitoring()
            } catch {
                // AudioRecorder publishes a localized error.
            }
        }
        .onDisappear {
            pendingMicCheck = nil
            model.stopMonitoring()
        }
    }
}

@MainActor
private struct QuitButton: View {
    var body: some View {
        Button("Quit LCP Recorder") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}

private func elapsedTime(_ duration: TimeInterval) -> String {
    let seconds = Int(max(0, duration))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

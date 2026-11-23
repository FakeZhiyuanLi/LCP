import SwiftUI
import AppKit
import LCPClient
import LCPContextCore

struct CaptureWorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        let groups = model.visibleClassGroups.filter { !$0.classes.isEmpty }
        let classes = groups.flatMap(\.classes)
        let activeClassID = model.capture?.activeSession?.academicClassID ?? model.captureClassID
        let selected = model.captureInProgress
            ? model.state.classes.first { $0.id == activeClassID }
            : classes.first { $0.id == model.captureClassID } ?? (classes.count == 1 ? classes.first : nil)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Capture").workspacePageTitle()
                if model.captureInProgress {
                    if let selected {
                        LabeledContent("Class", value: selected.displayLabel)
                    }
                } else if !classes.isEmpty {
                    Picker("Class", selection: Binding(get: { selected?.id }, set: { model.captureClassID = $0 })) {
                        if classes.count > 1 { Text("Choose a class").tag(nil as UUID?) }
                        ForEach(groups) { group in
                            Section(group.title) {
                                ForEach(group.classes) { course in
                                    Text([course.displayLabel, course.section].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .tag(Optional(course.id))
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 420, alignment: .leading)
                }
                if let selected {
                    ClassCaptureView(model: model, enrollment: selected).id(selected.id)
                } else if model.captureInProgress, let capture = model.capture {
                    CaptureMenuItems(capture: capture)
                } else if classes.isEmpty {
                    ContentUnavailableView {
                        Label("No classes to record", systemImage: "mic")
                    } description: {
                        Text("Add a class to record a lecture.")
                    } actions: {
                        Button("New Class…") { model.presentedEditor = .newClass }
                    }
                }
            }
            .workspacePage()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Capture")
    }
}

struct ClassCaptureView: View {
    @ObservedObject var model: WorkspaceModel
    let enrollment: ClassEnrollment
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record a lecture").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let capture = model.capture {
                CaptureControls(model: model, capture: capture, enrollment: enrollment)
            } else {
                Button("Initialize Local Capture") { model.initializeCapture() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.initializeCapture() }
    }
}

private struct CaptureControls: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var capture: CaptureCoordinator
    let enrollment: ClassEnrollment
    // A nil selection records into the academic class on this Mac.
    @State private var destinationID: String?

    init(model: WorkspaceModel, capture: CaptureCoordinator, enrollment: ClassEnrollment) {
        self.model = model
        self.capture = capture
        self.enrollment = enrollment
        _destinationID = State(initialValue: enrollment.recordingDestination?.exactCourseCode)
    }

    private var busy: Bool { [.requestingPermission, .recording, .finalizing].contains(capture.state) }
    private var destination: CaptureDestination? { capture.destinations.first { $0.id == destinationID } }
    private var selectedMapping: RecordingDestination? {
        guard let destination, let folder = destination.driveFolderID, !folder.isEmpty else { return nil }
        return RecordingDestination(driveFolderID: folder, exactCourseCode: destination.courseCode)
    }
    private var mappingIssue: String? {
        guard destinationID != nil else { return nil }
        guard capture.catalogIsUsable else { return capture.catalogIssue ?? "Refresh the recording catalog to use a synced destination." }
        guard let selectedMapping else { return "This synced destination is unavailable. Choose another destination or refresh the catalog." }
        if selectedMapping != enrollment.recordingDestination {
            return "Save this mapping to record to the selected synced folder."
        }
        return nil
    }
    private var localCatalogBlock: Bool {
        destinationID == nil && capture.catalogIssue != nil && capture.statusMessage == capture.catalogIssue && capture.compatibilityIssue == nil
    }
    private var canStart: Bool {
        !model.restorePending && !busy && capture.compatibilityIssue == nil && mappingIssue == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(localCatalogBlock && capture.state == .blocked ? "Idle" : capture.state.displayName,
                      systemImage: capture.state == .recording ? "record.circle.fill" : "mic")
                    .font(.headline).foregroundStyle(capture.state == .recording ? Color.red : Color.primary)
                Spacer()
                Text(formatDuration(capture.duration)).monospacedDigit().font(.title2)
            }
            if let session = capture.activeSession {
                LabeledContent("Recording Destination", value: session.destination.name)
            } else {
                Picker("Recording Destination", selection: $destinationID) {
                    Text("\(enrollment.shortLabel) · On this Mac").tag(nil as String?)
                    if let destinationID, destination == nil {
                        Text("\(destinationID) · Unavailable").tag(Optional(destinationID))
                    }
                    if !capture.destinations.isEmpty {
                        Section("Synced folders") {
                            ForEach(capture.destinations) { destination in
                                Text(destination.name).tag(Optional(destination.id))
                            }
                        }
                    }
                }
                .disabled(busy)
                Text(destinationID == nil
                     ? "Save audio on this Mac in this class’s Lectures. Choose a synced folder to send recordings for transcription."
                     : "Send recordings to the lecture server using this synced folder.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack {
                    if destinationID != nil && selectedMapping != enrollment.recordingDestination {
                        Button("Save Mapping") { updateMapping(selectedMapping) }
                            .disabled(busy || !capture.catalogIsUsable || selectedMapping == nil)
                            .accessibilityLabel("Save recording destination mapping for \(enrollment.shortLabel)")
                    } else if destinationID == nil && enrollment.recordingDestination != nil {
                        Button("Make Local Recording the Default") { updateMapping(nil) }.disabled(busy)
                    }
                    Spacer()
                    Button("Refresh Catalog") { capture.reloadDestinations() }.disabled(busy)
                }
            }
            if !busy, let issue = capture.compatibilityIssue ?? mappingIssue ?? (localCatalogBlock ? nil : capture.statusMessage) {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if capture.state == .recording {
                Button("Stop and Finalize", systemImage: "stop.fill") { capture.stop() }.buttonStyle(.borderedProminent).tint(.red)
            } else if capture.state == .finalizing {
                ProgressView("Saving recording…")
            } else {
                Button("Start Recording", systemImage: "record.circle") { start() }
                    .buttonStyle(.borderedProminent).disabled(!canStart)
                    .accessibilityLabel("Start recording for \(enrollment.shortLabel)")
            }
        }
        .padding(16).workspacePanel()
        .onChange(of: enrollment.recordingDestination) { _, saved in destinationID = saved?.exactCourseCode }
    }

    private func updateMapping(_ mapping: RecordingDestination?) {
        model.mutate { state in
            guard let index = state.classes.firstIndex(where: { $0.id == enrollment.id }),
                  state.classes[index].recordingDestination == enrollment.recordingDestination else {
                throw DesktopUIError.message("This class’s recording destination changed. Review its current mapping and try again.")
            }
            state.classes[index].recordingDestination = mapping
        }
    }

    private func start() {
        guard canStart else { return }
        let chosenID = destinationID
        let folder = selectedMapping?.driveFolderID
        Task { @MainActor in
            guard !model.restorePending, !model.captureInProgress,
                  let course = model.state.classes.first(where: { $0.id == enrollment.id }) else { return }
            model.captureClassID = course.id
            do {
                if let chosenID {
                    guard let folder, course.recordingDestination == RecordingDestination(driveFolderID: folder, exactCourseCode: chosenID) else {
                        throw DesktopUIError.message("Review and save the current synced destination before starting.")
                    }
                    try await capture.start(destinationID: chosenID, academicClassID: course.id, expectedDriveFolderID: folder)
                } else {
                    try await capture.startLocal(academicClassID: course.id, className: course.shortLabel,
                                                 recordingsDirectory: model.rootURL.appendingPathComponent("Recordings", isDirectory: true))
                }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct DesktopMenuBarView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open LCP", systemImage: "macwindow") { if let delegate = DesktopAppDelegate.active { delegate.showWorkspace() } else { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) } }
        Divider()
        if let enrollment = model.selectedClass {
            Button("New Study Note for \(enrollment.shortLabel)…", systemImage: "square.and.pencil") { showLog(for: enrollment.id) }
        } else {
            Menu("New Study Note", systemImage: "square.and.pencil") {
                ForEach(model.visibleClasses) { enrollment in
                    Button(enrollment.displayLabel) { showLog(for: enrollment.id) }
                }
            }.disabled(model.visibleClasses.isEmpty)
        }
        Button("Open Capture", systemImage: "mic") { model.openCapture() }
        if let capture = model.capture { CaptureMenuItems(capture: capture) }
        Divider()
        SettingsLink { Label("Settings…", systemImage: "gearshape") }
        Button("Back Up Library…", systemImage: "externaldrive") { model.exportBackup() }
        Divider()
        Button("Quit LCP") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func showLog(for classID: UUID) {
        model.inWorkspace("Log Class Context") {
            model.selection = .classDetail(classID)
            model.presentedEditor = .newActivity
        }
    }
}
private struct CaptureMenuItems: View {
    @ObservedObject var capture: CaptureCoordinator
    var body: some View {
        if capture.state == .recording {
            Text("Recording · \(formatDuration(capture.duration))")
            Button("Stop and Finalize Recording", systemImage: "stop.fill") { capture.stop() }
        } else {
            Text(capture.state.displayName)
        }
        if let message = capture.statusMessage { Text(message) }
    }
}
private extension CaptureState {
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .requestingPermission: "Waiting for microphone access"
        case .recording: "Recording"
        case .finalizing: "Saving recording…"
        case .blocked: "Capture needs attention"
        }
    }
}
func formatDuration(_ time: TimeInterval) -> String {
    guard time.isFinite, time < Double(Int.max) else { return "Unknown time" }
    let seconds = Int(max(0, time))
    return String(format: "%02lld:%02lld", Int64(seconds / 60), Int64(seconds % 60))
}

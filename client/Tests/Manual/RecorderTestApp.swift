import AppKit
import SwiftUI

/// A manual test host for the Stage 1 engine, separate from the production app.
@main
@MainActor
struct RecorderTestApp: App {
    @NSApplicationDelegateAdaptor(RecorderTestDelegate.self) private var appDelegate
    private var host: RecorderTestHost { appDelegate.host }

    var body: some Scene {
        MenuBarExtra {
            if let recorder = host.recorder {
                RecorderTestControls(recorder: recorder)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LCP Recorder Test").font(.headline)
                    Text(host.initializationError ?? "Recorder initialization failed.")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                .padding()
                .frame(width: 340)
            }
        } label: {
            if let recorder = host.recorder {
                RecorderTestLabel(recorder: recorder)
            } else {
                Label("LCP Test", systemImage: "exclamationmark.triangle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class RecorderTestDelegate: NSObject, NSApplicationDelegate {
    let host = RecorderTestHost()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        host.recorder?.deferApplicationTermination() == true ? .terminateLater : .terminateNow
    }
}

@MainActor
private final class RecorderTestHost: ObservableObject {
    let recorder: AudioRecorder?
    let initializationError: String?

    init() {
        do {
            // Keep manual fixtures out of the production Syncthing folder and
            // production worker vault. The test transport is configured for
            // this separate path (`lecture-test-inbox`).
            let testDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Lectures", isDirectory: true)
                .appendingPathComponent("TestIncoming", isDirectory: true)
            let recorder = try AudioRecorder(
                ingestManager: IngestManager(stagingDirectory: testDirectory)
            )
            recorder.courseCode = "LCPTEST"
            self.recorder = recorder
            initializationError = nil
        } catch {
            recorder = nil
            initializationError = error.localizedDescription
        }
    }
}

@MainActor
private struct RecorderTestLabel: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        Label {
            Text(recorder.isRecording ? elapsedTime(recorder.duration) : "LCP Test")
                .monospacedDigit()
        } icon: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "mic.fill")
        }
    }
}

@MainActor
private struct RecorderTestControls: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var isStarting = false
    @State private var startError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LCP Recorder Test").font(.headline)
            TextField("Course code", text: $recorder.courseCode)
                .disabled(recorder.isRecording || isStarting)
            Text(recorder.isRecording ? "Recording: \(elapsedTime(recorder.duration))" : "Stopped: \(elapsedTime(recorder.duration))")
                .monospacedDigit()

            HStack {
                Button(isStarting ? "Requesting access…" : "Start") {
                    isStarting = true
                    startError = nil
                    Task { @MainActor in
                        defer { isStarting = false }
                        guard await recorder.requestPermission() else { return }
                        do {
                            try recorder.startRecording()
                        } catch {
                            startError = error.localizedDescription
                        }
                    }
                }
                .disabled(recorder.isRecording || isStarting)

                Button(recorder.isFinishing ? "Saving…" : "Stop") { recorder.stopRecording() }
                    .disabled(!recorder.isRecording || recorder.isFinishing)
            }

            if let message = startError ?? recorder.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Text("Files: ~/Lectures/TestIncoming")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .disabled(isStarting)
        }
        .padding()
        .frame(width: 340)
    }
}

private func elapsedTime(_ duration: TimeInterval) -> String {
    let seconds = Int(max(0, duration))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

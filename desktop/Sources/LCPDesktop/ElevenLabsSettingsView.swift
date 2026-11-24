import SwiftUI

struct ElevenLabsSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var apiKey = ""
    @State private var status = ""
    @State private var hasKey = false
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Local transcription") {
                Text("Add your own ElevenLabs API key to transcribe finalized lecture audio from this Mac. LCP stores the transcript in the selected library and keeps it available offline.")
                SecureField("ElevenLabs API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                HStack {
                    Button(hasKey ? "Replace and Test Key" : "Test and Save Key") { saveKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Button("Remove Key", role: .destructive) { removeKey() }
                            .disabled(isWorking)
                    }
                    if isWorking { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("What this does") {
                Label("Audio is sent to ElevenLabs when you choose Transcribe Locally for a lecture.", systemImage: "arrow.up.right")
                Label("The parsed transcript is saved in this library and can be used by class context and chat.", systemImage: "internaldrive")
                Label("This setting does not upload audio or transcripts to Google Drive.", systemImage: "lock.shield")
            }
            Section("Privacy and cost") {
                Text("The API key stays in the Mac Keychain and is excluded from backups, exports, agent grants, and diagnostics. ElevenLabs may charge for each transcription according to your account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadStatus() }
    }

    private func loadStatus() {
        let credentials = ElevenLabsCredentials.forLibrary(model.rootURL)
        Task { @MainActor in
            do {
                hasKey = try await credentials.hasAPIKeyAsync()
                if hasKey { status = "An ElevenLabs key is saved in this Mac's Keychain." }
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func saveKey() {
        guard !isWorking else { return }
        isWorking = true
        status = "Testing the key without sending class audio…"
        let credentials = ElevenLabsCredentials.forLibrary(model.rootURL)
        let candidate = apiKey
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await credentials.checkAndSave(candidate)
                apiKey = ""
                hasKey = true
                status = "ElevenLabs is connected. Local transcription is ready."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func removeKey() {
        guard !isWorking else { return }
        isWorking = true
        let credentials = ElevenLabsCredentials.forLibrary(model.rootURL)
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await credentials.removeAsync()
                hasKey = false
                status = "ElevenLabs is disconnected."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

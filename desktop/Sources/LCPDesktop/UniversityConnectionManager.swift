import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LCPContextServices

enum UniversityConnectionStatus: Equatable {
    case unavailable, needsClient, disconnected, saved, verified(Date), checkFailed, manual

    @MainActor static func read(_ service: UniversitySource, credentials: UniversityCredentials) -> Self {
        do {
            if let kind = service.googleKind {
                guard try credentials.hasGoogleClient() else { return .needsClient }
                guard try credentials.isGoogleConnected(kind) else { return .disconnected }
            } else if service == .canvas {
                guard try credentials.hasCanvasToken() else { return .disconnected }
            } else { return .manual }
            return credentials.lastCheck(for: service) ?? .saved
        } catch { return .unavailable }
    }

    @MainActor static func readAsync(_ service: UniversitySource, credentials: UniversityCredentials) async -> Self {
        do {
            if let kind = service.googleKind {
                guard try await credentials.hasGoogleClientAsync() else { return .needsClient }
                guard try await credentials.isGoogleConnectedAsync(kind) else { return .disconnected }
            } else if service == .canvas {
                guard try await credentials.hasCanvasTokenAsync() else { return .disconnected }
            } else { return .manual }
            return credentials.lastCheck(for: service) ?? .saved
        } catch { return .unavailable }
    }

    var label: String {
        switch self {
        case .unavailable: "Keychain unavailable"
        case .needsClient: "Setup required"
        case .disconnected: "Not connected"
        case .saved: "Sign-in saved"
        case .verified: "Verified"
        case .checkFailed: "Check failed"
        case .manual: "Manual import"
        }
    }

    var isConfigured: Bool {
        switch self {
        case .saved, .verified, .checkFailed: true
        default: false
        }
    }
}

@MainActor
struct UniversityConnectionManager: View {
    let service: UniversitySource
    @ObservedObject var model: WorkspaceModel
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status = UniversityConnectionStatus.disconnected
    @State private var token = ""
    @State private var choosingClient = false
    @State private var folderCreationEnabled = false
    @State private var requestFolderCreation = true
    @State private var feedback: String?
    @State private var working: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var refreshTask: Task<Void, Never>?

    private var credentials: UniversityCredentials { .forLibrary(model.rootURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.rawValue).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(status.label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if status == .unavailable {
                    Text("Unlock your Mac Keychain to manage this connection.")
                    Button("Try Again") { refresh(); onChange() }
                } else if status == .manual {
                    Text("Open University Services in a class to import a campus resource.")
                } else {
                    if status.isConfigured {
                        if case let .verified(date) = status {
                            Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened)).")
                        } else {
                            Text("Check whether \(service.rawValue) accepts the saved sign-in.")
                        }
                        HStack {
                            Button("Check Connection") {
                                run("Checking connection…") { try await credentials.checkConnection(service) }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Disconnect", role: .destructive) { disconnect() }
                        }
                        if service == .drive {
                            Divider()
                            if folderCreationEnabled {
                                Label("Class folder creation enabled", systemImage: "checkmark.circle")
                            } else {
                                Text("LCP can link existing Drive folders. Allow folder creation to add a folder when a new class needs one.")
                                Button("Enable Folder Creation…") {
                                    signIn(.drive, enableFolders: true)
                                }
                            }
                        }
                    } else if service == .canvas {
                        Text("Create a personal access token in your UCI Canvas account settings.")
                        Link("Open Canvas Account Settings", destination: URL(string: "https://canvas.eee.uci.edu/profile/settings")!)
                        SecureField("Canvas access token", text: $token).textFieldStyle(.roundedBorder)
                        Button("Connect to Canvas") {
                            let candidate = token
                            run("Checking Canvas access…") {
                                try await credentials.checkConnection(.canvas, candidateCanvasToken: candidate)
                                token = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if let kind = service.googleKind, status == .disconnected {
                        if kind == .drive {
                            Text("Sign in to read class materials from Google Drive.")
                            Toggle("Also create folders for new classes", isOn: $requestFolderCreation)
                        } else {
                            Text("Sign in to give LCP read-only access to \(service.rawValue).")
                        }
                        Button("Sign In with Google…") {
                            signIn(kind, enableFolders: kind == .drive && requestFolderCreation)
                        }.buttonStyle(.borderedProminent)
                    }
                    if service.googleKind != nil {
                        if status != .needsClient { Divider() }
                        if status == .needsClient {
                            Text("Enable the Google APIs you use and download an OAuth client JSON for a Desktop app. Drive, Gmail and Calendar share this setup.")
                            Link("Open Google Cloud Credentials", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        } else {
                            Text("Drive, Gmail and Calendar share this OAuth client. Choosing a different client ID requires signing in again for each service.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Button(status == .needsClient ? "Choose Google Client JSON…" : "Change Google Client…") { choosingClient = true }
                    }
                }
            }
            .disabled(working != nil)
            if let working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working)
                    Spacer()
                    Button("Cancel Request") { cancel() }
                }
            }
            if let feedback {
                Label(feedback, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 460, alignment: .leading)
        .padding(24)
        .background(WorkspacePalette.canvas)
        .tint(WorkspacePalette.accent)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refresh() }
        .onDisappear { cancel(); refreshTask?.cancel(); token = "" }
        .onChange(of: model.rootURL) { _, _ in cancel(); dismiss() }
        .fileImporter(isPresented: $choosingClient, allowedContentTypes: [.json]) { result in
            let file: URL
            do { file = try result.get() }
            catch CocoaError.userCancelled { return }
            catch { feedback = error.localizedDescription; return }
            run("Saving Google client…") {
                try await credentials.configureGoogleAsync(from: file)
                feedback = nil
            }
        }
    }

    private func refresh() {
        refreshTask?.cancel()
        let service = service
        let credentials = credentials
        refreshTask = Task { @MainActor in
            let nextStatus = await UniversityConnectionStatus.readAsync(service, credentials: credentials)
            guard !Task.isCancelled else { return }
            status = nextStatus
            if service == .drive, nextStatus.isConfigured {
                do { folderCreationEnabled = try await credentials.canCreateDriveFoldersAsync() }
                catch {
                    guard !Task.isCancelled else { return }
                    status = .unavailable
                }
            } else {
                folderCreationEnabled = false
            }
            refreshTask = nil
        }
    }

    private func signIn(_ kind: GoogleUniversityKind, enableFolders: Bool) {
        run("Waiting for Google sign-in…") {
            try await credentials.signInGoogle(kind, enableDriveFolders: enableFolders)
            if kind == .drive { model.wakeDriveFolders() }
        }
    }

    private func disconnect() {
        run("Disconnecting…") {
            if let kind = service.googleKind { try await credentials.disconnectGoogleAsync(kind) }
            else { try await credentials.removeCanvasTokenAsync() }
            feedback = nil
        }
    }

    private func run(_ activity: String, perform: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        let id = UUID()
        operationID = id
        working = activity
        feedback = nil
        operation = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await perform()
            } catch {
                if !Task.isCancelled && operationID == id { feedback = error.localizedDescription }
            }
            guard operationID == id else { return }
            operation = nil
            operationID = nil
            working = nil
            refresh()
            onChange()
        }
    }

    private func cancel() {
        operation?.cancel()
        operation = nil
        operationID = nil
        working = nil
    }
}

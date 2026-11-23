import Combine
import Foundation
import LCPContextCore
import LCPContextServices

struct ChatProviders {
    var profiles: @MainActor (URL) async throws -> [AgentProviderProfile] = { root in
        try await AgentProviderCredentials.forLibrary(root).profilesListAsync()
    }
    var apiKey: @MainActor (URL, AgentProviderProfile) async throws -> String = { root, profile in
        try await AgentProviderCredentials.forLibrary(root).apiKeyAsync(for: profile)
    }
    var http = UniversityHTTP()
}

/// Drafts and running requests belong to a conversation, even while its view is closed.
@MainActor
final class ChatSession: ObservableObject {
    enum Phase { case preparing, waiting, streaming, cancelling }

    struct Generation {
        let id: UUID
        let question: String
        let providerName: String
        let filenames: [String]
        let startedAt = Date()
        var phase = Phase.preparing
        var update: AgentProviderStreamUpdate?
    }

    struct ContextSummary {
        let classLabels: [String]
        let sourceCount: Int
        let byteCount: Int
        let revision: UInt64

        init(_ context: ClassPlannerContext) {
            classLabels = context.classLabels
            sourceCount = context.sourceCount
            byteCount = context.markdown.utf8.count
            revision = context.repositoryRevision
        }
    }

    let classID: UUID?
    @Published var draft = ""
    @Published var uploads: [ChatUpload] = []
    @Published var automaticallyFileUploads = false
    @Published private(set) var loadingFiles = false
    var canSend: Bool { !loadingFiles && (!uploads.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    func attach(_ urls: [URL]) async {
        guard !urls.isEmpty, !loadingFiles, generation == nil else { return }
        guard urls.count <= ChatAttachment.maximumCount - uploads.count else {
            status = "Attach up to \(ChatAttachment.maximumCount) files per message."
            return
        }
        loadingFiles = true
        defer { loadingFiles = false }
        let remaining = ChatAttachment.maximumBytes - uploads.reduce(0) { $0 + Int($1.attachment.original.byteCount) }
        do {
            let added = try await Task.detached(priority: .userInitiated) { [remaining] in
                var budget = remaining
                var result: [ChatUpload] = []
                for url in urls {
                    let file = try ChatUpload.read(url, remainingBytes: budget)
                    budget -= Int(file.attachment.original.byteCount)
                    result.append(file)
                }
                return result
            }.value
            uploads.append(contentsOf: added)
            status = nil
            errorDetails = nil
        } catch ContextServiceError.fileTooLarge {
            status = "Attachments can total up to 32 MiB per message."
        } catch { status = error.localizedDescription }
    }
    @Published var selectedProfileID: UUID?
    @Published var context: ContextSummary?
    @Published var status: String?
    @Published var errorDetails: String?
    @Published private(set) var generation: Generation?
    private var task: Task<Void, Never>?

    init(classID: UUID?) { self.classID = classID }

    func classIDs(in model: WorkspaceModel) -> [UUID] {
        classID.map { [$0] } ?? model.activeClasses.map(\.id)
    }

    func send(in model: WorkspaceModel, using profile: AgentProviderProfile) {
        guard canSend, generation == nil, model.unsavedChatReplies[classID] == nil,
              !model.restorePending, let repository = model.repository else { return }
        let ids = classIDs(in: model)
        errorDetails = nil
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = uploads
        let autoFile = automaticallyFileUploads && !files.isEmpty
        let history = model.chatThread(classID: classID)?.messages ?? []
        let root = model.rootURL
        let providers = model.chatProviders
        let diagnostics = AgentRequestDiagnostics()
        let id = diagnostics.id
        generation = Generation(id: id, question: question, providerName: profile.name, filenames: files.map(\.attachment.filename))
        draft = ""
        uploads = []
        automaticallyFileUploads = false
        status = nil

        task = Task { [self, weak model] in
            defer {
                generation = nil
                task = nil
            }
            var stage = AgentRequestDiagnostics.ChatStage.credential
            do {
                await Task.yield()
                try Task.checkCancellation()
                diagnostics.chatStage(stage)
                let key = try await providers.apiKey(root, profile)
                try Task.checkCancellation()
                stage = .generation
                let result = try await ClassPlannerService(repository: repository, http: providers.http).generateChatStream(
                    classIDs: ids, history: history, message: question, profile: profile, apiKey: key,
                    uploads: files, diagnostics: diagnostics, onRequestReady: {
                        self.generation?.phase = .waiting
                    }, onUpdate: { update in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, var current = self.generation,
                                  current.id == id, current.phase != .cancelling else { return }
                            if !update.text.isEmpty { current.phase = .streaming }
                            current.update = update
                            self.generation = current
                        }
                    })
                try Task.checkCancellation()
                guard let model, model.repository === repository, model.rootURL == root else { return }
                saveReply(in: model, question: question, result: result, profile: profile, diagnostics: diagnostics,
                          automaticallyFileUploads: autoFile)
            } catch {
                draft = question
                uploads = files
                automaticallyFileUploads = autoFile
                if Task.isCancelled || error is CancellationError {
                    status = "Generation cancelled. Your message is back in the composer."
                } else {
                    let providerError = error as? AgentProviderError
                    let failedStage = stage == .generation && providerError == nil ? .context : stage
                    reportFailure(error, stage: failedStage, diagnostics: diagnostics)
                }
            }
        }
    }

    func stop() {
        guard generation != nil else { return }
        generation?.phase = .cancelling
        task?.cancel()
    }

    func saveReply(in model: WorkspaceModel, question: String, result: ClassPlanResult,
                   profile: AgentProviderProfile, diagnostics: AgentRequestDiagnostics, automaticallyFileUploads: Bool = false) {
        if model.saveChatReply(classID: classID, question: question, result: result, profile: profile, diagnostics: diagnostics,
                               automaticallyFileUploads: automaticallyFileUploads) {
            context = ContextSummary(result.context)
        }
    }

    func reportFailure(_ error: Error, stage: AgentRequestDiagnostics.ChatStage, diagnostics: AgentRequestDiagnostics) {
        let providerError = error as? AgentProviderError
        diagnostics.chatStage(stage, failed: true, error: providerError)
        status = error.localizedDescription
        errorDetails = diagnostics.supportDetails(stage: stage, error: providerError)
    }
}

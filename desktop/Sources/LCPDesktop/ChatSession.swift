import Combine
import Foundation
import LCPContextCore
import LCPContextServices

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
    /// The saved thread currently shown in the session. A nil value means the
    /// user is composing a new conversation that has not been saved yet.
    @Published private(set) var selectedThreadID: UUID?
    @Published var draft = ""
    @Published var uploads: [ChatUpload] = []
    @Published var automaticallyFileUploads = true
    @Published private(set) var loadingFiles = false
    var canSend: Bool { !loadingFiles && (!uploads.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    @discardableResult
    func attach(_ urls: [URL]) -> Task<Void, Never>? {
        guard !urls.isEmpty, !loadingFiles, generation == nil else { return nil }
        guard urls.count <= ChatAttachment.maximumCount - uploads.count else {
            status = "Attach up to \(ChatAttachment.maximumCount) files per message."
            return nil
        }
        loadingFiles = true
        let remaining = ChatAttachment.maximumBytes - uploads.reduce(0) { $0 + Int($1.attachment.original.byteCount) }
        return Task {
            defer { loadingFiles = false }
            do {
                let added = try await Task.detached(priority: .userInitiated) {
                    var budget = remaining
                    return try urls.map { url in
                        let file = try ChatUpload.read(url, remainingBytes: budget)
                        budget -= Int(file.attachment.original.byteCount)
                        return file
                    }
                }.value
                uploads.append(contentsOf: added)
                status = nil
                errorDetails = nil
            } catch ContextServiceError.fileTooLarge {
                status = "Attachments can total up to 32 MiB per message."
            } catch { status = error.localizedDescription }
        }
    }
    @Published var selectedProfileID: UUID?
    @Published var context: ContextSummary?
    @Published var status: String?
    @Published var errorDetails: String?
    @Published private(set) var generation: Generation?
    private var task: Task<Void, Never>?
    private var currentConversationID = UUID()
    private var initializedSelection = false

    private struct ConversationState {
        var draft = ""
        var uploads: [ChatUpload] = []
        var automaticallyFileUploads = true
        var context: ContextSummary?
    }

    private var conversationStates: [UUID: ConversationState] = [:]

    init(classID: UUID?) { self.classID = classID }

    /// Chooses the latest saved conversation the first time this scope is
    /// opened. Keeping this one-time guard lets a deliberately opened new chat
    /// stay selected while the repository refreshes in the background.
    func initializeSelection(from threads: [ChatThread]) {
        guard !initializedSelection else { return }
        initializedSelection = true
        if let latest = threads.filter({ $0.classID == classID }).max(by: Self.isOlder) {
            selectedThreadID = latest.id
            currentConversationID = latest.id
        }
        restoreConversationState()
    }

    private static func isOlder(_ lhs: ChatThread, than rhs: ChatThread) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func saveConversationState() {
        conversationStates[currentConversationID] = ConversationState(
            draft: draft,
            uploads: uploads,
            automaticallyFileUploads: automaticallyFileUploads,
            context: context
        )
    }

    private func restoreConversationState() {
        let state = conversationStates[currentConversationID] ?? ConversationState()
        draft = state.draft
        uploads = state.uploads
        automaticallyFileUploads = state.automaticallyFileUploads
        context = state.context
        status = nil
        errorDetails = nil
    }

    @discardableResult
    func selectExistingChat(_ threadID: UUID) -> Bool {
        guard generation == nil, !loadingFiles else { return false }
        guard threadID != selectedThreadID else { return true }
        saveConversationState()
        currentConversationID = threadID
        selectedThreadID = threadID
        restoreConversationState()
        return true
    }

    @discardableResult
    func startNewChat() -> Bool {
        guard generation == nil, !loadingFiles else { return false }
        saveConversationState()
        currentConversationID = UUID()
        selectedThreadID = nil
        restoreConversationState()
        return true
    }

    /// The ID used for the first save of a transient conversation. It becomes
    /// the persisted ChatThread ID after the first reply is committed.
    var conversationIDForSaving: UUID { currentConversationID }

    func markCurrentConversationPersisted(as threadID: UUID) {
        saveConversationState()
        if currentConversationID != threadID, let state = conversationStates[currentConversationID] {
            conversationStates[threadID] = state
            conversationStates.removeValue(forKey: currentConversationID)
        }
        currentConversationID = threadID
        selectedThreadID = threadID
    }

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
        let autoFile = automaticallyFileUploads
        let threadID = selectedThreadID
        let history = threadID.flatMap { model.chatThread(classID: classID, threadID: $0)?.messages } ?? []
        let root = model.rootURL
        let providers = model.agentProviders
        let diagnostics = AgentRequestDiagnostics()
        let id = diagnostics.id
        let local = ClassPlannerService.isLocalAcknowledgment(question, uploads: files)
        generation = Generation(id: id, question: question, providerName: local ? "LCP" : profile.name, filenames: files.map(\.attachment.filename))
        draft = ""
        uploads = []
        automaticallyFileUploads = true
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
                if !local { diagnostics.chatStage(stage) }
                let key = local ? "" : try await providers.apiKey(root, profile)
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
                          threadID: threadID,
                          automaticallyFileUploads: autoFile && !files.isEmpty)
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
                   profile: AgentProviderProfile, diagnostics: AgentRequestDiagnostics,
                   threadID: UUID? = nil, automaticallyFileUploads: Bool = false) {
        let destinationThreadID = threadID ?? conversationIDForSaving
        if model.saveChatReply(classID: classID, question: question, result: result, profile: profile, diagnostics: diagnostics,
                               threadID: destinationThreadID,
                               automaticallyFileUploads: automaticallyFileUploads) {
            context = ContextSummary(result.context)
            markCurrentConversationPersisted(as: destinationThreadID)
        }
    }

    func reportFailure(_ error: Error, stage: AgentRequestDiagnostics.ChatStage, diagnostics: AgentRequestDiagnostics) {
        let providerError = error as? AgentProviderError
        diagnostics.chatStage(stage, failed: true, error: providerError)
        status = error.localizedDescription
        errorDetails = diagnostics.supportDetails(stage: stage, error: providerError)
    }
}

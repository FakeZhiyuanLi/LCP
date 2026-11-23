import SwiftUI
import LCPContextCore
import LCPContextServices

struct ClassChatView: View {
    @ObservedObject var model: WorkspaceModel
    let classID: UUID?
    let globalScope: Bool

    @State private var profiles: [AgentProviderProfile] = []
    @State private var selectedProfileID: UUID?
    @State private var draft = ""
    @State private var context: ClassPlannerContext?
    @State private var loadingContext = false
    @State private var sending = false
    @State private var status: String?

    private var credentials: AgentProviderCredentials { AgentProviderCredentials.forLibrary(model.rootURL) }
    private var selectedProfile: AgentProviderProfile? { profiles.first { $0.id == selectedProfileID } }
    private var activeClassIDs: [UUID] {
        if let classID { return [classID] }
        return model.activeClasses.map(\.id)
    }
    private var thread: ChatThread? { model.chatThread(classID: classID) }
    private var messages: [ChatMessage] { thread?.messages ?? [] }

    init(model: WorkspaceModel, classID: UUID) {
        self.model = model
        self.classID = classID
        self.globalScope = false
    }

    init(model: WorkspaceModel, globalScope: Bool) {
        self.model = model
        self.classID = nil
        self.globalScope = globalScope
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if profiles.isEmpty {
                noProvider
            } else {
                contextSummary
                messageList
                composer
            }
        }
        .background(WorkspacePalette.canvas)
        .onAppear {
            refreshProfiles()
            refreshContext()
        }
        .onChange(of: model.rootURL) { _, _ in
            refreshProfiles()
            refreshContext()
        }
        .onChange(of: model.state.revision) { _, _ in
            refreshContext()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(globalScope ? "University chat" : "Class chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                if sending { ProgressView().controlSize(.small) }
            }
            Text(globalScope
                 ? "A persistent study conversation grounded in the active classes in your LCP library."
                 : "A persistent study conversation grounded only in this class's saved context.")
                .font(.callout)
                .foregroundStyle(WorkspacePalette.muted)
            Text("Each reply receives a fresh, bounded context snapshot. Raw audio, credentials, and connection grants stay local.")
                .font(.caption)
                .foregroundStyle(WorkspacePalette.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noProvider: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect an agent provider", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Add a BYOK provider in Agent Connections before starting a chat. The key stays in this library's Mac Keychain.")
                .foregroundStyle(WorkspacePalette.muted)
            HStack(spacing: 10) {
                Button("Add BYOK Provider…", systemImage: "key") {
                    model.presentedEditor = .newBYOKProvider
                }
                .buttonStyle(.borderedProminent)
                Button("Open Agent Connections", systemImage: "arrow.right") {
                    model.selection = .connections
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: 920, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contextSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(WorkspacePalette.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Fresh context for the next reply")
                    .font(.callout.weight(.semibold))
                if let context {
                    Text("\(context.sourceCount) source\(context.sourceCount == 1 ? "" : "s") across \(context.classLabels.joined(separator: ", ")) · library revision \(context.repositoryRevision)")
                        .font(.caption)
                        .foregroundStyle(WorkspacePalette.muted)
                } else if activeClassIDs.isEmpty {
                    Text(globalScope ? "Add an active class before starting the university chat." : "This class is not available in the library.")
                        .font(.caption)
                        .foregroundStyle(WorkspacePalette.muted)
                } else {
                    Text("LCP is preparing the current class context.")
                        .font(.caption)
                        .foregroundStyle(WorkspacePalette.muted)
                }
            }
            Spacer(minLength: 8)
            if loadingContext { ProgressView().controlSize(.small) }
            Button("Refresh") { refreshContext() }
                .buttonStyle(.borderless)
                .disabled(loadingContext || sending || activeClassIDs.isEmpty)
        }
        .padding(12)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(globalScope ? "Start your university conversation" : "Start your class conversation", systemImage: "sparkles")
                                .font(.headline)
                            Text(globalScope
                                 ? "Ask about priorities across your classes, upcoming deadlines, or how to balance the week."
                                 : "Ask about a lecture, reading, assignment, or the next thing you should review.")
                                .foregroundStyle(WorkspacePalette.muted)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.line) }
                    } else {
                        ForEach(messages) { message in
                            ChatMessageBubble(message: message) { citation in
                                model.presentedCitation = citation
                            }
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 76, maxHeight: 150)
                .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspacePalette.line) }
                .accessibilityLabel("Chat message")
            HStack(alignment: .center) {
                Picker("Agent provider", selection: Binding(get: { selectedProfileID ?? profiles.first?.id }, set: { selectedProfileID = $0 })) {
                    ForEach(profiles.filter(\.enabled)) { profile in
                        Text("\(profile.name) · \(profile.model)").tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 270)
                .accessibilityLabel("Agent provider")
                if let status { Text(status).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer(minLength: 8)
                Button(sending ? "Sending…" : "Send", systemImage: "arrow.up.circle.fill") {
                    send()
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || activeClassIDs.isEmpty || selectedProfile == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func refreshProfiles() {
        do {
            profiles = try credentials.profilesList().filter(\.enabled)
            if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = profiles.first?.id
            }
        } catch { status = error.localizedDescription }
    }

    private func refreshContext() {
        guard let repository = model.repository else { return }
        let ids = activeClassIDs
        guard !ids.isEmpty else {
            context = nil
            loadingContext = false
            return
        }
        loadingContext = true
        do {
            context = try ClassPlannerService(repository: repository).makeContext(classIDs: ids)
            status = nil
        } catch { status = error.localizedDescription }
        loadingContext = false
    }

    private func send() {
        guard let repository = model.repository, let profile = selectedProfile else { return }
        let ids = activeClassIDs
        guard !ids.isEmpty else {
            status = "No class context is available for this chat."
            return
        }
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, request.utf8.count <= 4_096 else {
            status = "Keep each chat message under 4,096 bytes."
            return
        }
        let key: String
        do { key = try credentials.apiKey(for: profile) }
        catch { status = error.localizedDescription; return }
        let history = thread?.messages ?? []
        sending = true
        status = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                let result = try await ClassPlannerService(repository: repository).generateChat(
                    classIDs: ids, history: history, message: request, profile: profile, apiKey: key)
                guard model.saveChatTurn(classID: classID, message: request, response: result.response.text,
                                         profile: profile, context: result.context) else { return }
                context = result.context
                draft = ""
            } catch is CancellationError {
                status = "The chat request was cancelled."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

private struct ChatMessageBubble: View {
    let message: ChatMessage
    let openCitation: (SourceCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                    .font(.caption.weight(.semibold))
                Text(message.role == .user ? "You" : (message.agentIdentity ?? "Agent"))
                    .font(.caption.weight(.semibold))
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(WorkspacePalette.muted)
            }
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
            if !message.citations.isEmpty {
                DisclosureGroup("Sources · \(message.citations.count)") {
                    FlowCitationLinks(citations: message.citations, open: openCitation)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? WorkspacePalette.surface : WorkspacePalette.tintSurface,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.line) }
    }
}

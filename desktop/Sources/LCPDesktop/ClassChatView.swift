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
    @State private var generationPhase: GenerationPhase = .idle
    @State private var generationTask: Task<Void, Never>?
    @State private var activeGenerationID: UUID?
    @State private var activeRequest: String?
    @State private var streamingText = ""
    @State private var streamingUsage: TokenUsage?
    @State private var streamingRequestID: String?
    @State private var generationStartedAt: Date?

    private let streamingBubbleID = "lcp-chat-streaming-bubble"
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
                if sending { generationBanner }
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
            guard !sending else { return }
            refreshContext()
        }
        .onDisappear { cancelGeneration() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(globalScope ? "University chat" : "Class chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 12)
                if sending { generationStatus }
            }
            Text(globalScope
                 ? "A persistent study conversation grounded in the active classes in your LCP library."
                 : "A persistent study conversation grounded only in this class's saved context.")
                .font(.callout)
                .foregroundStyle(WorkspacePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each reply receives a fresh, bounded context snapshot. Raw audio, credentials, and connection grants stay local.")
                .font(.caption)
                .foregroundStyle(WorkspacePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var generationStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(generationPhase.label)
                    .font(.caption.weight(.semibold))
                if let generationStartedAt {
                    Text(elapsedLabel(at: timeline.date.timeIntervalSince(generationStartedAt)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WorkspacePalette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(WorkspacePalette.tintSurface, in: Capsule())
            .overlay { Capsule().strokeBorder(WorkspacePalette.line.opacity(0.75)) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(generationPhase.label), \(generationStartedAt.map { elapsedLabel(at: timeline.date.timeIntervalSince($0)) } ?? "")")
        }
    }

    private var noProvider: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect an agent provider", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Add a BYOK provider in Agent Connections before starting a chat. The key stays in this library's Mac Keychain.")
                .foregroundStyle(WorkspacePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Fresh context for the next reply", systemImage: "doc.text.magnifyingglass")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(WorkspacePalette.ink)
                Spacer(minLength: 8)
                if loadingContext { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshContext() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh the class context")
                    .disabled(loadingContext || sending || activeClassIDs.isEmpty)
            }
            if let context {
                HStack(spacing: 7) {
                    contextBadge(systemImage: "square.stack.3d.up", text: "\(context.sourceCount) sources")
                    contextBadge(systemImage: "text.alignleft", text: byteLabel(context.markdown.utf8.count))
                    contextBadge(systemImage: "arrow.triangle.2.circlepath", text: "revision \(context.repositoryRevision)")
                    Spacer(minLength: 0)
                }
                Text(context.classLabels.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
                    .lineLimit(2)
            } else if activeClassIDs.isEmpty {
                Text(globalScope ? "Add an active class before starting the university chat." : "This class is not available in the library.")
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("LCP is preparing the current class context.")
                        .font(.caption)
                        .foregroundStyle(WorkspacePalette.muted)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.tintSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(WorkspacePalette.line.opacity(0.8)) }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func contextBadge(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(WorkspacePalette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(WorkspacePalette.surface.opacity(0.72), in: Capsule())
            .overlay { Capsule().strokeBorder(WorkspacePalette.line.opacity(0.7)) }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && activeRequest == nil {
                        VStack(alignment: .leading, spacing: 9) {
                            Label(globalScope ? "Start your university conversation" : "Start your class conversation", systemImage: "sparkles")
                                .font(.headline)
                            Text(globalScope
                                 ? "Ask about priorities across your classes, upcoming deadlines, or how to balance the week."
                                 : "Ask about a lecture, reading, assignment, or the next thing you should review.")
                                .foregroundStyle(WorkspacePalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
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
                        if let activeRequest {
                            pendingUserBubble(activeRequest)
                                .id("lcp-chat-pending-user")
                            StreamingMessageBubble(text: streamingText, provider: selectedProfile?.name ?? "Agent",
                                                   usage: streamingUsage, requestID: streamingRequestID)
                                .id(streamingBubbleID)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in scrollToLatest(proxy) }
            .onChange(of: streamingText) { _, _ in scrollToLatest(proxy) }
            .onChange(of: activeRequest) { _, _ in scrollToLatest(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pendingUserBubble(_ request: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.fill")
                    .font(.caption.weight(.semibold))
                Text("You")
                    .font(.caption.weight(.semibold))
                Text("sending")
                    .font(.caption2)
                    .foregroundStyle(WorkspacePalette.muted)
            }
            Text(request)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.line) }
    }

    private var generationBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(WorkspacePalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(generationPhase.label)
                    .font(.callout.weight(.semibold))
                Text(generationPhase.detail)
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
            }
            Spacer(minLength: 10)
            if let streamingUsage, let summary = usageLabel(streamingUsage) {
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WorkspacePalette.muted)
            }
            Button("Stop", systemImage: "stop.circle.fill") { cancelGeneration() }
                .buttonStyle(.bordered)
                .tint(.orange)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(WorkspacePalette.tintSurface.opacity(0.45))
        .overlay(alignment: .top) { Divider() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty && !sending {
                    Text(globalScope ? "Ask about your university context…" : "Ask about this class…")
                        .foregroundStyle(WorkspacePalette.muted.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 76, maxHeight: 150)
                    .disabled(sending)
                    .accessibilityLabel("Chat message")
            }
            .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(sending ? WorkspacePalette.accent : WorkspacePalette.line, lineWidth: sending ? 1.5 : 1) }
            HStack(alignment: .center, spacing: 10) {
                Picker("Agent provider", selection: Binding(get: { selectedProfileID ?? profiles.first?.id }, set: { selectedProfileID = $0 })) {
                    ForEach(profiles.filter(\.enabled)) { profile in
                        Text("\(profile.name) · \(profile.model)").tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .accessibilityLabel("Agent provider")
                if let status {
                    Label(status, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text("Enter to ask LCP about the saved context")
                        .font(.caption2)
                        .foregroundStyle(WorkspacePalette.muted)
                }
                Spacer(minLength: 8)
                Text("\(draft.utf8.count)/4,096")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(draft.utf8.count > 4_096 ? .red : WorkspacePalette.muted)
                if sending {
                    Button("Stop", systemImage: "stop.fill") { cancelGeneration() }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(activeClassIDs.isEmpty || selectedProfile == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
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
            if !sending { status = nil }
        } catch { status = error.localizedDescription }
        loadingContext = false
    }

    private func send() {
        guard generationTask == nil, let repository = model.repository, let profile = selectedProfile else { return }
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
        let generationID = UUID()
        activeGenerationID = generationID
        activeRequest = request
        streamingText = ""
        streamingUsage = nil
        streamingRequestID = nil
        generationStartedAt = Date()
        generationPhase = .preparing
        sending = true
        status = nil
        draft = ""

        generationTask = Task { @MainActor in
            defer {
                if activeGenerationID == generationID {
                    generationTask = nil
                    sending = false
                    generationPhase = .idle
                    activeGenerationID = nil
                    activeRequest = nil
                    streamingText = ""
                    streamingUsage = nil
                    streamingRequestID = nil
                    generationStartedAt = nil
                }
            }
            do {
                // Let SwiftUI render the preparing state before the bounded
                // context snapshot starts on the main actor.
                await Task.yield()
                try Task.checkCancellation()
                let result = try await ClassPlannerService(repository: repository).generateChatStream(
                    classIDs: ids, history: history, message: request, profile: profile, apiKey: key,
                    onUpdate: { update in
                        Task { @MainActor in
                            guard self.activeGenerationID == generationID else { return }
                            if !update.text.isEmpty { self.generationPhase = .streaming }
                            self.streamingText = update.text
                            self.streamingUsage = update.usage
                            self.streamingRequestID = update.requestID
                        }
                    })
                guard activeGenerationID == generationID else { return }
                guard model.saveChatTurn(classID: classID, message: request, response: result.response.text,
                                         profile: profile, context: result.context, usage: result.response.usage) else {
                    draft = request
                    return
                }
                context = result.context
            } catch is CancellationError {
                guard activeGenerationID == generationID else { return }
                draft = request
                status = "Generation cancelled. Your message is back in the composer."
            } catch {
                guard activeGenerationID == generationID else { return }
                draft = request
                status = error.localizedDescription
            }
        }
    }

    private func cancelGeneration() {
        guard sending else { return }
        generationPhase = .cancelling
        generationTask?.cancel()
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if activeRequest != nil {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(streamingBubbleID, anchor: .bottom) }
        } else if let last = messages.last {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func elapsedLabel(at interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func byteLabel(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
        return "\(bytes) bytes"
    }

    fileprivate static func usageLabel(_ usage: TokenUsage?) -> String? {
        guard let usage else { return nil }
        if let total = usage.totalTokens { return "\(compactNumber(total)) tokens" }
        let parts = [usage.inputTokens.map { "in \(compactNumber($0))" }, usage.outputTokens.map { "out \(compactNumber($0))" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func usageLabel(_ usage: TokenUsage?) -> String? { Self.usageLabel(usage) }

    private static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

private enum GenerationPhase {
    case idle
    case preparing
    case streaming
    case cancelling

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing context"
        case .streaming: return "Writing response"
        case .cancelling: return "Stopping"
        }
    }

    var detail: String {
        switch self {
        case .idle: return ""
        case .preparing: return "Reviewing the latest saved sources…"
        case .streaming: return "The answer will appear here as it arrives."
        case .cancelling: return "Finishing the request safely…"
        }
    }
}

private struct StreamingMessageBubble: View {
    let text: String
    let provider: String
    let usage: TokenUsage?
    let requestID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                Text(provider)
                    .font(.caption.weight(.semibold))
                Text("live")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(WorkspacePalette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(WorkspacePalette.tintSurface, in: Capsule())
                Spacer(minLength: 0)
                if let usage, let summary = ClassChatView.usageLabel(usage) {
                    Text(summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WorkspacePalette.muted)
                }
            }
            if text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(WorkspacePalette.muted)
                }
            } else {
                Text(text + "▌")
                    .font(.body)
                    .textSelection(.enabled)
            }
            if let requestID, !requestID.isEmpty {
                Text("Request \(requestID)")
                    .font(.caption2)
                    .foregroundStyle(WorkspacePalette.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.accent.opacity(0.6), lineWidth: 1.2) }
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
                Spacer(minLength: 0)
                if let usage = message.usage, let summary = ClassChatView.usageLabel(usage) {
                    Label(summary, systemImage: "chart.bar.xaxis")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(WorkspacePalette.muted)
                }
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

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LCPContextCore
import LCPContextServices

struct ClassChatView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var session: ChatSession
    @State private var profiles: [AgentProviderProfile] = []
    @State private var choosingFiles = false
    @State private var hoveringFiles = false
    @State private var loadingContext = false
    @State private var contextTask: Task<Void, Never>?

    private let streamingBubbleID = "lcp-chat-streaming-bubble"
    private var globalScope: Bool { session.classID == nil }
    private var sending: Bool { session.generation != nil }
    private var selectedProfile: AgentProviderProfile? { profiles.first { $0.id == session.selectedProfileID } }
    private var activeClassIDs: [UUID] { session.classIDs(in: model) }
    private var messages: [ChatMessage] { model.chatThread(classID: session.classID)?.messages ?? [] }
    private var unsavedReply: UnsavedChatReply? { model.unsavedChatReplies[session.classID] }

    init(model: WorkspaceModel, classID: UUID? = nil) {
        self.model = model
        self.session = model.chatSession(for: classID)
    }

    var body: some View {
        Group {
            if profiles.isEmpty && messages.isEmpty && session.draft.isEmpty && session.uploads.isEmpty && !sending && unsavedReply == nil {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        noProvider
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    contextSummary
                    messageList
                    if let generation = session.generation { generationBanner(generation) }
                    composer
                }
            }
        }
        // The split view measures its detail at narrow widths. Let the chat
        // fit the pane even when its wrapped text reports a tall minimum.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspacePalette.canvas)
        .task(id: ObjectIdentifier(session)) { await refreshProfiles() }
        .onChange(of: model.state.revision) { _, _ in
            guard !sending, session.context != nil else { return }
            scheduleContextRefresh()
        }
        .onDisappear {
            contextTask?.cancel()
            loadingContext = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(globalScope ? "University chat" : "Class chat", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 12)
                if let generation = session.generation { generationStatus(generation) }
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

    private func generationStatus(_ generation: ChatSession.Generation) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(generation.phase.label)
                    .font(.caption.weight(.semibold))
                Text(elapsedLabel(at: timeline.date.timeIntervalSince(generation.startedAt)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WorkspacePalette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(WorkspacePalette.tintSurface, in: Capsule())
            .overlay { Capsule().strokeBorder(WorkspacePalette.line.opacity(0.75)) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(generation.phase.label), \(elapsedLabel(at: timeline.date.timeIntervalSince(generation.startedAt)))")
        }
    }

    private var noProvider: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect an agent provider", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Add a BYOK provider in Agent Connections before starting a chat. The key stays in this library's Mac Keychain.")
                .foregroundStyle(WorkspacePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            statusRow
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
        .frame(maxWidth: 920, alignment: .topLeading)
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
                Button("Refresh", systemImage: "arrow.clockwise") { scheduleContextRefresh() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh the class context")
                    .disabled(loadingContext || sending || activeClassIDs.isEmpty)
            }
            if let context = session.context {
                HStack(spacing: 7) {
                    contextBadge(systemImage: "square.stack.3d.up", text: "\(context.sourceCount) sources")
                    contextBadge(systemImage: "text.alignleft", text: byteLabel(context.byteCount))
                    contextBadge(systemImage: "arrow.triangle.2.circlepath", text: "revision \(context.revision)")
                    Spacer(minLength: 0)
                }
                Text(context.classLabels.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
                    .lineLimit(2)
            } else if activeClassIDs.isEmpty {
                Text(globalScope ? "You can start with a question or attach a file." : "This class is not available in the library.")
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: loadingContext ? "hourglass" : "arrow.down.doc")
                    Text(loadingContext
                         ? "LCP is preparing the current class context."
                         : "The current class context will be prepared when you refresh or send a message.")
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
                    if messages.isEmpty && !sending && unsavedReply == nil {
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
                            ChatMessageBubble(model: model, threadID: model.chatThread(classID: session.classID)?.id, message: message) { citation in
                                model.presentedCitation = citation
                            }
                            .id(message.id)
                        }
                        if let generation = session.generation {
                            pendingUserBubble(generation.question, filenames: generation.filenames)
                                .id("lcp-chat-pending-user")
                            StreamingMessageBubble(text: generation.update?.text ?? "", provider: generation.providerName,
                                                   usage: generation.update?.usage, requestID: generation.update?.requestID)
                                .id(streamingBubbleID)
                        } else if let unsavedReply {
                            pendingUserBubble(unsavedReply.question, filenames: unsavedReply.result.uploads.map(\.attachment.filename), status: "unsaved")
                            StreamingMessageBubble(text: unsavedReply.result.response.text, provider: unsavedReply.profile.name,
                                                   usage: unsavedReply.result.response.usage, requestID: unsavedReply.result.response.requestID,
                                                   badge: "unsaved")
                                .id(streamingBubbleID)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToLatest(proxy, animated: false) }
            .onChange(of: messages.count) { _, _ in scrollToLatest(proxy) }
            .onChange(of: session.generation?.update?.text) { _, _ in scrollToLatest(proxy) }
            .onChange(of: session.generation?.id) { _, _ in scrollToLatest(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pendingUserBubble(_ request: String, filenames: [String], status: String = "sending") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.fill")
                    .font(.caption.weight(.semibold))
                Text("You")
                    .font(.caption.weight(.semibold))
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(WorkspacePalette.muted)
            }
            if !request.isEmpty { Text(verbatim: request).font(.body).textSelection(.enabled) }
            ForEach(Array(filenames.enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "paperclip").font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspacePalette.line) }
    }

    private func generationBanner(_ generation: ChatSession.Generation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(WorkspacePalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(generation.phase.label)
                    .font(.callout.weight(.semibold))
                Text(generation.phase.detail)
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
            }
            Spacer(minLength: 10)
            if let summary = usageLabel(generation.update?.usage) {
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WorkspacePalette.muted)
            }
            Button("Stop", systemImage: "stop.circle.fill") { session.stop() }
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
            if !session.uploads.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(session.uploads) { upload in
                            HStack(spacing: 6) {
                                Image(systemName: "doc")
                                Text(upload.attachment.filename).lineLimit(1)
                                Button {
                                    session.uploads.removeAll { $0.id == upload.id }
                                    if session.uploads.isEmpty { session.automaticallyFileUploads = false }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(upload.attachment.filename)")
                            }
                            .font(.callout).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(WorkspacePalette.tintSurface, in: Capsule())
                            .help(upload.contentDescription)
                        }
                    }
                }.scrollIndicators(.hidden)
                if !activeClassIDs.isEmpty {
                    Toggle("Let the agent file these uploads in class materials", isOn: $session.automaticallyFileUploads)
                        .toggleStyle(.checkbox).font(.caption)
                        .help("Applies to files in this message and classes in this conversation.")
                }
            }
            ZStack(alignment: .topLeading) {
                if session.draft.isEmpty && !sending {
                    Text(globalScope ? "Ask about your university context…" : "Ask about this class…")
                        .foregroundStyle(WorkspacePalette.muted.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $session.draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 76, maxHeight: 150)
                    .disabled(sending)
                    .accessibilityLabel("Chat message")
            }
            .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(sending ? WorkspacePalette.accent : WorkspacePalette.line, lineWidth: sending ? 1.5 : 1) }
            statusRow
            HStack(alignment: .center, spacing: 10) {
                Button { choosingFiles = true } label: {
                    Label("Attach Files…", systemImage: "paperclip").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Attach files to this message")
                .accessibilityLabel("Attach files")
                .disabled(sending || session.loadingFiles || unsavedReply != nil)
                if session.loadingFiles { ProgressView().controlSize(.small) }
                Menu {
                    if profiles.isEmpty {
                        Button("Add BYOK Provider…", systemImage: "key") { model.presentedEditor = .newBYOKProvider }
                    }
                    ForEach(profiles) { profile in
                        Button {
                            session.selectedProfileID = profile.id
                        } label: {
                            HStack {
                                Text(profile.name)
                                Spacer()
                                Text(profile.model)
                                    .foregroundStyle(WorkspacePalette.muted)
                            }
                        }
                    }
                } label: {
                    Label(selectedProfile.map { "\($0.name) · \($0.model)" } ?? "Choose an agent",
                          systemImage: "sparkles")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 280, alignment: .leading)
                .accessibilityLabel("Agent provider")
                if session.status == nil {
                    Text("⌘ Return to send")
                        .font(.caption2)
                        .foregroundStyle(WorkspacePalette.muted)
                }
                Spacer(minLength: 8)
                if sending {
                    Button("Stop", systemImage: "stop.fill") { session.stop() }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        if let selectedProfile { session.send(in: model, using: selectedProfile) }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(unsavedReply != nil || selectedProfile == nil || !session.canSend)
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
        .overlay { if hoveringFiles { RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspacePalette.accent, lineWidth: 2).allowsHitTesting(false) } }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await session.attach(urls) }
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { session.status = error.localizedDescription }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !sending, !session.loadingFiles, unsavedReply == nil, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            Task { await session.attach(urls) }
            return true
        } isTargeted: { hoveringFiles = $0 }
    }

    @ViewBuilder private var statusRow: some View {
        if let unsavedReply {
            VStack(alignment: .leading, spacing: 5) {
                Label(unsavedReply.reason, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    Button("Retry Save") {
                        session.saveReply(in: model, question: unsavedReply.question, result: unsavedReply.result,
                                          profile: unsavedReply.profile, diagnostics: unsavedReply.diagnostics,
                                          automaticallyFileUploads: unsavedReply.automaticallyFileUploads)
                    }
                    Button("Copy Reply") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(unsavedReply.result.response.text, forType: .string)
                    }
                    Button("Copy Error Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(unsavedReply.errorDetails, forType: .string)
                    }
                    Button("Discard Unsaved Reply", role: .destructive) {
                        model.discardUnsavedChatReply(classID: session.classID)
                    }
                }.controlSize(.small)
            }
        } else if let status = session.status {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(status, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let errorDetails = session.errorDetails {
                    Button("Copy Error Details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(errorDetails, forType: .string)
                    }.controlSize(.small)
                }
            }
        }
    }

    private func refreshProfiles() async {
        let diagnostics = AgentRequestDiagnostics()
        diagnostics.chatStage(.profiles)
        do {
            let values = try await model.chatProviders.profiles(model.rootURL).filter(\.enabled)
            try Task.checkCancellation()
            profiles = values
            if !values.contains(where: { $0.id == session.selectedProfileID }) {
                session.selectedProfileID = values.first?.id
            }
        } catch {
            guard !Task.isCancelled else { return }
            profiles = []
            session.reportFailure(error, stage: .profiles, diagnostics: diagnostics)
        }
    }

    private func scheduleContextRefresh() {
        contextTask?.cancel()
        guard let repository = model.repository else { return }
        let ids = activeClassIDs
        guard !ids.isEmpty else {
            session.context = nil
            loadingContext = false
            return
        }
        let diagnostics = AgentRequestDiagnostics()
        diagnostics.chatStage(.context)
        loadingContext = true
        contextTask = Task { @MainActor in
            // Let SwiftUI commit the chat shell before payload validation and
            // context assembly run on the main actor.
            await Task.yield()
            guard !Task.isCancelled else { return }
            do {
                let prepared = try ClassPlannerService(repository: repository).makeContext(classIDs: ids)
                guard !Task.isCancelled else { return }
                session.context = .init(prepared)
                if !sending { session.status = nil; session.errorDetails = nil }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                session.reportFailure(error, stage: .context, diagnostics: diagnostics)
            }
            loadingContext = false
            contextTask = nil
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        withAnimation(animated ? .easeOut(duration: 0.2) : nil) {
            if sending || unsavedReply != nil {
                proxy.scrollTo(streamingBubbleID, anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
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

private extension ChatSession.Phase {
    var label: String {
        switch self {
        case .preparing: return "Preparing context"
        case .waiting: return "Waiting for provider"
        case .streaming: return "Writing response"
        case .cancelling: return "Stopping"
        }
    }

    var detail: String {
        switch self {
        case .preparing: return "Reviewing the latest saved sources…"
        case .waiting: return "LCP is waiting for the first part of the answer."
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
    var badge = "live"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                Text(provider)
                    .font(.caption.weight(.semibold))
                Text(badge)
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
                AgentOutputView(source: text)
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
    @ObservedObject var model: WorkspaceModel
    let threadID: UUID?
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
            if message.role == .assistant {
                AgentOutputView(source: message.content)
            } else {
                if !message.content.isEmpty { Text(verbatim: message.content).textSelection(.enabled) }
                if let threadID {
                    ForEach(message.attachments ?? []) { file in
                        ChatFileRow(model: model, threadID: threadID, file: file)
                    }
                }
            }
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

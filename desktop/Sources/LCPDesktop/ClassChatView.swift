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
    @State private var showingContext = false
    @State private var transcriptLayout: TranscriptLayout?
    @State private var alignedReplyID: UUID?
    @FocusState private var composerFocused: Bool

    private var globalScope: Bool { session.classID == nil }
    private var sending: Bool { session.generation != nil }
    private var selectedProfile: AgentProviderProfile? { profiles.first { $0.id == session.selectedProfileID } }
    private var activeClassIDs: [UUID] { session.classIDs(in: model) }
    private var messages: [ChatMessage] { model.chatThread(classID: session.classID)?.messages ?? [] }
    private var unsavedReply: UnsavedChatReply? { model.unsavedChatReplies[session.classID] }
    private var latestReplyID: UUID? { session.generation?.id ?? unsavedReply?.diagnostics.id ?? messages.last?.id }

    init(model: WorkspaceModel, classID: UUID? = nil) {
        self.model = model
        self.session = model.chatSession(for: classID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header(proxy)
                Divider()
                if profiles.isEmpty && messages.isEmpty && session.draft.isEmpty && session.uploads.isEmpty && !sending && unsavedReply == nil {
                    ScrollView { noProvider }
                } else {
                    messageList(proxy)
                    Divider()
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

    private func header(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            Label(globalScope ? "University chat" : "Class chat", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let generation = session.generation { generationStatus(generation).help(generation.phase.detail) }
            if transcriptLayout?.nearLatest == false, let latestReplyID {
                Button("Jump to latest", systemImage: "arrow.down.to.line") {
                    proxy.scrollTo(latestReplyID, anchor: .bottom)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Jump to the end of the latest message")
            }
            Button("Context", systemImage: "doc.text.magnifyingglass") { showingContext.toggle() }
                .buttonStyle(.bordered)
                .help("View and refresh the sources for the next reply")
                .popover(isPresented: $showingContext) {
                    contextSummary
                        .onAppear {
                            if session.context == nil && !sending { scheduleContextRefresh() }
                        }
                }
        }
        .padding(.vertical, 8)
        .modifier(ChatColumn())
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
                Text("Context for the next reply")
                    .font(.headline)
                    .foregroundStyle(WorkspacePalette.ink)
                Spacer(minLength: 8)
                if loadingContext { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { scheduleContextRefresh() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh context")
                    .disabled(loadingContext || sending || activeClassIDs.isEmpty)
            }
            Text(globalScope
                 ? "Replies use saved sources from your active classes and any files you attach."
                 : "Replies use saved sources from this class and any files you attach.")
                .font(.callout)
                .foregroundStyle(WorkspacePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
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
                    .help(context.classLabels.joined(separator: " · "))
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
        .padding(16)
        .frame(width: 350, alignment: .leading)
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

    private func messageList(_ proxy: ScrollViewProxy) -> some View {
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
                        ChatMessageBubble(model: model, threadID: model.chatThread(classID: session.classID)?.id,
                                          message: message, openCitation: { model.presentedCitation = $0 },
                                          onFirstLayout: { alignRenderedReply(message.id, in: proxy) })
                        .id(message.id)
                    }
                    if let generation = session.generation {
                        pendingUserBubble(generation.question, filenames: generation.filenames)
                            .id("lcp-chat-pending-user")
                        StreamingMessageBubble(text: generation.update?.text ?? "", provider: generation.providerName,
                                               usage: generation.update?.usage, requestID: generation.update?.requestID,
                                               onFirstLayout: { alignRenderedReply(generation.id, in: proxy) })
                            .id(generation.id)
                    } else if let unsavedReply {
                        pendingUserBubble(unsavedReply.question, filenames: unsavedReply.result.uploads.map(\.attachment.filename), status: "unsaved")
                        StreamingMessageBubble(text: unsavedReply.result.response.text, provider: unsavedReply.profile.name,
                                               usage: unsavedReply.result.response.usage, requestID: unsavedReply.result.response.requestID,
                                               badge: "unsaved", onFirstLayout: { alignRenderedReply(unsavedReply.diagnostics.id, in: proxy) })
                            .id(unsavedReply.diagnostics.id)
                    }
                }
            }
            .padding(.vertical, 12)
            .modifier(ChatColumn())
            .onGeometryChange(for: TranscriptLayout.self) { geometry in
                let height = geometry.size.height
                let visibleEnd = geometry.bounds(of: .scrollView(axis: .vertical))?.maxY ?? height
                return TranscriptLayout(height: height, visibleEnd: visibleEnd)
            } action: { layout in
                let previous = transcriptLayout
                guard layout.height != previous?.height || layout.nearLatest != previous?.nearLatest else { return }
                transcriptLayout = layout
                // Follow the rendered reply while the reader is at the end, including large Markdown updates.
                if let generation = session.generation, let previous, previous.nearLatest, layout.height > previous.height,
                   layout.visibleEnd >= previous.height - TranscriptLayout.followDistance {
                    proxy.scrollTo(generation.id, anchor: .bottom)
                }
            }
        }
        .clipped()
        .task(id: latestReplyID) {
            guard let latestReplyID else { return }
            if let generation = session.generation, (generation.update?.text ?? "").isEmpty {
                alignedReplyID = latestReplyID
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo(latestReplyID, anchor: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func alignRenderedReply(_ id: UUID, in proxy: ScrollViewProxy) {
        // A saved reply can first appear as a short bubble while its Markdown is being laid out.
        guard id == latestReplyID, alignedReplyID != id else { return }
        alignedReplyID = id
        proxy.scrollTo(id, anchor: .top)
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            uploadControls
            statusRow
            VStack(alignment: .leading, spacing: 4) {
                draftEditor
                composerToolbar.padding(.horizontal, 4)
            }
            .padding(8)
            .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(composerFocused ? WorkspacePalette.accent : WorkspacePalette.line)
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 8)
        .modifier(ChatColumn())
        .background(WorkspacePalette.canvas)
        .overlay {
            if hoveringFiles {
                RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspacePalette.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
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

    @ViewBuilder private var uploadControls: some View {
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
    }

    private var draftEditor: some View {
        // Measure wrapped text at the editor's width; the text view scrolls beyond five lines.
        Text(verbatim: session.draft + "\u{200B}")
            .font(.body)
            .lineLimit(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $session.draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .disabled(sending)
                    .accessibilityLabel("Chat message")
                    .overlay(alignment: .topLeading) {
                        if session.draft.isEmpty && !sending {
                            Text(globalScope ? "Ask about your university context…" : "Ask about this class…")
                                .font(.body)
                                .foregroundStyle(WorkspacePalette.muted)
                                .padding(.horizontal, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
    }

    private var composerToolbar: some View {
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
            Spacer(minLength: 8)
            if sending {
                Button("Stop", systemImage: "stop.fill") { session.stop() }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") {
                    if let selectedProfile { session.send(in: model, using: selectedProfile) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(unsavedReply != nil || selectedProfile == nil || !session.canSend)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send message (⌘Return)")
            }
        }
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

    private static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

private struct TranscriptLayout: Equatable {
    static let followDistance: CGFloat = 24
    let height: CGFloat
    let visibleEnd: CGFloat
    var nearLatest: Bool { height - visibleEnd <= Self.followDistance }
}

private struct ChatColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
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
    let onFirstLayout: () -> Void

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
                AgentOutputView(source: text, onFirstLayout: onFirstLayout)
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
    let onFirstLayout: () -> Void

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
                AgentOutputView(source: message.content, onFirstLayout: onFirstLayout)
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

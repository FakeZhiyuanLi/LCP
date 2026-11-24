import SwiftUI
import LCPContextCore

/// A dedicated home for saved conversations across the entire library.
/// Current drafts remain owned by ChatSession and are intentionally omitted
/// until the first reply saves a thread.
struct ChatHistoryView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var searchText = ""

    private var filteredThreads: [ChatThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.chatHistoryThreads }
        return model.chatHistoryThreads.filter { thread in
            let preview = thread.messages.last(where: { $0.role == .user })?.content ?? ""
            let scope = model.chatScopeLabel(for: thread)
            return [thread.title, scope, preview].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if filteredThreads.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredThreads) { thread in
                            ChatHistoryRow(model: model, thread: thread)
                        }
                    }
                }
            }
            .workspacePage()
        }
        .background(WorkspacePalette.canvas)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search saved chats")
        .accessibilityIdentifier("chat-history")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Chat History").workspacePageTitle()
                if !model.chatHistoryThreads.isEmpty {
                    Text("\(model.chatHistoryThreads.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(WorkspacePalette.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(WorkspacePalette.tintSurface, in: Capsule())
                }
            }
            Text("Browse saved conversations from your classes and university context. Select a chat to continue where you left off.")
                .font(.callout)
                .foregroundStyle(WorkspacePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(WorkspacePalette.accent)
                .accessibilityHidden(true)
            Text(searchText.isEmpty ? "No saved chats yet" : "No matching chats")
                .font(.title2.weight(.semibold))
            Text(searchText.isEmpty
                 ? "Start a class or university chat. Once the first response is saved, it will appear here."
                 : "Try a different title, class, or phrase from the conversation.")
                .foregroundStyle(WorkspacePalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspacePanel()
    }
}

private struct ChatHistoryRow: View {
    @ObservedObject var model: WorkspaceModel
    let thread: ChatThread
    @State private var hovered = false

    private var preview: String {
        let message = thread.messages.last(where: { $0.role == .user }) ?? thread.messages.last
        let value = message?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No messages"
        return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private var turnCount: Int {
        let count = thread.messages.filter { $0.role == .user }.count
        return count > 0 ? count : (thread.messages.count + 1) / 2
    }

    private var enrollment: ClassEnrollment? {
        guard let classID = thread.classID else { return nil }
        return model.state.classes.first(where: { $0.id == classID })
    }

    var body: some View {
        Button {
            _ = model.openChatHistoryThread(thread)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: thread.classID == nil ? "building.columns" : "book.closed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WorkspacePalette.accent)
                    .frame(width: 34, height: 34)
                    .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(thread.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(WorkspacePalette.ink)
                            .lineLimit(1)
                        if enrollment?.archived == true {
                            Text("Archived")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(WorkspacePalette.muted)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(WorkspacePalette.canvas, in: Capsule())
                        }
                    }
                    HStack(spacing: 7) {
                        Text(model.chatScopeLabel(for: thread))
                        Text("·")
                        Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                        Text("\(turnCount) \(turnCount == 1 ? "turn" : "turns")")
                    }
                    .font(.caption)
                    .foregroundStyle(WorkspacePalette.muted)
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(WorkspacePalette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WorkspacePalette.muted)
                    .padding(.top, 9)
                    .accessibilityHidden(true)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? WorkspacePalette.tintSurface : WorkspacePalette.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovered ? WorkspacePalette.accent : WorkspacePalette.line)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open \(thread.title) in \(model.chatScopeLabel(for: thread))")
        .accessibilityLabel("\(thread.title), \(model.chatScopeLabel(for: thread))")
        .accessibilityValue("Updated \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened)). \(turnCount) \(turnCount == 1 ? "turn" : "turns")")
    }
}

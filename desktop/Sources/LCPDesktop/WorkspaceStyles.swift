import SwiftUI

enum WorkspaceLayout {
    static let pageInset: CGFloat = 28
    static let pageWidth: CGFloat = 1_030
}

extension View {
    func workspacePage() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceLayout.pageInset)
            .frame(maxWidth: WorkspaceLayout.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    func workspacePageTitle() -> some View {
        font(.system(size: 34, weight: .semibold))
            .tracking(-0.9)
            .foregroundStyle(WorkspacePalette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    func workspacePanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return background(WorkspacePalette.surface, in: shape)
            .overlay { shape.strokeBorder(WorkspacePalette.line).allowsHitTesting(false) }
    }

    func workspaceListRow() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .workspacePanel()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
    }
}

/// Keeps the hit area and VoiceOver name on the native menu control.
struct MoreActionsMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

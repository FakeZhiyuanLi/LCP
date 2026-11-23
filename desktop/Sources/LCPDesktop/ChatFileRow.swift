import SwiftUI
import AppKit
import LCPContextCore
import LCPContextServices

struct ChatFileRow: View {
    @ObservedObject var model: WorkspaceModel
    let threadID: UUID
    let file: ChatAttachment

    private var destinations: [ClassEnrollment] {
        if let id = model.state.chatThreads?.first(where: { $0.id == threadID })?.classID {
            return model.state.classes.filter { $0.id == id }
        }
        return model.visibleClassGroups.flatMap(\.classes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "doc")
                    .foregroundStyle(WorkspacePalette.accent)
                Text(file.filename).font(.callout.weight(.medium)).lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.original.byteCount), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu {
                    if file.savedMaterialID == nil {
                        ForEach(destinations) { enrollment in
                            Button("Save to \(enrollment.displayLabel)") { save(to: enrollment.id) }
                        }
                    }
                    Button("Save a Copy…", action: exportCopy)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Actions for \(file.filename)")
            }
            if let saved = file.savedMaterialID, let material = model.state.materials.first(where: { $0.id == saved }) {
                Label("Saved to \(model.state.classes.first { $0.id == material.classID }?.shortLabel ?? "class materials")",
                      systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            } else if let suggestion = file.suggestion, let target = destinations.first(where: { $0.id == suggestion.classID }) {
                Text(suggestion.reason).font(.callout).foregroundStyle(.secondary)
                Button("Save “\(suggestion.title)” to \(target.shortLabel)") { save(to: target.id) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(WorkspacePalette.tintSurface, in: RoundedRectangle(cornerRadius: 9))
    }

    private func save(to classID: UUID) {
        guard let repository = model.repository else { return }
        model.perform { try ChatFilingTool.file(file.id, from: threadID, to: classID, in: repository) }
    }

    private func exportCopy() {
        guard let repository = model.repository else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try repository.payloadData(file.original).write(to: url, options: .atomic) }
        catch { model.errorMessage = error.localizedDescription }
    }
}

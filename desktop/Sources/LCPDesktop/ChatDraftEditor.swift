import AppKit
import SwiftUI

/// Finder files dropped on a standard text view are inserted as paths.
/// The chat editor attaches those files and uses native editing for text drags.
struct ChatDraftEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let acceptsFiles: Bool
    let attach: ([URL]) -> Bool
    let fileHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ChatDraftTextView.scrollableTextView()
        let editor = scroll.documentView as! ChatDraftTextView
        scroll.autohidesScrollers = true
        editor.drawsBackground = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.allowsUndo = true
        editor.setAccessibilityLabel("Chat message")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let editor = scroll.documentView as! ChatDraftTextView
        if editor.isEditable != isEditable { editor.isEditable = isEditable }
        editor.acceptsFiles = acceptsFiles
        editor.attach = attach
        editor.fileHover = fileHover
        editor.onEdit = { text = $0 }
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
    }
}

final class ChatDraftTextView: NSTextView {
    var acceptsFiles = false
    var attach: (([URL]) -> Bool)?
    var fileHover: ((Bool) -> Void)?
    var onEdit: ((String) -> Void)?
    private let draftUndo = UndoManager()
    override var undoManager: UndoManager? { draftUndo }

    override func didChangeText() {
        super.didChangeText()
        onEdit?(string)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.acceptableDragTypes
    }

    override func dragOperation(for sender: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else {
            return super.dragOperation(for: sender, type: type)
        }
        fileHover?(acceptsFiles)
        return acceptsFiles ? .copy : []
    }

    override func cleanUpAfterDragOperation() {
        fileHover?(false)
        super.cleanUpAfterDragOperation()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        guard board.availableType(from: [.fileURL]) != nil else { return super.performDragOperation(sender) }
        defer { cleanUpAfterDragOperation() }
        return attachFiles(from: board)
    }

    func attachFiles(from board: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard acceptsFiles, let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        return attach?(urls) ?? false
    }
}

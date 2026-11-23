import AppKit
import SwiftUI
import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

final class ChatWindowLayoutTests: XCTestCase {
    @MainActor
    func testChatHistoryAndGrowingComposerFitBothWorkspaceRoutes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = AgentProviderProfile(name: "Fictional provider", baseURL: "https://example.invalid/v1",
                                           model: "fictional-model")

        let providers = ChatProviders(profiles: { _ in
            await Task.yield()
            return [provider]
        })
        let model = WorkspaceModel(arguments: ["--profile-root", root.path, "--demo"], chatProviders: providers)
        let enrollment = try XCTUnwrap(model.activeClasses.first)
        model.notice = nil
        let repository = try XCTUnwrap(model.repository)
        let reply = (1...80).map { "Study point \($0) for the fictional seminar." }.joined(separator: "\n\n")
        for classID: UUID? in [enrollment.id, nil] {
            let ids = [enrollment.id]
            let earlier = (1...30).map { "Earlier observation \($0)" }.joined(separator: "\n")
            let thread = ChatThread(classID: classID, title: "Seminar chat", messages: [
                ChatMessage(role: .user, content: earlier, contextClassIDs: ids),
                ChatMessage(role: .assistant, content: "Keep those observations for the seminar.", contextClassIDs: ids),
                ChatMessage(role: .user, content: "What should I review?", contextClassIDs: ids),
                ChatMessage(role: .assistant, content: reply, contextClassIDs: ids),
            ])
            try repository.update { $0.chatThreads = ($0.chatThreads ?? []) + [thread] }
            model.refresh()
            model.chatClassID = classID
            model.selection = classID.map(WorkspaceRoute.classDetail) ?? .universityChat
            let workspace = WorkspaceView(model: model).frame(minWidth: 980, minHeight: 660)
            let window = NSWindow(contentViewController: NSHostingController(rootView: workspace))
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.setContentSize(NSSize(width: 1260, height: 820))
            window.orderBack(nil)
            let content = try XCTUnwrap(window.contentView)
            let session = model.chatSession(for: classID)
            for _ in 0..<100 where session.selectedProfileID == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(session.selectedProfileID, provider.id)
            let editor = try XCTUnwrap(descendants(NSTextView.self, of: content).first(where: \.isEditable))
            let composer = try XCTUnwrap(editor.enclosingScrollView)
            let split = try XCTUnwrap(descendants(NSSplitView.self, of: content).first)
            let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
            let detail = try XCTUnwrap(split.arrangedSubviews.last)
            let history = try XCTUnwrap(descendants(NSScrollView.self, of: detail).first { $0 !== composer && $0.bounds.height > 150 })
            // Wait for the saved Markdown reply to lay out at its full height.
            for _ in 0..<100 where (history.documentView?.bounds.height ?? 0) < 2_200 {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThan(try XCTUnwrap(history.documentView).bounds.height, 2_200)
            for _ in 0..<100 where history.documentVisibleRect.minY <= 350 {
                try await Task.sleep(for: .milliseconds(20))
            }
            // Both the earlier turn and most of the latest reply extend beyond the viewport.
            XCTAssertGreaterThan(history.documentVisibleRect.minY, 350)
            XCTAssertLessThan(history.documentVisibleRect.minY, 850)
            let screenshotWidth = sidebar.frame.width + split.dividerThickness + 967
            for size in [NSSize(width: screenshotWidth, height: 732), NSSize(width: 980, height: 660)] {
                window.setContentSize(size)
                content.layoutSubtreeIfNeeded()
                for _ in 0..<100 where abs(content.bounds.height - size.height) > 1 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                for view in [composer, sidebar, history] {
                    let frame = view.convert(view.bounds, to: content)
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                                  "Window \(content.bounds) should contain \(type(of: view)) at \(frame)")
                }
                let transcriptFrame = history.convert(history.bounds, to: content)
                XCTAssertFalse(transcriptFrame.intersects(composer.convert(composer.bounds, to: content)))
                XCTAssertGreaterThan(transcriptFrame.height, size.height * 0.55)
                XCTAssertLessThan(composer.bounds.height, 40)
            }
            session.draft = String(repeating: "A wrapped fictional sentence. ", count: 250)
            for _ in 0..<100 where editor.string != session.draft || composer.bounds.height < 55 {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(editor.string, session.draft)
            XCTAssertGreaterThan(composer.bounds.height, 55)
            XCTAssertLessThan(composer.bounds.height, 110)
            XCTAssertGreaterThan(history.bounds.height, 300)
            let file = root.appendingPathComponent("Fictional seminar notes.txt")
            try Data("Notes from the seminar.".utf8).write(to: file)
            await session.attach([file])
            XCTAssertEqual(session.uploads.count, 1)
            content.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(history.bounds.height, 250)
            session.draft = ""
            for _ in 0..<100 where composer.bounds.height >= 40 { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertLessThan(composer.bounds.height, 40)
        }
    }

    @MainActor
    private func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
        [view as? T].compactMap { $0 } + view.subviews.flatMap { descendants(type, of: $0) }
    }
}

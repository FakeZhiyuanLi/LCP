import AppKit
import SwiftUI
import XCTest
import LCPContextServices
@testable import LCPDesktop

final class ChatWindowLayoutTests: XCTestCase {
    @MainActor
    func testLoadingProviderKeepsChatComposerAndSidebarInsideWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path, "--demo"])
        let enrollment = try XCTUnwrap(model.activeClasses.first)
        let provider = AgentProviderProfile(name: "Fictional provider", baseURL: "https://example.invalid/v1",
                                           model: "fictional-model")

        for var chat in [ClassChatView(model: model, globalScope: true), ClassChatView(model: model, classID: enrollment.id)] {
            chat.loadProfiles = { _ in
                await Task.yield()
                return [provider]
            }
            let workspace = NavigationSplitView {
                Text("Class Library").navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 310)
            } detail: {
                chat
            }
            .frame(minWidth: 980, minHeight: 660)
            let window = NSWindow(contentViewController: NSHostingController(rootView: workspace))
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.setContentSize(NSSize(width: 1260, height: 820))
            window.orderBack(nil)
            let content = try XCTUnwrap(window.contentView)
            // The composer is mounted only after the asynchronous provider read returns.
            for _ in 0..<100 where descendant(NSTextView.self, of: content) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let editor = try XCTUnwrap(descendant(NSTextView.self, of: content))
            let split = try XCTUnwrap(descendant(NSSplitView.self, of: content))
            for size in [NSSize(width: 1260, height: 820), NSSize(width: 980, height: 660)] {
                window.setContentSize(size)
                content.layoutSubtreeIfNeeded()
                let composer = try XCTUnwrap(editor.enclosingScrollView)
                let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
                for view in [composer, sidebar] {
                    let frame = view.convert(view.bounds, to: content)
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                                  "Window \(content.bounds) should contain \(type(of: view)) at \(frame)")
                }
            }
        }
    }

    @MainActor
    private func descendant<T: NSView>(_ type: T.Type, of view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, of: child) { return match }
        }
        return nil
    }
}

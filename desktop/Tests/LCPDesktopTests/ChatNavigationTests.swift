import AppKit
import SwiftUI
import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

@MainActor
final class ChatNavigationTests: XCTestCase {
    func testLocalThanksIsSavedInBothChatsWithoutReadingTheKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AgentProviderProfile(name: "Fictional provider", baseURL: "https://example.invalid", model: "fixture")
        let providers = AgentProviders(apiKey: { _, _ in XCTFail("Local reply read the API key"); return "" })
        let model = WorkspaceModel(arguments: ["--profile-root", root.path], agentProviders: providers)
        model.canvasSyncInterval = .manual
        let course = ClassEnrollment(title: "Fictional astronomy")
        let repository = try XCTUnwrap(model.repository)
        try repository.update { $0.classes.append(course) }
        model.refresh()
        for scope: UUID? in [course.id, nil] {
            let session = model.chatSession(for: scope)
            session.draft = "Thanks!"
            session.send(in: model, using: profile)
            try await waitFor("local reply saved") { session.generation == nil }
            let messages = try XCTUnwrap(model.chatThread(classID: scope)?.messages)
            XCTAssertEqual(messages.map(\.content), ["Thanks!", "You’re welcome!"])
            XCTAssertEqual(messages.last?.agentIdentity, "LCP")
            XCTAssertEqual(messages.last?.usage?.totalTokens, 0)
            XCTAssertEqual(messages.last?.citations, [])
        }
    }

    func testDraftAndStreamingReplySurviveLeavingUniversityChat() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, course, _) = try makeWorkspace(at: root)
        model.selection = .universityChat
        let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceView(model: model)))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1260, height: 820))
        window.orderBack(nil)
        let content = try XCTUnwrap(window.contentView)
        let question = "What should I review for astronomy?"
        let classDraft = "Draft for the astronomy class only."
        let university = model.chatSession(for: nil)

        try await waitFor("university composer") { self.editor(in: content) != nil }
        try XCTUnwrap(editor(in: content)).insertText(question, replacementRange: NSRange(location: 0, length: 0))
        try await waitFor("typed draft") { university.draft == question }
        model.selectedClassSection = .chat
        model.selection = .classDetail(course.id)
        try await waitFor("empty class composer") { self.editor(in: content)?.string == "" }
        try XCTUnwrap(editor(in: content)).insertText(classDraft, replacementRange: NSRange(location: 0, length: 0))
        try await waitFor("separate class draft") { model.chatSession(for: course.id).draft == classDraft }

        model.selection = .universityChat
        try await waitFor("restored university composer") { self.editor(in: content)?.string == question }
        let sendKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: sendKey))
        try await waitFor("first streamed words") { university.generation?.update?.text == "Start with stars" }

        model.selection = .classDetail(course.id)
        try await waitFor("class draft while university reply is pending") { self.editor(in: content)?.string == classDraft }
        XCTAssertNil(model.chatSession(for: course.id).generation)
        model.selection = .universityChat
        try await waitFor("university composer reattached during streaming") {
            self.textView(in: content, matching: { $0.string.isEmpty }) != nil
        }
        XCTAssertEqual(university.generation?.question, question)
        XCTAssertEqual(university.generation?.update?.text, "Start with stars")
        XCTAssertEqual(university.generation?.providerName, "Fictional provider")

        model.selection = .review
        try await waitFor("chat left the window") { self.textView(in: content, matching: { _ in true }) == nil }
        XCTAssertEqual(PausedChatStream.requests.count, 1)
        try XCTUnwrap(PausedChatStream.requests.first).finish()
        try await waitFor("turn saved in the background") { university.generation == nil && model.chatThread(classID: nil)?.messages.count == 2 }
        model.selection = .universityChat
        try await waitFor("composer available for a follow-up") { self.editor(in: content)?.string == "" }

        let reopened = try ContextRepository(rootURL: root)
        let threads = try XCTUnwrap(reopened.state.chatThreads)
        XCTAssertEqual(threads.count, 1)
        XCTAssertNil(threads[0].classID)
        XCTAssertEqual(threads[0].messages.map(\.content), [question, "Start with stars and planets."])
        XCTAssertEqual(PausedChatStream.requests.count, 1)
        XCTAssertEqual(model.chatSession(for: course.id).draft, classDraft)
    }

    func testStopAndProviderFailureReturnDraftToOriginatingChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, course, profile) = try makeWorkspace(at: root)
        let session = model.chatSession(for: course.id)
        let attachment = root.appendingPathComponent("Fictional notes.md")
        try Data("Fictional stars".utf8).write(to: attachment)
        await session.attach([attachment])?.value
        let fileID = try XCTUnwrap(session.uploads.first?.id)
        XCTAssertTrue(session.automaticallyFileUploads)
        session.automaticallyFileUploads = false
        session.draft = "A question for class."
        session.send(in: model, using: profile)
        try await waitFor("stream before Stop") { session.generation?.update != nil }
        session.stop()
        try await waitFor("stopped") { session.generation == nil }
        XCTAssertEqual(session.draft, "A question for class.")
        XCTAssertTrue(session.status?.contains("cancelled") == true)
        XCTAssertEqual(session.uploads.map(\.id), [fileID])
        XCTAssertFalse(session.automaticallyFileUploads)
        XCTAssertTrue(model.chatSession(for: nil).uploads.isEmpty)
        session.send(in: model, using: profile)
        try await waitFor("second stream") { session.generation?.update != nil && PausedChatStream.requests.count == 2 }
        model.selection = .universityChat
        try XCTUnwrap(PausedChatStream.requests.last).fail()
        try await waitFor("failed reply") { session.generation == nil }
        XCTAssertEqual(session.draft, "A question for class.")
        XCTAssertNotNil(session.errorDetails)
        XCTAssertFalse(session.automaticallyFileUploads)
        XCTAssertNil(model.chatThread(classID: course.id))
        XCTAssertTrue(model.chatSession(for: nil).draft.isEmpty)
        session.send(in: model, using: profile)
        try await waitFor("retry stream") { PausedChatStream.requests.count == 3 }
        try XCTUnwrap(PausedChatStream.requests.last).finish()
        try await waitFor("new draft") { session.generation == nil && session.uploads.isEmpty }
        XCTAssertTrue(session.automaticallyFileUploads)
    }

    func testStreamingFollowsLatestUntilReaderScrollsUp() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, provider) = try makeWorkspace(at: root)
        model.selection = .universityChat
        let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceView(model: model)))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 980, height: 660))
        window.orderBack(nil)
        let content = try XCTUnwrap(window.contentView)
        let chat = model.chatSession(for: nil)
        try await waitFor("chat composer") { self.editor(in: content) != nil }
        chat.draft = "Explain each observation."
        chat.send(in: model, using: provider)
        try await waitFor("stream") { chat.generation?.update != nil }
        let stream = try XCTUnwrap(PausedChatStream.requests.first)
        let paragraphs = (1...80).map { "\n\nObservation \($0)." }.joined()
        try stream.appendText(paragraphs)
        var history: NSScrollView?
        func findHistory(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, (scroll.documentView?.bounds.height ?? 0) > 1_500 { return scroll }
            return view.subviews.lazy.compactMap { findHistory(in: $0) }.first
        }
        try await waitFor("rendered paragraphs") {
            history = findHistory(in: content)
            return history != nil
        }
        let scroll = try XCTUnwrap(history)
        let document = try XCTUnwrap(scroll.documentView)
        try await waitFor("following the rendered end") { document.bounds.maxY - scroll.documentVisibleRect.maxY < 24 }
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: 4_000, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        try await waitFor("reading the start") { scroll.documentVisibleRect.minY < 5 }
        let firstHeight = document.bounds.height
        try stream.appendText(paragraphs)
        try await waitFor("new paragraphs below the reader") { document.bounds.height > firstHeight + 300 }
        XCTAssertLessThan(scroll.documentVisibleRect.minY, 5)
        stream.finish()
        try await waitFor("saved response") { chat.generation == nil && model.chatThread(classID: nil)?.messages.count == 2 }
    }

    func testChangingLibraryDetachesDraftAndRunningRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = root.appendingPathComponent("Other")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, course, profile) = try makeWorkspace(at: root)
        let old = model.chatSession(for: nil)
        model.chatSession(for: course.id).draft = "Private to the first library"
        old.draft = "Where do I start?"
        old.send(in: model, using: profile)
        try await waitFor("stream in original library") { old.generation?.update != nil }
        model.repository = try ContextRepository(rootURL: other)
        model.rootURL = other
        model.refresh()
        try await waitFor("old request cancelled") { old.generation == nil }
        XCTAssertFalse(old === model.chatSession(for: nil))
        XCTAssertTrue(model.chatSession(for: nil).draft.isEmpty)
        XCTAssertTrue(model.chatSession(for: course.id).draft.isEmpty)
        XCTAssertNil(model.chatThread(classID: nil))
        XCTAssertNil(try ContextRepository(rootURL: root).state.chatThreads)
    }

    private func makeWorkspace(at root: URL) throws -> (WorkspaceModel, ClassEnrollment, AgentProviderProfile) {
        PausedChatStream.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PausedChatStream.self]
        let profile = AgentProviderProfile(name: "Fictional provider", baseURL: "https://example.invalid", model: "fixture")
        let providers = AgentProviders(profiles: { _ in [profile] }, apiKey: { _, _ in "fictional-key" },
                                      http: UniversityHTTP(configuration: config))
        let model = WorkspaceModel(arguments: ["--profile-root", root.path], agentProviders: providers)
        model.canvasSyncInterval = .manual
        let course = ClassEnrollment(title: "Fictional astronomy")
        let repository = try XCTUnwrap(model.repository)
        try repository.update { $0.classes.append(course) }
        model.refresh()
        return (model, course, profile)
    }

    private func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                         _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try XCTUnwrap(ready() ? true : nil, description, file: file, line: line)
    }

    private func editor(in view: NSView) -> NSTextView? {
        textView(in: view) { $0.isEditable }
    }

    private func textView(in view: NSView, matching predicate: (NSTextView) -> Bool) -> NSTextView? {
        if let text = view as? NSTextView, !text.isFieldEditor, predicate(text) { return text }
        for child in view.subviews {
            if let match = textView(in: child, matching: predicate) { return match }
        }
        return nil
    }
}

/// Delivers one delta, then waits for the test to finish or fail the request.
private final class PausedChatStream: URLProtocol, @unchecked Sendable {
    @MainActor static var requests: [PausedChatStream] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in Self.requests.append(self) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        sendEvent(#"{"type":"response.output_text.delta","delta":"Start with stars"}"#)
    }
    override func stopLoading() {}
    func appendText(_ text: String) throws {
        let data = try JSONEncoder().encode(["type": "response.output_text.delta", "delta": text])
        sendEvent(String(decoding: data, as: UTF8.self))
    }
    func finish() {
        sendEvent(#"{"type":"response.output_text.delta","delta":" and planets."}"#)
        sendEvent(#"{"type":"response.completed","response":{"usage":{"total_tokens":17}}}"#)
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    private func sendEvent(_ json: String) {
        client?.urlProtocol(self, didLoad: Data("data: \(json)\n\n".utf8))
    }
}

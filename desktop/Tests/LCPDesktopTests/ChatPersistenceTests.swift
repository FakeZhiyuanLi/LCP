import Foundation
import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

final class ChatPersistenceTests: XCTestCase {
    @MainActor
    func testFirstAndSubsequentRepliesPersistInBothChatScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        // A class name may be longer than a thread title, including in an older library.
        let course = ClassEnrollment(title: String(repeating: "天文学", count: 40))
        try repository.update { $0.classes.append(course) }
        model.refresh()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FictionalChatStream.self]
        let planner = ClassPlannerService(repository: repository, http: UniversityHTTP(configuration: configuration))
        let profile = AgentProviderProfile(name: "Fictional provider", baseURL: "https://example.invalid", model: "fixture")
        let usage = TokenUsage(totalTokens: 17)

        for scope: UUID? in [nil, course.id] {
            for number in 1...2 {
                let question = "Question \(number)"
                let trace = AgentRequestDiagnostics()
                let result = try await planner.generateChatStream(classIDs: [course.id], history: model.chatThread(classID: scope)?.messages ?? [],
                                                                  message: question, profile: profile, apiKey: "fictional-key",
                                                                  diagnostics: trace) { _ in }
                XCTAssertTrue(model.saveChatReply(classID: scope, question: question, result: result, profile: profile, diagnostics: trace))
                XCTAssertEqual(model.chatThread(classID: scope)?.messages.last?.contextRevision, result.context.repositoryRevision)
            }
        }

        let reopened = try ContextRepository(rootURL: root)
        let threads = try XCTUnwrap(reopened.state.chatThreads)
        XCTAssertEqual(threads.count, 2)
        for scope: UUID? in [nil, course.id] {
            let thread = try XCTUnwrap(threads.first { $0.classID == scope })
            XCTAssertEqual(thread, model.chatThread(classID: scope))
            XCTAssertLessThanOrEqual(thread.title.utf8.count, ChatThread.maximumTitleBytes)
            XCTAssertGreaterThanOrEqual(thread.updatedAt, thread.createdAt)
            XCTAssertEqual(thread.messages.map(\.role), [.user, .assistant, .user, .assistant])
            XCTAssertEqual(thread.messages.map(\.content), ["Question 1", "Fictional answer", "Question 2", "Fictional answer"])
            XCTAssertEqual(thread.messages.last?.usage, usage)
        }
    }

    @MainActor
    func testLongChatAndFileOnlyTurnsPreserveOriginalsAndHonorPerMessageFiling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repo = try XCTUnwrap(model.repository)
        let course = ClassEnrollment(title: "Fictional astronomy")
        try repo.update { $0.classes = [course] }
        model.refresh()
        let session = model.chatSession(for: nil)
        let bytes = Data("Fictional astronomical tables.".utf8)
        let url = root.appendingPathComponent("Tables.md")
        try bytes.write(to: url)
        await session.attach([url])
        let upload = try XCTUnwrap(session.uploads.first)
        XCTAssertTrue(session.canSend, "A file can start a turn on its own.")
        XCTAssertTrue(model.chatSession(for: course.id).uploads.isEmpty)
        try FileManager.default.removeItem(at: url)
        let profile = AgentProviderProfile(name: "Fixture", baseURL: "https://example.invalid", model: "test")
        let context = try ClassPlannerService(repository: repo).makeContext(classIDs: [course.id])
        let suggestion = ChatFilingSuggestion(attachmentID: upload.id, classID: course.id, title: "Astronomical tables", reason: "Study reference")
        let result = ClassPlanResult(response: .init(text: "File reviewed.", filingSuggestions: [suggestion]),
                                     context: context, uploads: [upload])
        let trace = AgentRequestDiagnostics()
        XCTAssertTrue(model.saveChatReply(classID: nil, question: "", result: result, profile: profile, diagnostics: trace))
        var thread = try XCTUnwrap(model.chatThread(classID: nil))
        XCTAssertEqual(thread.messages[0].attachments?.first?.suggestion, suggestion)
        XCTAssertTrue(repo.state.materials.isEmpty)
        try ChatFilingTool.file(upload.id, from: thread.id, to: course.id, in: repo)
        try ChatFilingTool.file(upload.id, from: thread.id, to: course.id, in: repo)
        XCTAssertEqual(repo.state.materials.count, 1)
        XCTAssertEqual(try repo.payloadData(upload.attachment.original), bytes)

        let another = root.appendingPathComponent("Second.md")
        try Data("A different fictional handout.".utf8).write(to: another)
        let second = try ChatUpload.read(another)
        let next = ChatFilingSuggestion(attachmentID: second.id, classID: course.id, title: "Second", reason: "Reference")
        let auto = ClassPlanResult(response: .init(text: "Reviewed.", filingSuggestions: [next]), context: context, uploads: [second])
        let longQuestion = String(repeating: "星\t", count: 100_000) + "last character"
        let nextTrace = AgentRequestDiagnostics()
        for _ in 0..<2 {
            XCTAssertTrue(model.saveChatReply(classID: course.id, question: longQuestion, result: auto, profile: profile,
                                              diagnostics: nextTrace, automaticallyFileUploads: true))
        }
        thread = try XCTUnwrap(model.chatThread(classID: course.id))
        XCTAssertEqual(thread.messages.count, 2)
        XCTAssertEqual(thread.messages[0].content, longQuestion)
        XCTAssertNotNil(thread.messages[0].attachments?.first?.savedMaterialID)
        XCTAssertEqual(repo.state.materials.count, 2)
        let backup = root.appendingPathComponent("Backup")
        try repo.exportBackup(to: backup)
        let restored = try ContextRepository(rootURL: root.appendingPathComponent("Restored"))
        try restored.restoreBackup(from: backup)
        XCTAssertEqual(restored.state.chatThreads, repo.state.chatThreads)
        XCTAssertEqual(try restored.payloadData(second.attachment.original), try Data(contentsOf: another))
    }

    @MainActor
    func testFailedCitationCommitKeepsCompletedReplyForOneLocalSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        let course = ClassEnrollment(title: "Fictional astronomy")
        try repository.update { $0.classes.append(course) }
        let note = root.appendingPathComponent("Fictional.md")
        try Data("Fictional notes about stars.".utf8).write(to: note)
        _ = try MaterialService(repository: repository).importMaterial(from: note, classID: course.id)
        model.refresh()
        let profile = AgentProviderProfile(name: "Fictional provider", baseURL: "https://example.invalid", model: "fixture")
        let context = try ClassPlannerService(repository: repository).makeContext(classIDs: [course.id])
        XCTAssertFalse(context.sourceCitations.isEmpty)
        let result = ClassPlanResult(response: .init(text: "A completed reply."), context: context)
        let reference = try XCTUnwrap(repository.state.materialRevisions.first?.original)
        let payload = try repository.payloadURL(reference)
        let offline = root.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: payload, to: offline)
        let revision = repository.state.revision
        let diagnostics = AgentRequestDiagnostics()

        XCTAssertFalse(model.saveChatReply(classID: nil, question: "Question", result: result, profile: profile, diagnostics: diagnostics))
        XCTAssertEqual(repository.state.revision, revision)
        XCTAssertNil(try ContextRepository(rootURL: root).state.chatThreads)
        XCTAssertNil(model.errorMessage)
        let pending = try XCTUnwrap(model.unsavedChatReplies[nil])
        XCTAssertEqual(pending.result, result)
        XCTAssertTrue(pending.errorDetails.contains("Stage: save"))
        XCTAssertTrue(pending.errorDetails.contains("Reason: "))
        XCTAssertFalse(pending.errorDetails.contains(offline.path))
        XCTAssertFalse(pending.errorDetails.contains(result.response.text))

        try FileManager.default.moveItem(at: offline, to: payload)
        for _ in 0..<2 {
            XCTAssertTrue(model.saveChatReply(classID: nil, question: pending.question, result: pending.result,
                                              profile: pending.profile, diagnostics: pending.diagnostics))
        }
        XCTAssertNil(model.unsavedChatReplies[nil])
        let reopened = try ContextRepository(rootURL: root)
        XCTAssertEqual(reopened.state.revision, revision + 1)
        let thread = try XCTUnwrap(reopened.state.chatThreads?.first)
        XCTAssertEqual(thread.messages.map(\.content), ["Question", "A completed reply."])
        XCTAssertEqual(thread.messages.last?.citations, context.sourceCitations)
    }
}

private final class FictionalChatStream: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let stream = """
        data: {"type":"response.output_text.delta","delta":"Fictional answer"}

        data: {"type":"response.completed","response":{"usage":{"total_tokens":17}}}


        """
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

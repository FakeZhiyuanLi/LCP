import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

@MainActor
final class ChatThreadsTests: XCTestCase {
    func testLatestChatIsSelectedAndNewChatsKeepTheirOwnDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        let course = ClassEnrollment(title: "Fictional astronomy")
        try repository.update { state in
            state.classes = [course]
            state.chatThreads = [
                ChatThread(classID: course.id, title: "Earlier question", createdAt: Date(timeIntervalSince1970: 10),
                           updatedAt: Date(timeIntervalSince1970: 10), messages: [ChatMessage(role: .user, content: "Earlier", contextClassIDs: [course.id])]),
                ChatThread(classID: course.id, title: "Latest question", createdAt: Date(timeIntervalSince1970: 20),
                           updatedAt: Date(timeIntervalSince1970: 20), messages: [ChatMessage(role: .user, content: "Latest", contextClassIDs: [course.id])]),
            ]
        }
        model.refresh()

        let threads = model.chatThreads(for: course.id)
        let latest = try XCTUnwrap(threads.first)
        let earlier = try XCTUnwrap(threads.last)
        let session = model.chatSession(for: course.id)
        XCTAssertEqual(session.selectedThreadID, latest.id)
        XCTAssertEqual(model.chatThread(classID: course.id, threadID: latest.id)?.messages.first?.content, "Latest")

        session.draft = "Draft for the latest chat"
        XCTAssertTrue(model.selectChat(classID: course.id, threadID: earlier.id))
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.selectedThreadID, earlier.id)

        XCTAssertTrue(model.startNewChat(classID: course.id))
        XCTAssertNil(session.selectedThreadID)
        XCTAssertTrue(session.draft.isEmpty)
        XCTAssertTrue(model.selectChat(classID: course.id, threadID: latest.id))
        XCTAssertEqual(session.draft, "Draft for the latest chat")
        XCTAssertEqual(session.selectedThreadID, latest.id)
    }

    func testFirstReplyInNewChatCreatesAndSelectsASeparateThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        let course = ClassEnrollment(title: "Fictional astronomy")
        try repository.update { $0.classes = [course] }
        model.refresh()

        let session = model.chatSession(for: course.id)
        let context = try ClassPlannerService(repository: repository).makeContext(classIDs: [course.id])
        let result = ClassPlanResult(response: .init(text: "A separate answer."), context: context)
        let profile = AgentProviderProfile(name: "Fictional provider", baseURL: "https://example.invalid", model: "fixture")
        let diagnostics = AgentRequestDiagnostics()

        XCTAssertTrue(model.startNewChat(classID: course.id))
        let transientID = session.conversationIDForSaving
        session.saveReply(in: model, question: "A fresh question", result: result, profile: profile, diagnostics: diagnostics)

        let saved = try XCTUnwrap(model.chatThread(classID: course.id, threadID: transientID))
        XCTAssertEqual(saved.messages.map(\.content), ["A fresh question", "A separate answer."])
        XCTAssertEqual(session.selectedThreadID, transientID)
        XCTAssertEqual(model.chatThreads(for: course.id).count, 1)
    }
}

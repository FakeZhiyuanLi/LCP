import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

@MainActor
final class ChatHistoryTests: XCTestCase {
    func testHistoryCombinesScopesAndSortsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        let classID = UUID()
        let classEnrollment = ClassEnrollment(id: classID, courseCode: "ASTRO 101", title: "Fictional Astronomy")
        let earlier = ChatThread(classID: classID, title: "Earlier class question",
                                 createdAt: Date(timeIntervalSince1970: 10),
                                 updatedAt: Date(timeIntervalSince1970: 10),
                                 messages: [ChatMessage(role: .user, content: "Earlier", contextClassIDs: [classID])])
        let university = ChatThread(classID: nil, title: "University planning",
                                    createdAt: Date(timeIntervalSince1970: 20),
                                    updatedAt: Date(timeIntervalSince1970: 30),
                                    messages: [ChatMessage(role: .user, content: "Latest university question")])
        let latest = ChatThread(classID: classID, title: "Latest class question",
                                createdAt: Date(timeIntervalSince1970: 25),
                                updatedAt: Date(timeIntervalSince1970: 25),
                                messages: [ChatMessage(role: .user, content: "Latest class question", contextClassIDs: [classID])])
        try repository.update { state in
            state.classes = [classEnrollment]
            state.chatThreads = [earlier, university, latest]
        }
        model.refresh()

        XCTAssertEqual(model.chatHistoryThreads.map(\.title), [
            "University planning", "Latest class question", "Earlier class question"
        ])
        XCTAssertEqual(model.chatScopeLabel(for: university), "University")
        XCTAssertEqual(model.chatScopeLabel(for: latest), "ASTRO 101 · Fictional Astronomy")
    }

    func testOpeningClassHistorySelectsClassChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        let enrollment = ClassEnrollment(courseCode: "ASTRO 101", title: "Fictional Astronomy")
        let thread = ChatThread(classID: enrollment.id, title: "Review orbit notes",
                                messages: [ChatMessage(role: .user, content: "Review orbit notes", contextClassIDs: [enrollment.id])])
        try repository.update { state in
            state.classes = [enrollment]
            state.chatThreads = [thread]
        }
        model.refresh()

        XCTAssertTrue(model.openChatHistoryThread(thread))
        XCTAssertEqual(model.selection, .classDetail(enrollment.id))
        XCTAssertEqual(model.selectedClassSection, .chat)
        XCTAssertEqual(model.chatSession(for: enrollment.id).selectedThreadID, thread.id)
    }

    func testOpeningUniversityHistorySelectsUniversityChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        let thread = ChatThread(classID: nil, title: "Plan the week",
                                messages: [ChatMessage(role: .user, content: "Plan the week")])
        try repository.update { $0.chatThreads = [thread] }
        model.refresh()

        XCTAssertTrue(model.openChatHistoryThread(thread))
        XCTAssertEqual(model.selection, .universityChat)
        XCTAssertEqual(model.chatSession(for: nil).selectedThreadID, thread.id)
    }

    func testMissingClassStillHasAHistoryLabel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let thread = ChatThread(classID: UUID(), title: "Orphaned conversation")
        model.state.chatThreads = [thread]

        XCTAssertEqual(model.chatScopeLabel(for: thread), "Class unavailable")
        XCTAssertTrue(model.chatHistoryThreads.contains(thread))
        XCTAssertFalse(model.openChatHistoryThread(thread))
        XCTAssertEqual(model.notice, "This chat's class is no longer available in the library.")
    }
}

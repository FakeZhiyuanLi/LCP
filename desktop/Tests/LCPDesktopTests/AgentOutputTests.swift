import AppKit
import SwiftUI
import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

final class AgentOutputTests: XCTestCase {
    func testExistingMarkdownGetsHeadingsListsEmphasisLinksAndCode() throws {
        let blocks = AgentOutputBlock.parse("""
        ## Priority plan

        Check **Homework 8** on [Canvas](https://example.edu/assignment).

        1. Open the course
        2. Review the lab

        - Read the slides

        [Local](file:///tmp/fictional) and [custom](other://handler)

        ```swift
        print("example")
        ```
        """)
        guard case let .text(title, level, _, _, _) = blocks.first else { return XCTFail("Missing heading") }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(String(title.characters), "Priority plan")
        guard case let .text(paragraph, _, _, _, _) = blocks[1] else { return XCTFail("Missing paragraph") }
        XCTAssertTrue(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(paragraph.runs.compactMap(\.link), [URL(string: "https://example.edu/assignment")!])
        let markers = blocks.compactMap { block -> String? in
            guard case .text(_, _, let marker, _, _) = block else { return nil }
            return marker
        }
        XCTAssertEqual(markers, ["1.", "2.", "•"])
        guard case let .text(unsafe, _, _, _, _) = blocks[5] else { return XCTFail("Missing link labels") }
        XCTAssertTrue(unsafe.runs.compactMap(\.link).isEmpty)
        XCTAssertEqual(blocks.last, .code("print(\"example\")"))
        XCTAssertFalse(AgentOutputBlock.allowsLink(URL(string: "lcp://other/action")!))
    }

    @MainActor
    func testVisualsReopenInChatAndSavedClassPlans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.path])
        let repository = try XCTUnwrap(model.repository)
        let course = ClassEnrollment(title: "Fictional astronomy")
        try repository.update { $0.classes.append(course) }
        model.refresh()
        let chart = try AgentDisplayTool.barChart.render(arguments: Data(#"{"title":"Practice time","unit":"minutes","items":[{"label":"Reading","value":10},{"label":"Lab","value":25}]}"#.utf8))
        let timeline = try AgentDisplayTool.timeline.render(arguments: Data(#"{"title":"Suggested study order","items":[{"label":"Review","detail":"Read the notes."},{"label":"Practice","detail":"Try two questions."}]}"#.utf8))
        let text = try ["## Study plan", chart.markdown(), timeline.markdown()].joined(separator: "\n\n")
        let context = try ClassPlannerService(repository: repository).makeContext(classIDs: [course.id])
        let profile = AgentProviderProfile(name: "Fictional agent", baseURL: "https://example.invalid", model: "fixture")
        let result = ClassPlanResult(response: .init(text: text), context: context)
        model.saveAgentPlan(classIDs: [course.id], objective: "Make a plan", plan: text, profile: profile, context: context)
        XCTAssertTrue(model.saveChatReply(classID: nil, question: "Make a plan", result: result, profile: profile, diagnostics: .init()))
        let reopened = try ContextRepository(rootURL: root)
        let chat = try XCTUnwrap(reopened.state.chatThreads?.first?.messages.last)
        let activity = try XCTUnwrap(reopened.state.activities.first)
        for body in [activity.body, chat.content] {
            let graphics = AgentOutputBlock.parse(body).compactMap { block -> AgentVisual? in
                if case .visual(let v) = block { return v }
                return nil
            }
            XCTAssertEqual(graphics, [chart, timeline])
        }
        XCTAssertEqual(activity.agentIdentity, profile.name)
    }

    func testTableAndUnknownVisualRemainReadable() {
        let source = "| Task | Minutes |\n| --- | --- |\n| Lab | 30 |\n\n```lcp-visual\n{\"version\":9}\n```"
        let blocks = AgentOutputBlock.parse(source)
        guard case .table(let rows) = blocks.first else { return XCTFail("Missing table") }
        XCTAssertEqual(rows.map { $0.map { String($0.characters) } }, [["Task", "Minutes"], ["Lab", "30"]])
        XCTAssertEqual(blocks.last, .code("{\"version\":9}"))
    }
}

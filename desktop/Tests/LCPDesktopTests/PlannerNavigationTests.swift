import AppKit
import SwiftUI
import XCTest
import LCPContextCore
import LCPContextServices
@testable import LCPDesktop

@MainActor
final class PlannerNavigationTests: XCTestCase {
    func testClassSectionFollowsNavigationAndShowsTheDestinationClass() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, first, _) = try workspace(at: root)
        let second = try XCTUnwrap(model.activeClasses.first { $0.id != first.id })
        let firstObjective = "Review the rules of inference."
        let secondObjective = "Compare the narrators."
        model.plannerSession(for: first.id).objective = firstObjective
        model.plannerSession(for: second.id).objective = secondObjective
        model.selection = .classDetail(first.id)
        model.selectedClassSection = .planner

        let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceView(model: model)))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1260, height: 820))
        window.orderBack(nil)
        let content = try XCTUnwrap(window.contentView)
        try await waitFor("first class plan") { self.containsEditor(firstObjective, in: content) }

        model.selection = .classDetail(second.id)
        try await waitFor("second class plan") { self.containsEditor(secondObjective, in: content) }
        model.selection = .welcome
        try await waitFor("left the second class") { !self.containsEditor(secondObjective, in: content) }
        model.selection = .classDetail(first.id)
        try await waitFor("returned to first class plan") { self.containsEditor(firstObjective, in: content) }
    }

    func testUniversityAndClassRequestsCompleteWhileTheirTabsAreClosed() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, course, profile) = try workspace(at: root)
        model.selection = .planner
        let window = NSWindow(contentViewController: NSHostingController(rootView: WorkspaceView(model: model)))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 1260, height: 820))
        window.orderBack(nil)

        let university = model.plannerSession(for: nil)
        let individual = model.plannerSession(for: course.id)
        university.selectClasses([course.id])
        university.objective = "Plan my week using the inference notes."
        let content = try XCTUnwrap(window.contentView)
        try await waitFor("university planner appears with its draft and provider") {
            university.selectedProfileID == profile.id && self.containsEditor(university.objective, in: content)
        }
        university.generate(in: model, using: profile)
        try await waitFor("the university request") { HeldPlannerReply.requests.count == 1 }
        XCTAssertTrue(university.isGenerating)

        individual.objective = "Prepare a truth table."
        model.selectedClassSection = .planner
        model.selection = .classDetail(course.id)
        try await waitFor("class planner appears with its own draft") {
            individual.selectedProfileID == profile.id && self.containsEditor(individual.objective, in: content)
        }
        individual.generate(in: model, using: profile)
        try await waitFor("the separate class request") { HeldPlannerReply.requests.count == 2 }
        model.selectedClassSection = .chat
        try await waitFor("class Plan tab replaced by Chat") { !self.containsEditor(individual.objective, in: content) }
        HeldPlannerReply.requests[1].finish(action: "Draw the table for class.")
        try await waitFor("class plan completed behind Chat") { individual.plan != nil }

        model.selection = .planner
        try await waitFor("pending university request on return") {
            university.isGenerating && self.containsEditor(university.objective, in: content)
        }
        XCTAssertEqual(university.selectedClassIDs, [course.id])
        XCTAssertEqual(university.selectedProfileID, profile.id)
        XCTAssertEqual(university.objective, "Plan my week using the inference notes.")
        university.generate(in: model, using: profile)
        XCTAssertEqual(HeldPlannerReply.requests.count, 2)

        model.selectedClassSection = .planner
        model.selection = .classDetail(course.id)
        try await waitFor("class planner restored") { self.containsEditor(individual.objective, in: content) }
        XCTAssertTrue(individual.plan?.result.response.text.contains("Draw the table for class.") == true)
        HeldPlannerReply.requests[0].finish(action: "Work through the weekly inference exercise.")
        try await waitFor("university plan completed behind the class tab") { university.plan != nil }
        XCTAssertEqual(model.state.activities.filter { $0.kind == "agent_plan" }.count, 0)
        model.selection = .planner
        try await waitFor("university planner restored") { self.containsEditor(university.objective, in: content) }
        let completed = try XCTUnwrap(model.plannerSession(for: nil).plan)
        XCTAssertEqual(completed.objective, university.objective)
        XCTAssertEqual(completed.result.context.classIDs, [course.id])
        XCTAssertTrue(completed.result.response.text.contains("Work through the weekly inference exercise."))
        XCTAssertFalse(completed.result.response.text.contains("Draw the table for class."))
        XCTAssertEqual(HeldPlannerReply.requests.count, 2)
        XCTAssertEqual(individual.plan?.objective, "Prepare a truth table.")
    }

    func testSwitchingLibrariesCancelsTheOldRequestAndDetachesBothPlanners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, course, profile) = try workspace(at: root)
        let old = model.plannerSession(for: nil)
        let individual = model.plannerSession(for: course.id)
        individual.objective = "Draft for the original class."
        old.selectClasses([])
        model.selection = .review
        model.selection = .planner
        XCTAssertTrue(model.plannerSession(for: nil).classIDs(in: model).isEmpty)
        old.selectClasses([course.id])
        old.generate(in: model, using: profile)
        try await waitFor("request started in the original library") { HeldPlannerReply.requests.count == 1 }
        let other = root.appendingPathComponent("Other")
        model.repository = try ContextRepository(rootURL: other)
        model.rootURL = other
        model.refresh()
        try await waitFor("old request stopped") { !old.isGenerating }
        XCTAssertNil(old.plan)
        XCTAssertFalse(model.plannerSession(for: nil) === old)
        XCTAssertFalse(model.plannerSession(for: course.id) === individual)
        XCTAssertNil(model.plannerSession(for: nil).status)
        XCTAssertEqual(HeldPlannerReply.requests.count, 1)
    }

    private func workspace(at root: URL) throws -> (WorkspaceModel, ClassEnrollment, AgentProviderProfile) {
        HeldPlannerReply.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldPlannerReply.self]
        let profile = AgentProviderProfile(name: "Fictional tutor", baseURL: "https://planner.example.invalid/v1", model: "fixture")
        let providers = AgentProviders(profiles: { _ in [profile] }, apiKey: { _, _ in "fictional-key" },
                                       http: UniversityHTTP(configuration: configuration))
        let model = WorkspaceModel(arguments: ["--profile-root", root.path], agentProviders: providers)
        model.canvasSyncInterval = .manual
        let course = ClassEnrollment(title: "Fictional logic")
        let repo = try XCTUnwrap(model.repository)
        try repo.update {
            $0.classes = [course, ClassEnrollment(title: "Fictional literature")]
            $0.activities.append(ActivityEntry(classID: course.id, title: "Inference notes", body: "Construct a truth table."))
        }
        model.refresh()
        return (model, course, profile)
    }

    private func containsEditor(_ text: String, in view: NSView) -> Bool {
        if let editor = view as? NSTextView, !editor.isFieldEditor, editor.string == text { return true }
        return view.subviews.contains { containsEditor(text, in: $0) }
    }

    private func waitFor(_ label: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try XCTUnwrap(condition() ? true : nil, label, file: file, line: line)
    }
}

private final class HeldPlannerReply: URLProtocol, @unchecked Sendable {
    @MainActor static var requests: [HeldPlannerReply] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "planner.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Task { @MainActor in Self.requests.append(self) } }
    override func stopLoading() {}

    func finish(action: String) {
        let step = ["source": "S1", "action": action, "why": "Practice the inference exercise.",
                    "doneWhen": "each row is complete.", "evidence": "truth table"]
        let answer = try! JSONEncoder().encode(["steps": [step]])
        let data = try! JSONEncoder().encode(["output_text": String(decoding: answer, as: UTF8.self)])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

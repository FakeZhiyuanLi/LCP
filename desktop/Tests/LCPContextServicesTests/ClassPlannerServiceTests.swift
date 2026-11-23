import Foundation
import XCTest
import LCPContextCore
@testable import LCPContextServices

private final class PlannerProviderFixtureProtocol: URLProtocol {
    static var requestBody: [String: Any] = [:]
    static var plannerReply = #"{"steps":[{"source":"S1","action":"Draw a collision chain and an open-addressed table for the same keys.","why":"The handout compares two ways to handle collisions.","doneWhen":"you can explain both collision paths.","evidence":"chaining and open addressing","minutes":15}]}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let data = request.httpBody ?? streamData(request.httpBodyStream),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.requestBody = object
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let input = Self.requestBody["input"] as? String ?? ""
        let answer = input.contains("<lcp_context>") && !input.contains("persistent study companion") ? Self.plannerReply : "Plan fixture"
        let body = try! JSONSerialization.data(withJSONObject: ["id": "planner_fixture", "output_text": answer])
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private func streamData(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class ClassPlannerServiceTests: XCTestCase {
    @MainActor
    private func listing(_ repository: ContextRepository, course: ClassEnrollment, path: String, title: String,
                         due: Date?, parent: Int64? = nil, status: CanvasSubmissionState? = nil,
                         instructions: String = "Write two answers using the lecture notes.") throws -> SourceMaterial {
        let url = URL(string: "https://canvas.eee.uci.edu/courses/70/" + path)!
        let facts = ImportedCourseworkContext(title: title, kind: path.hasPrefix("quizzes/") ? "quiz" : "assignment",
                                             dueAt: due, assignmentID: parent, submissionState: status)
        let document = UniversityDocument(filename: title + ".txt", data: Data("\(title)\n\(url.absoluteString)\n\n\(instructions)".utf8),
                                          sourceURL: url, courseworkContext: facts)
        return try MaterialService(repository: repository).importUniversityDocument(document, classID: course.id,
            provider: "uci-canvas", remoteID: "70/" + path, title: title)
    }

    @MainActor
    func testUnacceptedCanvasDeadlinesAreScopedRankedAndPairedWithoutMarkingUnknownWorkLate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let course = ClassEnrollment(title: "Fictional Logic")
        let other = ClassEnrollment(title: "Fictional Design")
        try repository.update { $0.classes = [course, other] }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstDue = now.addingTimeInterval(3_600), later = now.addingTimeInterval(86_400)
        let first = try listing(repository, course: course, path: "assignments/1", title: "Check-in", due: firstDue)
        _ = try listing(repository, course: course, path: "quizzes/11", title: "Check-in", due: firstDue)
        _ = try listing(repository, course: course, path: "assignments/2", title: "Proof draft", due: later)
        _ = try listing(repository, course: course, path: "quizzes/12", title: "Alternate quiz name", due: nil, parent: 2)
        _ = try listing(repository, course: course, path: "assignments/3", title: "Old unknown", due: now.addingTimeInterval(-60))
        _ = try listing(repository, course: course, path: "assignments/4", title: "Missing outline", due: now.addingTimeInterval(-60), status: .missing)
        _ = try listing(repository, course: course, path: "assignments/5", title: "Submitted outline", due: firstDue, status: .submitted)
        _ = try listing(repository, course: course, path: "assignments/6", title: "Optional practice", due: now.addingTimeInterval(60))
        _ = try listing(repository, course: other, path: "assignments/1", title: "Outside this scope", due: now)

        let planner = ClassPlannerService(repository: repository)
        let context = try planner.makeContext(classIDs: [course.id], now: now)
        XCTAssertEqual(context.planningSources.map(\.title), ["Check-in", "Proof draft", "Missing outline", "Optional practice"])
        XCTAssertEqual(planner.courseworkPreview(classIDs: [course.id], objective: "", now: now).map(\.id), context.planningSources.map(\.id))
        let item = try XCTUnwrap(context.planningSources.first)
        XCTAssertEqual(item.id, first.id)
        XCTAssertEqual(item.kind, "quiz")
        XCTAssertEqual(item.progress, "Submission status unknown")
        XCTAssertEqual(item.excerpt, "Write two answers using the lecture notes.")
        XCTAssertEqual(item.citation?.revisionID, first.currentRevisionID)
        let passage = try RetrievalService(repository: repository).resolve(XCTUnwrap(item.citation))
        XCTAssertTrue(passage.text.contains(item.excerpt))
        XCTAssertTrue(context.sourceCitations.allSatisfy { $0.classID == course.id })
        XCTAssertTrue(repository.state.coursework.isEmpty)

        let service = CourseworkService(repository: repository)
        let saved = try service.accept(service.reviewCanvasMaterial(first.id))
        try repository.update { state in
            state.coursework[state.coursework.firstIndex(where: { $0.id == saved.id })!].status = "completed"
        }
        let after = try planner.makeContext(classIDs: [course.id], now: now)
        XCTAssertFalse(after.planningSources.contains { $0.title == "Check-in" })
    }

    @MainActor
    func testDateOnlyWorkStaysCurrentThroughTheClassDayAndUsesNoInventedTime() throws {
        let course = ClassEnrollment(title: "Fictional course")
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let item = PlannerCoursework(id: UUID(), course: course, title: "Outline", kind: "assignment", zone: zone,
            due: .dateOnly(LocalDate(year: 2027, month: 1, day: 20)), canvas: nil, personal: [], citation: nil, sourceURL: nil)
        let parser = ISO8601DateFormatter()
        let endOfDay = try XCTUnwrap(parser.date(from: "2027-01-21T07:59:59Z"))
        XCTAssertFalse(item.deadline(at: endOfDay).past)
        XCTAssertTrue(item.deadline(at: endOfDay.addingTimeInterval(1)).past)
        XCTAssertTrue(item.deadline(at: endOfDay).label.contains("date only"))
    }

    @MainActor
    func testPlannerCapsSourceBytesAndFocusedReviewUsesTheMatchingMaterial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let course = ClassEnrollment(title: "Fictional Algorithms")
        try repository.update { $0.classes.append(course) }
        let longText = String(repeating: "A fictional task with multibyte text 例. ", count: 100)
        let now = Date.now
        for index in 1...20 {
            _ = try listing(repository, course: course, path: "assignments/\(index)", title: "Worksheet \(index)",
                            due: now.addingTimeInterval(Double(index * 3600)), instructions: longText)
        }
        let notes = root.appendingPathComponent("Collision notes.md")
        try Data("Use chaining to resolve hash collisions.".utf8).write(to: notes)
        let material = try MaterialService(repository: repository).importMaterial(from: notes, classID: course.id)
        let planner = ClassPlannerService(repository: repository)
        let objective = "Help me review hash collisions"
        for maximum in [4_096, 1_000_000] {
            let context = try planner.makeContext(classIDs: [course.id], objective: objective, maxBytes: maximum, now: now)
            XCTAssertLessThanOrEqual(context.markdown.utf8.count, min(maximum, ClassPlannerService.planContextByteLimit))
            XCTAssertTrue(context.sourceCitations.contains { $0.sourceID == material.id })
            let local = StudyPlanResponse.localPlan(context.planningSources, objective: objective)
            XCTAssertTrue(local.contains("Collision notes"))
            XCTAssertFalse(local.contains("Worksheet"))
        }
    }

    @MainActor
    func testPlannerContextIncludesClassMaterialsAndHistoryWithoutWritingAnExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LCP-Planner-Test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let enrollment = ClassEnrollment(courseCode: "SYN 46", title: "Synthetic Algorithms")
        try repository.update { state in
            state.classes.append(enrollment)
            state.activities.append(ActivityEntry(classID: enrollment.id, title: "Review queues", body: "Compare the queue implementations before Friday."))
        }
        let materialURL = root.deletingLastPathComponent().appendingPathComponent("planner-handout-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: materialURL) }
        try Data("# Hash tables\n\nReview chaining and open addressing.".utf8).write(to: materialURL)
        _ = try MaterialService(repository: repository).importMaterial(from: materialURL, classID: enrollment.id)

        let planner = ClassPlannerService(repository: repository)
        let context = try planner.makeContext(classIDs: [enrollment.id], maxBytes: 128 * 1_024)

        XCTAssertEqual(context.classIDs, [enrollment.id])
        XCTAssertEqual(context.sourceCount, 2)
        XCTAssertEqual(context.sourceCitations.count, 2)
        XCTAssertTrue(context.markdown.contains("Hash tables"))
        XCTAssertTrue(context.markdown.contains("Review queues"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planner-context").path))
    }

    @MainActor
    func testPlannerContextScopesMultipleClassesAndKeepsTheirCitations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LCP-Planner-Multi-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let first = ClassEnrollment(courseCode: "SYN 46", title: "Synthetic Algorithms")
        let second = ClassEnrollment(courseCode: "SYN 9", title: "Synthetic Literature")
        try repository.update { state in
            state.classes.append(contentsOf: [first, second])
            state.activities.append(ActivityEntry(classID: first.id, title: "Algorithms note", body: "Review hashing before the next meeting."))
            state.activities.append(ActivityEntry(classID: second.id, title: "Literature note", body: "Compare the two fictional narrators."))
        }
        let firstURL = root.deletingLastPathComponent().appendingPathComponent("planner-first-\(UUID().uuidString).md")
        let secondURL = root.deletingLastPathComponent().appendingPathComponent("planner-second-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try Data("# Algorithms\n\nHashing notes.".utf8).write(to: firstURL)
        try Data("# Literature\n\nNarrator notes.".utf8).write(to: secondURL)
        _ = try MaterialService(repository: repository).importMaterial(from: firstURL, classID: first.id)
        _ = try MaterialService(repository: repository).importMaterial(from: secondURL, classID: second.id)

        let context = try ClassPlannerService(repository: repository).makeContext(classIDs: [first.id, second.id], maxBytes: 256 * 1_024)

        XCTAssertEqual(context.classIDs, [first.id, second.id])
        XCTAssertEqual(Set(context.classLabels), Set(["SYN 46: Synthetic Algorithms", "SYN 9: Synthetic Literature"]))
        XCTAssertTrue(context.markdown.contains("Algorithms note"))
        XCTAssertTrue(context.markdown.contains("Literature note"))
        XCTAssertTrue(context.markdown.contains("Hashing notes"))
        XCTAssertTrue(context.markdown.contains("Narrator notes"))
        XCTAssertGreaterThanOrEqual(context.sourceCount, 4)
        XCTAssertFalse(context.sourceCitations.isEmpty)
        XCTAssertTrue(context.sourceCitations.allSatisfy { [first.id, second.id].contains($0.classID) })
        XCTAssertTrue(context.sourceCitations.contains { $0.classID == first.id })
        XCTAssertTrue(context.sourceCitations.contains { $0.classID == second.id })
    }

    @MainActor
    func testGenerateSendsTheReviewedContextAndReturnsTheProviderAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LCP-Planner-Generate-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let enrollment = ClassEnrollment(courseCode: "SYN 46", title: "Synthetic Algorithms")
        try repository.update { $0.classes.append(enrollment) }
        let materialURL = root.deletingLastPathComponent().appendingPathComponent("planner-generate-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: materialURL) }
        try Data("# Hash tables\n\nReview chaining and open addressing.".utf8).write(to: materialURL)
        _ = try MaterialService(repository: repository).importMaterial(from: materialURL, classID: enrollment.id)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerProviderFixtureProtocol.self]
        let service = ClassPlannerService(
            repository: repository,
            http: UniversityHTTP(configuration: configuration))
        let profile = AgentProviderProfile(name: "Fixture", baseURL: "https://provider.example/v1", model: "fixture-model")
        let result = try await service.generate(classIDs: [enrollment.id], objective: "Prepare for the exam", profile: profile, apiKey: "fixture-key")

        XCTAssertFalse(result.isLocalReply)
        XCTAssertTrue(result.response.text.contains("Draw a collision chain"))
        XCTAssertTrue(result.response.text.contains("**Done when** you can explain both collision paths."))
        let citation = try XCTUnwrap(result.context.sourceCitations.first)
        XCTAssertTrue(result.response.text.contains(CitationLink.url(for: citation).absoluteString))
        XCTAssertNil(PlannerProviderFixtureProtocol.requestBody["tools"])
        let prompt = try XCTUnwrap(PlannerProviderFixtureProtocol.requestBody["input"] as? String)
        XCTAssertTrue(prompt.contains("Prepare for the exam"))
        XCTAssertTrue(prompt.contains("Hash tables"))
        XCTAssertTrue(prompt.contains("untrusted study data"))

        let original = PlannerProviderFixtureProtocol.plannerReply
        defer { PlannerProviderFixtureProtocol.plannerReply = original }
        PlannerProviderFixtureProtocol.plannerReply = original.replacingOccurrences(of: "S1", with: "S999")
        let fallback = try await service.generate(classIDs: [enrollment.id], objective: "Explain chaining", profile: profile, apiKey: "fixture-key")
        XCTAssertTrue(fallback.isLocalReply)
        XCTAssertTrue(fallback.response.text.contains("chaining and open addressing"))
        XCTAssertTrue(fallback.response.text.contains("Done when"))
        XCTAssertFalse(fallback.response.text.contains("Draw a collision chain"))
        XCTAssertNil(StudyPlanResponse.render(original.replacingOccurrences(of: "chaining and open addressing", with: "An unsupported detail"), sources: result.context.planningSources))
        XCTAssertNil(StudyPlanResponse.render("Verify every Canvas item", sources: result.context.planningSources))
    }

    @MainActor
    func testChatGenerationIncludesBoundedConversationAndFreshContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LCP-Planner-Chat-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let enrollment = ClassEnrollment(courseCode: "SYN 46", title: "Synthetic Algorithms")
        try repository.update { $0.classes.append(enrollment) }
        let materialURL = root.deletingLastPathComponent().appendingPathComponent("planner-chat-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: materialURL) }
        try Data("# Hash tables\n\nReview chaining and open addressing.".utf8).write(to: materialURL)
        _ = try MaterialService(repository: repository).importMaterial(from: materialURL, classID: enrollment.id)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerProviderFixtureProtocol.self]
        let service = ClassPlannerService(repository: repository, http: UniversityHTTP(configuration: configuration))
        let profile = AgentProviderProfile(name: "Fixture", baseURL: "https://provider.example/v1", model: "fixture-model")
        let history = [
            ChatMessage(role: .user, content: "What did I miss in lecture?"),
            ChatMessage(role: .assistant, content: "Review the hashing notes first.", agentIdentity: "Fixture")
        ]
        let result = try await service.generateChat(classIDs: [enrollment.id], history: history,
                                                    message: "What should I practice next?", profile: profile, apiKey: "fixture-key")

        XCTAssertEqual(result.response.text, "Plan fixture")
        let prompt = try XCTUnwrap(PlannerProviderFixtureProtocol.requestBody["input"] as? String)
        XCTAssertTrue(prompt.contains("What did I miss in lecture?"))
        XCTAssertTrue(prompt.contains("What should I practice next?"))
        XCTAssertTrue(prompt.contains("Hash tables"))
        XCTAssertTrue(prompt.contains("persistent study companion"))
    }
}

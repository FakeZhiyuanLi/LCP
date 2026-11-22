import Foundation
import XCTest
import LCPContextCore
@testable import LCPContextServices

private final class PlannerProviderFixtureProtocol: URLProtocol {
    static var requestBody: [String: Any] = [:]

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
        let body = Data(#"{"id":"planner_fixture","output_text":"Plan fixture"}"#.utf8)
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

        XCTAssertEqual(result.response.text, "Plan fixture")
        let prompt = try XCTUnwrap(PlannerProviderFixtureProtocol.requestBody["input"] as? String)
        XCTAssertTrue(prompt.contains("Prepare for the exam"))
        XCTAssertTrue(prompt.contains("Hash tables"))
        XCTAssertTrue(prompt.contains("untrusted study data"))
    }
}

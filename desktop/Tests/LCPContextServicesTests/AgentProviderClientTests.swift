import Foundation
import XCTest
import LCPContextCore
@testable import LCPContextServices

final class AgentProviderFixtureProtocol: URLProtocol {
    static var status = 200
    static var response: [String: Any] = ["id": "resp_fixture"]
    static var streamBody: Data?
    static var requestBody: [String: Any] = [:]
    static var authorization: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        let body = request.httpBody ?? requestBodyStreamData(request.httpBodyStream)
        if let body,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            Self.requestBody = object
        }
        let isStream = (Self.requestBody["stream"] as? Bool) == true
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.status < 300 {
            if isStream, let streamBody = Self.streamBody {
                let split = max(1, streamBody.count / 3)
                var start = 0
                while start < streamBody.count {
                    let end = min(streamBody.count, start + split)
                    client?.urlProtocol(self, didLoad: streamBody.subdata(in: start..<end))
                    start = end
                }
            } else {
                let body = (try? JSONSerialization.data(withJSONObject: Self.response)) ?? Data()
                client?.urlProtocol(self, didLoad: body)
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private func requestBodyStreamData(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var result = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(bytes, count: count)
        }
        return result.isEmpty ? nil : result
    }
}

final class AgentProviderClientTests: XCTestCase {
    private func client(model: String = "gpt-6.2-sol", key: String = "fixture-key") throws -> OpenAICompatibleAgentClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentProviderFixtureProtocol.self]
        let http = UniversityHTTP(configuration: configuration)
        let profile = AgentProviderProfile(name: "Fixture", baseURL: "https://provider.example/v1", model: model)
        return try OpenAICompatibleAgentClient(profile: profile, apiKey: key, http: http)
    }

    override func setUp() {
        super.setUp()
        AgentProviderFixtureProtocol.status = 200
        AgentProviderFixtureProtocol.response = ["id": "resp_fixture"]
        AgentProviderFixtureProtocol.streamBody = nil
        AgentProviderFixtureProtocol.requestBody = [:]
        AgentProviderFixtureProtocol.authorization = nil
    }

    func testResponsesCheckUsesTheConfiguredModelAndDoesNotSendClassContext() async throws {
        let result = try await client().checkConnection()

        XCTAssertEqual(result.model, "gpt-6.2-sol")
        XCTAssertEqual(result.endpoint.absoluteString, "https://provider.example/v1/responses")
        XCTAssertEqual(result.requestID, "resp_fixture")
        XCTAssertEqual(AgentProviderFixtureProtocol.authorization, "Bearer fixture-key")
        let payload = try JSONSerialization.jsonObject(with: OpenAICompatibleAgentClient.requestBody(model: "gpt-6.2-sol")) as? [String: Any]
        XCTAssertEqual(payload?["model"] as? String, "gpt-6.2-sol")
        XCTAssertEqual(payload?["store"] as? Bool, false)
        XCTAssertNil(payload?["class"])
        XCTAssertNil(payload?["context"])
    }

    func testConfigurationRejectsInsecureOrCredentialBearingURLs() {
        XCTAssertThrowsError(try AgentProviderProfile.validateBaseURL("http://provider.example/v1"))
        XCTAssertThrowsError(try AgentProviderProfile.validateBaseURL("https://user:pass@provider.example/v1"))
        XCTAssertThrowsError(try AgentProviderProfile.validateBaseURL("https://provider.example/v1?api_key=secret"))
        XCTAssertThrowsError(try AgentProviderProfile.validateAPIKey("fixture key"))
    }

    func testUnauthorizedProviderResponseIsMappedWithoutExposingResponseBody() async throws {
        AgentProviderFixtureProtocol.status = 401
        do {
            _ = try await client().checkConnection()
            XCTFail("Expected the provider to reject the key")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .http(401))
            XCTAssertEqual(error.errorDescription, "The provider rejected the API key. Check the key and reconnect.")
        }
    }

    func testGenerationSendsBoundedPromptAndReadsOutputText() async throws {
        AgentProviderFixtureProtocol.response = ["id": "resp_plan", "output_text": "Plan ready"]
        let result = try await client().generate(prompt: "quoted class context", maxOutputTokens: 64)

        XCTAssertEqual(result.text, "Plan ready")
        XCTAssertEqual(result.requestID, "resp_plan")
        XCTAssertEqual(AgentProviderFixtureProtocol.requestBody["model"] as? String, "gpt-6.2-sol")
        XCTAssertEqual(AgentProviderFixtureProtocol.requestBody["store"] as? Bool, false)
        XCTAssertEqual(AgentProviderFixtureProtocol.requestBody["input"] as? String, "quoted class context")
        XCTAssertEqual(AgentProviderFixtureProtocol.requestBody["max_output_tokens"] as? Int, 64)
    }

    func testGenerationRejectsOversizedPrompt() async throws {
        do {
            _ = try await client().generate(prompt: String(repeating: "x", count: 3_000_001))
            XCTFail("Expected an input-size error")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .inputTooLarge)
        }
    }

    func testStreamingGenerationSendsStreamFlagAndReportsDeltasAndUsage() async throws {
        AgentProviderFixtureProtocol.streamBody = Data(#"""
data: {"type":"response.created","response":{"id":"resp_stream"}}

data: {"type":"response.output_text.delta","delta":"Hello "}

data: {"type":"response.output_text.delta","delta":"streaming world"}

data: {"type":"response.completed","response":{"id":"resp_stream","usage":{"input_tokens":24,"output_tokens":6,"total_tokens":30}}}

data: [DONE]
"""#.utf8)
        let collector = StreamUpdateCollector()
        let result = try await client().generateStream(prompt: "streamed prompt", maxOutputTokens: 64) { update in
            collector.append(update)
        }

        XCTAssertEqual(result.text, "Hello streaming world")
        XCTAssertEqual(result.requestID, "resp_stream")
        XCTAssertEqual(result.usage, TokenUsage(inputTokens: 24, outputTokens: 6, totalTokens: 30))
        XCTAssertEqual(AgentProviderFixtureProtocol.requestBody["stream"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(collector.values.filter { !$0.delta.isEmpty }.count, 2)
        XCTAssertTrue(collector.values.last?.finished == true)
        XCTAssertEqual(collector.values.last?.usage, result.usage)
    }
}

private final class StreamUpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentProviderStreamUpdate] = []

    func append(_ update: AgentProviderStreamUpdate) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }

    var values: [AgentProviderStreamUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

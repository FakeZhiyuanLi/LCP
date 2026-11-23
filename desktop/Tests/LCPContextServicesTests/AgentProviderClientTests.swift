import Foundation
import os
import XCTest
import LCPContextCore
@testable import LCPContextServices

final class AgentProviderFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var response: [String: Any] = ["id": "resp_fixture"]
    static var streamBody: Data?
    static var requestBody: [String: Any] = [:]
    static var authorization: String?
    static var timeoutInterval: TimeInterval?
    static var simulateTimeout: AgentTimeoutPhase?
    static let partialReplyTimeout = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        Self.timeoutInterval = request.timeoutInterval
        let body = request.httpBody ?? requestBodyStreamData(request.httpBodyStream)
        if let body,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            Self.requestBody = object
        }
        if Self.simulateTimeout == .beforeHeaders {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let isStream = (Self.requestBody["stream"] as? Bool) == true
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.simulateTimeout == .beforeBody {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if Self.simulateTimeout == .duringBody {
            // URLSession may discard queued partial data if the protocol fails in
            // the same callback. Let the consumer trigger the timeout after a delta.
            Self.partialReplyTimeout.withLock { action in
                action = { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                }
            }
        }
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
        if Self.simulateTimeout != .duringBody {
            client?.urlProtocolDidFinishLoading(self)
        }
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
        AgentProviderFixtureProtocol.timeoutInterval = nil
        AgentProviderFixtureProtocol.simulateTimeout = nil
        AgentProviderFixtureProtocol.partialReplyTimeout.withLock { $0 = nil }
    }

    func testResponsesCheckUsesTheConfiguredModelAndDoesNotSendClassContext() async throws {
        let result = try await client().checkConnection()

        XCTAssertEqual(result.model, "gpt-6.2-sol")
        XCTAssertEqual(result.endpoint.absoluteString, "https://provider.example/v1/responses")
        XCTAssertEqual(result.requestID, "resp_fixture")
        XCTAssertEqual(AgentProviderFixtureProtocol.authorization, "Bearer fixture-key")
        XCTAssertEqual(AgentProviderFixtureProtocol.timeoutInterval, 120)
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

    func testStreamingTimeoutReportsWhetherHeadersOrBodyArrivedWithoutLeakingContent() async throws {
        let marker = "fictional-private"
        let body = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"\(marker)\"}\n\n".utf8)
        AgentProviderFixtureProtocol.streamBody = body
        for phase in [AgentTimeoutPhase.beforeHeaders, .beforeBody, .duringBody] {
            AgentProviderFixtureProtocol.simulateTimeout = phase
            let diagnostics = AgentRequestDiagnostics()
            do {
                _ = try await client(key: marker).generateStream(prompt: marker, diagnostics: diagnostics) { update in
                    if !update.delta.isEmpty {
                        let timeout = AgentProviderFixtureProtocol.partialReplyTimeout.withLock { $0 }
                        timeout?()
                    }
                }
                XCTFail("Expected a timeout")
            } catch let error as AgentProviderError {
                XCTAssertEqual(error, .timeout(phase))
                let details = diagnostics.supportDetails(stage: .generation, error: error)
                XCTAssertTrue(details.contains("Reason: network_-1001"))
                XCTAssertTrue(details.contains("Elapsed: "))
                XCTAssertTrue(details.contains("Timeouts: 120 s idle, 600 s total"))
                XCTAssertTrue(details.contains(phase == .beforeHeaders ? "HTTP: no response headers" : "HTTP: 200 after "))
                XCTAssertTrue(details.contains("Response body: \(phase == .duringBody ? body.count : 0) bytes"))
                XCTAssertTrue(details.contains(phase == .duringBody ? "events=1" : "events=0"))
                XCTAssertEqual(details.contains("Body timing:"), phase == .duringBody)
                XCTAssertFalse(details.contains(marker))
                XCTAssertFalse(details.contains("provider.example"))
                XCTAssertFalse(error.localizedDescription.contains(marker))
            }
            XCTAssertEqual(AgentProviderFixtureProtocol.timeoutInterval, 120)
        }
    }

    func testBufferedGenerationAndConnectionCheckPreserveTransportTimeouts() async throws {
        AgentProviderFixtureProtocol.simulateTimeout = .beforeHeaders
        let provider = try client()
        do {
            _ = try await provider.checkConnection()
            XCTFail("Expected connection check timeout")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .timeout(.beforeHeaders))
        }
        AgentProviderFixtureProtocol.simulateTimeout = .beforeBody
        do {
            _ = try await provider.generate(prompt: "fictional")
            XCTFail("Expected generation timeout")
        } catch let error as AgentProviderError {
            XCTAssertEqual(error, .timeout(.beforeBody))
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

    func testNamedResponsesEventsFromGatewayDeliverOnlyAnswerText() async throws {
        let wire = [
            ": keep-alive", "",
            "event: response.created", "id: 1", "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_fixture\"}}", "",
            "event: response.reasoning_summary_text.delta", "data: {\"delta\":\"summary\"}", "",
            "event: response.output_text.delta", "retry: 1000", "data: {\"delta\":", "data: \"OK\"}", "",
            "event: response.completed", "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"total_tokens\":14}}}", ""
        ].joined(separator: "\r\n")
        AgentProviderFixtureProtocol.streamBody = Data(wire.utf8)
        let collector = StreamUpdateCollector()
        let reply = try await client().generateStream(prompt: "Fictional message") { collector.append($0) }
        XCTAssertEqual(reply.text, "OK")
        XCTAssertEqual(reply.requestID, "resp_fixture")
        XCTAssertEqual(reply.usage?.totalTokens, 14)
        XCTAssertEqual(collector.values.map(\.delta).joined(), "OK")
    }

    func testStreamFramingSurvivesOneByteChunksAndPrettyJSONFallback() throws {
        let fixtures = [
            "\u{FEFF}: keep-alive\r\runknown-field: ignore\rid: 7\revent: response.output_text.delta\rdata: {\"delta\":\"café\"}\r\rdata: [DONE]",
            "\u{FEFF}  {\n  \"id\":\"resp_fixture\",\n  \"output_text\":\"café\"\n}\n",
            "data: {\"id\":\"resp_fixture\",\"output_text\":\"café\"}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"café\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n"
        ]
        for wire in fixtures {
            let collector = StreamUpdateCollector()
            var parser = ProviderStreamParser(onUpdate: { collector.append($0) })
            for byte in wire.utf8 { try parser.consume(Data([byte])) }
            XCTAssertEqual(try parser.finish().text, "café")
            XCTAssertEqual(collector.values.filter(\.finished).count, 1)
        }
    }

    func testBrokenOrUnfinishedStreamsGiveSpecificSafeErrorsWithoutFinishing() async throws {
        let privateValue = "fictional-private-marker"
        let fixtures: [(String, AgentResponseIssue)] = [
            ("event: \(privateValue)\ndata: \(privateValue)\n\n", .malformedEvent),
            ("{\"output_text\": ", .malformedJSON),
            ("<html>\(privateValue)</html>", .unexpectedFormat),
            ("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n", .incomplete),
            ("event: response.incomplete\ndata: {\"response\":{\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n", .tokenLimit),
            ("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"\(privateValue)\"}}}\n\n", .providerFailure),
            ("data: {\"type\":\"response.completed\",\"response\":{}}\n\n", .noText)
        ]
        for (wire, issue) in fixtures {
            let collector = StreamUpdateCollector()
            let diagnostics = AgentRequestDiagnostics()
            AgentProviderFixtureProtocol.streamBody = Data(wire.utf8)
            do {
                _ = try await client().generateStream(prompt: privateValue, diagnostics: diagnostics) { collector.append($0) }
                XCTFail("Expected \(issue)")
            } catch let error as AgentProviderError {
                XCTAssertEqual(error, .response(issue))
                let report = diagnostics.supportDetails(stage: .generation, error: error)
                XCTAssertTrue(report.contains(diagnostics.id.uuidString))
                XCTAssertTrue(report.contains(issue.rawValue))
                XCTAssertFalse(report.contains(privateValue))
                XCTAssertFalse(error.localizedDescription.contains(privateValue))
            }
            XCTAssertFalse(collector.values.contains(where: \.finished))
        }
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

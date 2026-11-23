import Foundation
import CoreGraphics
import CoreText
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
    static var rejectedToolParameter: String?
    static var generationRequests = 0
    static var requestSizes: [Int] = []
    static var filingFollowup: [String: Any]?
    static var firstRequest: [String: Any] = [:]
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
        Self.generationRequests += 1
        Self.requestSizes.append(body?.count ?? 0)
        if Self.generationRequests == 1 { Self.firstRequest = Self.requestBody }
        if let param = Self.rejectedToolParameter, Self.requestBody["tools"] != nil {
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = try! JSONSerialization.data(withJSONObject: ["error": ["param": param, "message": "Unsupported parameter"]])
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
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
                let object = Self.generationRequests == 2 ? Self.filingFollowup ?? Self.response : Self.response
                let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
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
        AgentProviderFixtureProtocol.rejectedToolParameter = nil
        AgentProviderFixtureProtocol.generationRequests = 0
        AgentProviderFixtureProtocol.requestSizes = []
        AgentProviderFixtureProtocol.filingFollowup = nil
        AgentProviderFixtureProtocol.firstRequest = [:]
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

    @MainActor
    func testChatUploadsSendContentAndAcceptOnlySuggestionsForSuppliedFilesAndClasses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try ContextRepository(rootURL: directory)
        let course = ClassEnrollment(title: "Observational Astronomy")
        try repository.update { $0.classes = [course] }
        let source = directory.appendingPathComponent("Handout.md")
        try Data("Fictional orbital marker 937.".utf8).write(to: source)
        let upload = try ChatUpload.read(source)
        let image = directory.appendingPathComponent("Figure.png")
        let imageData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aYuoAAAAASUVORK5CYII="))
        try imageData.write(to: image)
        let picture = try ChatUpload.read(image)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentProviderFixtureProtocol.self]
        let planner = ClassPlannerService(repository: repository, http: UniversityHTTP(configuration: config))
        let profile = AgentProviderProfile(name: "Fiction", baseURL: "https://provider.example/v1", model: "fixture")
        func call(_ file: UUID, _ target: UUID) throws -> [String: Any] {
            let args = ["attachment_id": file.uuidString, "class_id": target.uuidString, "title": "Orbital handout", "reason": "Reference for the orbit lab."]
            return ["type": "function_call", "call_id": "call_" + UUID().uuidString, "name": ChatFilingTool.name,
                    "arguments": String(decoding: try JSONEncoder().encode(args), as: UTF8.self)]
        }
        AgentProviderFixtureProtocol.filingFollowup = ["output_text": "The orbital marker is 937.", "usage": ["total_tokens": 22]]
        AgentProviderFixtureProtocol.response = ["usage": ["total_tokens": 15], "output": try [
            call(upload.id, course.id), call(picture.id, UUID()), call(UUID(), course.id)]]
        let longMessage = String(repeating: "Compare orbits.\t", count: 22_000) + "End of question."
        let reply = try await planner.generateChatStream(classIDs: [course.id], history: [], message: longMessage,
            profile: profile, apiKey: "fictional", uploads: [upload, picture]) { _ in }
        XCTAssertEqual(AgentProviderFixtureProtocol.generationRequests, 2)
        XCTAssertEqual(reply.response.text, "The orbital marker is 937.")
        XCTAssertEqual(reply.response.usage?.totalTokens, 37)
        let followupInputs = try XCTUnwrap(AgentProviderFixtureProtocol.requestBody["input"] as? [[String: Any]])
        let followupParts = try XCTUnwrap(followupInputs.first?["content"] as? [[String: Any]])
        XCTAssertFalse(followupParts.contains { $0["image_url"] != nil || $0["file_data"] != nil })
        XCTAssertEqual(followupInputs.filter { $0["type"] as? String == "function_call_output" }.count, 3)
        XCTAssertNil(AgentProviderFixtureProtocol.requestBody["tools"])
        let body = AgentProviderFixtureProtocol.firstRequest
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertTrue((parts.first?["text"] as? String)?.contains(longMessage) == true)
        XCTAssertTrue(parts.contains { ($0["text"] as? String)?.contains("Fictional orbital marker 937.") == true })
        XCTAssertTrue(parts.contains { $0["image_url"] as? String == "data:image/png;base64," + imageData.base64EncodedString() })
        XCTAssertFalse(parts.contains { ($0["text"] as? String)?.contains(directory.path) == true })
        XCTAssertTrue((body["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == ChatFilingTool.name } == true)
        XCTAssertEqual(reply.response.filingSuggestions.map(\.attachmentID), [upload.id])
        XCTAssertTrue(repository.state.materials.isEmpty)

        try upload.retain(in: repository)
        let history = [ChatMessage(role: .user, content: "", contextClassIDs: [course.id], attachments: [upload.attachment])]
        AgentProviderFixtureProtocol.response = ["output_text": "Follow-up"]
        _ = try await planner.generateChat(classIDs: [course.id], history: history, message: "Which marker?",
                                           profile: profile, apiKey: "fictional")
        let followup = try JSONSerialization.data(withJSONObject: AgentProviderFixtureProtocol.requestBody)
        XCTAssertTrue(String(decoding: followup, as: UTF8.self).contains("Fictional orbital marker 937."))
        _ = try await planner.generateChat(classIDs: [], history: history, message: "Other scope", profile: profile, apiKey: "fictional")
        let outside = try JSONSerialization.data(withJSONObject: AgentProviderFixtureProtocol.requestBody)
        XCTAssertFalse(String(decoding: outside, as: UTF8.self).contains("Fictional orbital marker 937."))
        try picture.retain(in: repository)
        let imageHistory = [ChatMessage(role: .user, content: "Inspect this figure", contextClassIDs: [course.id], attachments: [picture.attachment])]
        _ = try await planner.generateChat(classIDs: [course.id], history: imageHistory, message: "When does campus open?",
                                           profile: profile, apiKey: "fictional")
        XCTAssertNotNil(AgentProviderFixtureProtocol.requestBody["input"] as? String)
        _ = try await planner.generateChat(classIDs: [course.id], history: imageHistory, message: "Inspect Figure.png again",
                                           profile: profile, apiKey: "fictional")
        let imageMessages = try XCTUnwrap(AgentProviderFixtureProtocol.requestBody["input"] as? [[String: Any]])
        let imageParts = try XCTUnwrap(imageMessages.first?["content"] as? [[String: Any]])
        XCTAssertTrue(imageParts.contains { $0["image_url"] as? String == "data:image/png;base64," + imageData.base64EncodedString() })
    }

    @MainActor
    func testTextbookHomeworkAndThanksBoundTheActualProviderRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root)
        let course = ClassEnrollment(title: "Fictional astronomy"), other = ClassEnrollment(title: "Fictional history")
        try repository.update { $0.classes = [course, other] }
        let url = root.appendingPathComponent("Orbit Atlas.pdf")
        let marker = "Homework: observe the blue comet on Thursday."
        let data = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &rect, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        }
        let filler = line("A fictional observatory maps the changing positions of distant stars across our night sky.")
        for page in 1...128 {
            pdf.beginPDFPage(nil)
            for row in 0..<28 {
                pdf.textPosition = CGPoint(x: 25, y: 750 - row * 22)
                CTLineDraw(page == 128 && row == 27 ? line(marker) : filler, pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
        try (data as Data).write(to: url)
        let upload = try ChatUpload.read(url)
        let extractedSize = try XCTUnwrap(upload.document?.plainText.utf8.count)
        XCTAssertGreaterThan(extractedSize, 250_000)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentProviderFixtureProtocol.self]
        let service = ClassPlannerService(repository: repository, http: .init(configuration: config))
        let profile = AgentProviderProfile(name: "Fixture", baseURL: "https://provider.example/v1", model: "fixture")
        let args = ["attachment_id": upload.id.uuidString, "class_id": course.id.uuidString, "title": "Orbit Atlas", "reason": "Course reading"]
        let call = ["type": "function_call", "name": ChatFilingTool.name, "call_id": "call_atlas",
                    "arguments": String(decoding: try JSONEncoder().encode(args), as: UTF8.self)]
        AgentProviderFixtureProtocol.response = ["output_text": "I found the homework.", "output": [call]]
        let result = try await service.generateChatStream(classIDs: [course.id], history: [], message: "Find the homework in this textbook.",
            profile: profile, apiKey: "fixture", uploads: [upload]) { _ in }
        XCTAssertEqual(AgentProviderFixtureProtocol.generationRequests, 1)
        let items = try XCTUnwrap(AgentProviderFixtureProtocol.firstRequest["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(items.first?["content"] as? [[String: Any]])
        XCTAssertTrue(parts.contains { ($0["text"] as? String)?.contains(marker) == true })
        XCTAssertFalse(parts.contains { $0["file_data"] != nil })
        let suggestion = try XCTUnwrap(result.response.filingSuggestions.first)
        try upload.retain(in: repository)
        var thread = ChatThread(classID: course.id, title: "Class chat")
        thread.messages = [ChatMessage(role: .user, content: "Find the homework.", contextClassIDs: [course.id], attachments: [upload.attachment]),
                           ChatMessage(role: .assistant, content: String(repeating: "earlier dialogue ", count: 8_000), contextClassIDs: [course.id])]
        try repository.update { state in
            XCTAssertTrue(ChatFilingTool.suggest(suggestion, in: &thread))
            state.chatThreads = [thread]
            try ChatFilingTool.file(upload.id, from: thread.id, to: course.id, in: &state)
        }
        let history = try XCTUnwrap(repository.state.chatThreads?.first?.messages)
        AgentProviderFixtureProtocol.response = ["output_text": "Observe the comet."]
        let homework = try await service.generateChat(classIDs: [course.id], history: history, message: "Thanks, when is the homework due?",
            profile: profile, apiKey: "fixture")
        let prompt = try XCTUnwrap(AgentProviderFixtureProtocol.requestBody["input"] as? String)
        XCTAssertTrue(prompt.contains(marker))
        XCTAssertFalse(prompt.contains("attachment_id"))
        XCTAssertEqual(homework.context.sourceCitations.map(\.locator), [.page(128)])
        XCTAssertTrue(try RetrievalService(repository: repository).resolve(XCTUnwrap(homework.context.sourceCitations.first)).text.contains(marker))
        XCTAssertEqual(AgentProviderFixtureProtocol.generationRequests, 2)
        XCTAssertTrue(AgentProviderFixtureProtocol.requestSizes.allSatisfy { (1..<32_768).contains($0) })
        for ids in [[course.id], [course.id, other.id]] {
            let thanks = try await service.generateChat(classIDs: ids, history: history, message: "thanks", profile: profile, apiKey: "")
            let streamed = try await service.generateChatStream(classIDs: ids, history: history, message: "  Thank you!! ", profile: profile, apiKey: "") { _ in }
            for reply in [thanks, streamed] {
                XCTAssertTrue(reply.isLocalReply)
                XCTAssertEqual(reply.response.usage, .init(inputTokens: 0, outputTokens: 0, totalTokens: 0))
                XCTAssertTrue(reply.context.markdown.isEmpty)
                XCTAssertTrue(reply.context.sourceCitations.isEmpty)
            }
        }
        XCTAssertEqual(AgentProviderFixtureProtocol.generationRequests, 2)
        print("Fictional textbook: \(extractedSize) extracted bytes; upload and homework request bytes: \(AgentProviderFixtureProtocol.requestSizes); acknowledgment requests: 0")
        XCTAssertFalse(ClassPlannerService.isLocalAcknowledgment("thanks", uploads: [upload]))
        XCTAssertFalse(ClassPlannerService.isLocalAcknowledgment("Thanks?", uploads: []))
    }

    func testGenerationRejectsInputAboveTotalTransportBudget() async throws {
        do {
            _ = try await client().generate(prompt: String(repeating: "x", count: OpenAICompatibleAgentClient.maximumRequestBytes))
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

    func testBufferedAndStreamedDisplayToolOutputUsesSharedSchemaAndOneGraphic() async throws {
        let provider = try client()
        let arguments = #"{"title":"Reading time","unit":"min","items":[{"label":"Chapter One","value":12}]}"#
        let item: [String: Any] = ["type": "function_call", "id": "fc_test", "call_id": "call_test",
                                   "name": "render_bar_chart", "arguments": arguments]
        let finished: [String: Any] = ["id": "resp_display", "output_text": "## Review",
                                       "output": [item], "usage": ["total_tokens": 23]]
        AgentProviderFixtureProtocol.response = finished
        let buffered = try await provider.generate(prompt: "Fictional chart")
        let tools = try XCTUnwrap(AgentProviderFixtureProtocol.requestBody["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), Set(AgentDisplayTool.allCases.map(\.rawValue)))
        let expected = try AgentDisplayTool.barChart.render(arguments: Data(arguments.utf8)).markdown()
        XCTAssertEqual(buffered.text, "## Review\n\n" + expected)

        func sse(_ events: [[String: Any]]) throws -> Data {
            Data(try events.map { event in
                "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
            }.joined().utf8)
        }
        var added = item; added["arguments"] = ""
        let split = arguments.index(arguments.startIndex, offsetBy: 10)
        let stream: [[String: Any]] = [
            ["type": "response.output_text.delta", "delta": "## Review"],
            ["type": "response.output_item.added", "output_index": 0, "item": added],
            ["type": "response.function_call_arguments.delta", "item_id": "fc_test", "delta": String(arguments[..<split])],
            ["type": "response.function_call_arguments.delta", "output_index": 0, "delta": String(arguments[split...])],
        ]
        AgentProviderFixtureProtocol.streamBody = try sse(stream + [["type": "response.completed", "response": ["id": "resp_display"]]])
        let deltasOnly = try await provider.generateStream(prompt: "Fictional chart") { _ in }
        XCTAssertEqual(deltasOnly.text, buffered.text)
        AgentProviderFixtureProtocol.streamBody = try sse(stream + [
            ["type": "response.function_call_arguments.done", "output_index": 0, "arguments": arguments],
            ["type": "response.output_item.done", "output_index": 0, "item": item],
            ["type": "response.completed", "response": finished]
        ])
        let repeated = try await provider.generateStream(prompt: "Fictional chart") { _ in }
        XCTAssertEqual(repeated, buffered)
        AgentProviderFixtureProtocol.response = ["output": [item]]
        let graphicOnly = try await provider.generate(prompt: "Just a chart")
        XCTAssertEqual(graphicOnly.text, expected)
    }

    func testInvalidToolInputsKeepProseAndCannotDispatchOtherFunctions() async throws {
        let provider = try client()
        for item in [
            ["type": "function_call", "name": "unknown_tool", "arguments": "{}"],
            ["type": "function_call", "name": "render_timeline", "arguments": #"{"title":"Bad","items":[]}"#]
        ] {
            AgentProviderFixtureProtocol.response = ["output_text": "A readable answer.", "output": [item]]
            let reply = try await provider.generate(prompt: "Fictional plan")
            XCTAssertTrue(reply.text.hasPrefix("A readable answer."))
            XCTAssertFalse(reply.text.contains("lcp-visual"))
        }
        for input in [
            #"{"title":"T","unit":"min","items":[{"label":"L","value":true}]}"#,
            #"{"title":"T","unit":"min","items":[{"label":"L","value":-1}]}"#,
            #"{"title":"T","unit":"min","items":[{"label":"L","value":1,"path":"/example"}]}"#
        ] {
            XCTAssertThrowsError(try AgentDisplayTool.barChart.render(arguments: Data(input.utf8)))
        }
    }

    func testPlainMarkdownFallbackOnlyForRejectedDisplayTools() async throws {
        let provider = try client()
        AgentProviderFixtureProtocol.response = ["output_text": "**Review**"]
        AgentProviderFixtureProtocol.rejectedToolParameter = "tools"
        let result = try await provider.generateStream(prompt: "Fictional plan") { _ in }
        XCTAssertEqual(result.text, "**Review**")
        XCTAssertEqual(AgentProviderFixtureProtocol.generationRequests, 2)
        XCTAssertNil(AgentProviderFixtureProtocol.requestBody["tools"])
        AgentProviderFixtureProtocol.rejectedToolParameter = "model"
        do {
            _ = try await provider.generate(prompt: "Fictional plan")
            XCTFail("Expected the original HTTP rejection")
        } catch let error as AgentProviderError { XCTAssertEqual(error, .http(400)) }
        XCTAssertEqual(AgentProviderFixtureProtocol.generationRequests, 3)
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

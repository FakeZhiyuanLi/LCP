import Foundation
import LCPContextCore

/// Compatibility name for provider-facing APIs. Persisted chat records use
/// the core `TokenUsage` type so the storage module stays independent.
public typealias AgentProviderUsage = TokenUsage

/// Metadata for a user-owned provider connection. The API key is deliberately
/// kept outside this value so it cannot enter library state, backups, or agent
/// exports.
public struct AgentProviderProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var providerKind: String
    public var baseURL: String
    public var model: String
    public var createdAt: Date
    public var updatedAt: Date
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, providerKind: String = "openai-compatible",
                baseURL: String, model: String, createdAt: Date = Date(), updatedAt: Date = Date(),
                enabled: Bool = true) {
        self.id = id
        self.name = name
        self.providerKind = providerKind
        self.baseURL = baseURL
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.enabled = enabled
    }

    public func validated() throws -> AgentProviderProfile {
        _ = try Self.validateBaseURL(baseURL)
        guard Self.validText(name, maximumBytes: 128),
              Self.validText(providerKind, maximumBytes: 64),
              Self.validText(model, maximumBytes: 256) else {
            throw AgentProviderError.invalidConfiguration
        }
        return self
    }

    public static func validateBaseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbiddenHostCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard trimmed.utf8.count <= 2_048,
              let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              host.unicodeScalars.allSatisfy({ !forbiddenHostCharacters.contains($0) }) else {
            throw AgentProviderError.invalidConfiguration
        }
        return url
    }

    public static func validateAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 16_384,
              key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw AgentProviderError.invalidCredential
        }
        return key
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maximumBytes &&
            trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public struct AgentProviderCheckResult: Equatable, Sendable {
    public let model: String
    public let endpoint: URL
    public let requestID: String?

    public init(model: String, endpoint: URL, requestID: String? = nil) {
        self.model = model
        self.endpoint = endpoint
        self.requestID = requestID
    }
}

public struct AgentProviderGenerationResult: Equatable, Sendable {
    public let text: String
    public let requestID: String?
    public let usage: TokenUsage?
    public var filingSuggestions: [ChatFilingSuggestion]
    var fileContinuation: ProviderFileContinuation?

    public init(text: String, requestID: String? = nil, usage: TokenUsage? = nil, filingSuggestions: [ChatFilingSuggestion] = []) {
        self.filingSuggestions = filingSuggestions
        self.text = text
        self.requestID = requestID
        self.usage = usage
    }
}

/// Incremental output from a Responses API stream.
public struct AgentProviderStreamUpdate: Sendable {
    public let delta: String
    public let text: String
    public let requestID: String?
    public let usage: TokenUsage?
    public let finished: Bool

    public init(delta: String = "", text: String, requestID: String? = nil,
                usage: TokenUsage? = nil, finished: Bool = false) {
        self.delta = delta
        self.text = text
        self.requestID = requestID
        self.usage = usage
        self.finished = finished
    }
}

public enum AgentResponseIssue: String, Sendable {
    case malformedEvent, malformedJSON, unexpectedFormat, invalidEncoding, invalidText
    case noText, incomplete, tokenLimit, providerFailure, outputTooLarge

    var message: String {
        switch self {
        case .malformedEvent: return "LCP could not decode an event in the provider’s reply."
        case .malformedJSON: return "The provider returned an unreadable JSON response."
        case .unexpectedFormat: return "The provider returned an unrecognized response format."
        case .invalidEncoding, .invalidText: return "The provider returned text that LCP could not display."
        case .noText: return "The provider finished without returning an answer."
        case .incomplete: return "The response ended before the provider finished the answer. You can retry your message."
        case .tokenLimit: return "The provider reached its output limit before finishing. Try asking for a shorter answer."
        case .providerFailure: return "The provider reported that it could not finish this request."
        case .outputTooLarge: return "The provider’s reply exceeded LCP’s size limit."
        }
    }
}

public enum AgentTimeoutPhase: Sendable {
    case beforeHeaders, beforeBody, duringBody
}

public enum AgentProviderError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidCredential
    case credentialAccess(Int32)
    case inputTooLarge
    case unsupportedProvider
    case invalidResponse
    case response(AgentResponseIssue)
    case timeout(AgentTimeoutPhase)
    case network(Int)
    case requestFailed
    case http(Int)

    var diagnosticCode: String {
        switch self {
        case .invalidConfiguration: return "invalidConfiguration"
        case .invalidCredential: return "invalidCredential"
        case .credentialAccess(let code): return "keychain_\(code)"
        case .inputTooLarge: return "inputTooLarge"
        case .unsupportedProvider: return "unsupportedProvider"
        case .invalidResponse: return "invalidResponse"
        case .response(let issue): return issue.rawValue
        case .requestFailed: return "requestFailed"
        case .timeout: return "network_\(URLError.timedOut.rawValue)"
        case .network(let code): return "network_\(code)"
        case .http(let code): return "http_\(code)"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Enter an HTTPS provider URL, a name, and a model."
        case .credentialAccess: return "LCP could not read or update the provider connection in the Mac Keychain."
        case .invalidCredential:
            return "Enter an API key without spaces or line breaks."
        case .inputTooLarge:
            return "The combined message, files, and class context exceed the provider request budget. Send fewer files or split this request."
        case .unsupportedProvider:
            return "This provider connection is not supported yet. Choose OpenAI-compatible Responses API."
        case .invalidResponse:
            return "The provider returned an unexpected response. Check the endpoint and model."
        case .response(let issue): return issue.message
        case .timeout(.beforeHeaders):
            return "LCP timed out waiting for the provider to respond. You can try again."
        case .timeout(.beforeBody):
            return "The provider responded, but LCP timed out waiting for the reply to begin. You can try again."
        case .timeout(.duringBody):
            return "LCP received part of the reply before the request timed out. You can try again."
        case .requestFailed, .network:
            return "LCP could not reach the provider. Check the network and endpoint."
        case .http(401):
            return "The provider rejected the API key. Check the key and reconnect."
        case .http(403):
            return "The provider denied this request. Check the key's permissions and model access."
        case .http(404):
            return "The provider endpoint or model was not found. Check the base URL and model."
        case .http(429):
            return "The provider is rate limiting requests. Try again later."
        case .http(let status):
            return "The provider returned HTTP \(status). Check the connection settings and try again."
        }
    }
}

/// Minimal OpenAI Responses API check for a user-owned, OpenAI-compatible
/// endpoint. It sends no class context and asks for a bounded response.
public struct OpenAICompatibleAgentClient: Sendable {
    private let profile: AgentProviderProfile
    private let apiKey: String
    private let http: UniversityHTTP

    public init(profile: AgentProviderProfile, apiKey: String, http: UniversityHTTP = .init()) throws {
        self.profile = try profile.validated()
        self.apiKey = try AgentProviderProfile.validateAPIKey(apiKey)
        self.http = http
    }

    private func destination() throws -> (endpoint: URL, host: String) {
        guard profile.providerKind == "openai-compatible" else { throw AgentProviderError.unsupportedProvider }
        let base = try AgentProviderProfile.validateBaseURL(profile.baseURL)
        guard let host = base.host?.lowercased() else { throw AgentProviderError.invalidConfiguration }
        return (base.appendingPathComponent("responses"), host)
    }

    private func jsonResponse(endpoint: URL, host: String, body: Data,
                              diagnostics: AgentRequestDiagnostics, displayTools: Bool = false) async throws -> [String: Any] {
        let chunks = try http.postProviderJSON(endpoint, body: body, bearer: apiKey, host: host,
                                               stream: false, limit: 65_536, diagnostics: diagnostics, displayTools: displayTools)
        var data = Data()
        for try await chunk in chunks {
            try Task.checkCancellation()
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentProviderError.response(.malformedJSON)
        }
        return object
    }

    public func checkConnection() async throws -> AgentProviderCheckResult {
        let diagnostics = AgentRequestDiagnostics()
        return try await diagnostics.run(.connectionCheck) {
            let (endpoint, host) = try destination()
            let body = try Self.requestBody(model: profile.model)
            let object = try await jsonResponse(endpoint: endpoint, host: host, body: body, diagnostics: diagnostics)
            // This tiny probe may legitimately exhaust its eight-token budget.
            do { try Self.checkStatus(object) } catch AgentProviderError.response(.tokenLimit) { }
            guard object["id"] is String || Self.responseText(from: object) != nil else {
                throw AgentProviderError.invalidResponse
            }
            return AgentProviderCheckResult(model: profile.model, endpoint: endpoint, requestID: object["id"] as? String)
        }
    }

    public func generate(prompt: String, maxOutputTokens: Int = 1_200, files: [ChatFileInput] = []) async throws -> AgentProviderGenerationResult {
        let diagnostics = AgentRequestDiagnostics()
        return try await diagnostics.run(.generate) {
            let (endpoint, host) = try destination()
            let object = try await withGenerationBody(prompt: prompt, maximum: maxOutputTokens, stream: false, files: files) { body, tools in
                try await jsonResponse(endpoint: endpoint, host: host, body: body, diagnostics: diagnostics, displayTools: tools)
            }
            try Self.checkStatus(object)
            var displays = ProviderDisplayCalls()
            displays.response(object)
            let answerText = Self.responseText(from: object)
            let parts = [answerText ?? "", displays.markdown()].filter { !$0.isEmpty }
            let suggestions = displays.filingSuggestions
            let text = parts.isEmpty && !suggestions.isEmpty ? ChatFilingTool.reply : parts.joined(separator: "\n\n")
            guard !text.isEmpty else { throw AgentProviderError.response(.noText) }
            let first = AgentProviderGenerationResult(text: text, requestID: object["id"] as? String,
                usage: Self.usage(from: object["usage"] as? [String: Any]), filingSuggestions: suggestions)
            guard !files.isEmpty, let continuation = displays.continuation(answered: answerText != nil) else { return first }
            let body = try Self.generationBody(model: profile.model, prompt: prompt, maxOutputTokens: maxOutputTokens,
                stream: false, displayTools: false, files: files, continuation: continuation)
            let final = try await jsonResponse(endpoint: endpoint, host: host, body: body, diagnostics: diagnostics)
            try Self.checkStatus(final)
            guard let answer = Self.responseText(from: final) else { throw AgentProviderError.response(.noText) }
            return first.appending(.init(text: answer, requestID: final["id"] as? String, usage: Self.usage(from: final["usage"] as? [String: Any])))
        }
    }

    public func generateStream(prompt: String, maxOutputTokens: Int = 1_200, files: [ChatFileInput] = [],
                               diagnostics: AgentRequestDiagnostics = .init(),
                               onUpdate: @escaping @Sendable (AgentProviderStreamUpdate) -> Void) async throws -> AgentProviderGenerationResult {
        try await diagnostics.run(.stream) {
            let (endpoint, host) = try destination()
            func stream(_ body: Data, tools: Bool, update: @escaping @Sendable (AgentProviderStreamUpdate) -> Void) async throws -> AgentProviderGenerationResult {
                let chunks = try http.postProviderJSON(endpoint, body: body, bearer: apiKey, host: host,
                                                       stream: true, limit: ProviderStreamParser.byteLimit, diagnostics: diagnostics, displayTools: tools)
                var parser = ProviderStreamParser(onUpdate: update)
                defer { diagnostics.streamSummary(parser) }
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    try parser.consume(chunk)
                }
                try Task.checkCancellation()
                return try parser.finish()
            }
            let first = try await withGenerationBody(prompt: prompt, maximum: maxOutputTokens, stream: true, files: files) { body, tools in
                try await stream(body, tools: tools, update: onUpdate)
            }
            guard !files.isEmpty, let continuation = first.fileContinuation else { return first }
            try Task.checkCancellation()
            let body = try Self.generationBody(model: profile.model, prompt: prompt, maxOutputTokens: maxOutputTokens,
                stream: true, displayTools: false, files: files, continuation: continuation)
            let prefix = first.text == ChatFilingTool.reply ? "" : first.text + "\n\n"
            let final = try await stream(body, tools: false) { update in
                onUpdate(.init(delta: update.delta, text: prefix + update.text, requestID: update.requestID,
                               usage: update.usage, finished: update.finished))
            }
            return first.appending(final)
        }
    }

    private func withGenerationBody<T>(prompt: String, maximum: Int, stream: Bool, files: [ChatFileInput],
                                       send: (Data, Bool) async throws -> T) async throws -> T {
        let body = try Self.generationBody(model: profile.model, prompt: prompt, maxOutputTokens: maximum,
                                           stream: stream, displayTools: true, files: files)
        do { return try await send(body, true) }
        catch is UnsupportedDisplayTools {
            // Some compatible gateways reject function declarations before beginning a response.
            try Task.checkCancellation()
            return try await send(Self.generationBody(model: profile.model, prompt: prompt, maxOutputTokens: maximum,
                                                      stream: stream, displayTools: false, files: files), false)
        }
    }

    static func checkStatus(_ object: [String: Any]) throws {
        if object["status"] as? String == "failed" || object["error"] is [String: Any] {
            throw AgentProviderError.response(.providerFailure)
        }
        if object["status"] as? String == "incomplete" {
            throw incompleteResponse(object)
        }
    }

    static func incompleteResponse(_ object: [String: Any]) -> AgentProviderError {
        let reason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String
        return .response(reason == "max_output_tokens" ? .tokenLimit : .incomplete)
    }

    static let maximumRequestBytes = 64 * 1024 * 1024

    static func requestBody(model: String) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "input": "Reply with exactly OK.",
            "max_output_tokens": 8,
            "store": false
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { throw AgentProviderError.invalidConfiguration }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    static func generationBody(model: String, prompt: String, maxOutputTokens: Int) throws -> Data {
        try generationBody(model: model, prompt: prompt, maxOutputTokens: maxOutputTokens, stream: false, displayTools: true)
    }

    private static func generationBody(model: String, prompt: String, maxOutputTokens: Int, stream: Bool, displayTools: Bool, files: [ChatFileInput] = [], continuation: ProviderFileContinuation? = nil) throws -> Data {
        // Avoid duplicating a request that already exceeds the total wire budget.
        guard (1...4_096).contains(maxOutputTokens), prompt.utf8.count < Self.maximumRequestBytes else {
            throw AgentProviderError.inputTooLarge
        }
        var payload: [String: Any] = [
            "model": model,
            "input": prompt,
            "max_output_tokens": maxOutputTokens,
            "store": false,
            "stream": stream
        ]
        if !files.isEmpty {
            let promptPart: [String: Any] = ["type": "input_text", "text": prompt]
            let parts = try files.flatMap { try $0.parts(includeOriginal: continuation == nil) }
            var input: [[String: Any]] = [["role": "user", "content": [promptPart] + parts]]
            if let continuation {
                input += try continuation.input(files: files)
                payload["instructions"] = "The filing tools have finished. Answer the student's question from the supplied excerpts, observations and tool results. If the requested detail is unavailable, say so. The student controls filing."
            }
            payload["input"] = input
        }
        if displayTools {
            var tools = AgentDisplayTool.allCases.map { tool -> [String: Any] in
                ["type": "function", "name": tool.rawValue, "description": tool.guidance,
                 "parameters": tool.inputSchema, "strict": false]
            }
            var instructions = "Write readable Markdown. Use a display tool when a comparison or sequence would help the student. Use up to four visuals. Include explanations and citations in the same response. Each tool displays its graphic directly in LCP. Use known facts and clearly label estimates."
            if files.contains(where: { !$0.destinations.isEmpty && $0.file.savedMaterialID == nil }) {
                payload["include"] = ["reasoning.encrypted_content"]
                tools.append(["type": "function", "name": ChatFilingTool.name, "description": ChatFilingTool.guidance,
                              "parameters": ChatFilingTool.schema, "strict": false])
                instructions += " Answer the student's question in the same response as any filing suggestion. Inspect supplied images and documents now. The original file is supplied only once."
            }
            payload["tools"] = tools
            payload["instructions"] = instructions
        }
        guard JSONSerialization.isValidJSONObject(payload) else { throw AgentProviderError.invalidConfiguration }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard data.count <= Self.maximumRequestBytes else { throw AgentProviderError.inputTooLarge }
        return data
    }

    static func responseText(from object: [String: Any]) -> String? {
        if let direct = (object["output_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty { return direct }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        var fragments: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                switch part["type"] as? String {
                case "output_text": if let text = part["text"] as? String { fragments.append(text) }
                case "refusal": if let text = part["refusal"] as? String { fragments.append(text) }
                default: break
                }
            }
        }
        let result = fragments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func usage(from object: [String: Any]?) -> TokenUsage? {
        guard let object else { return nil }
        func count(_ key: String) -> Int? {
            guard let value = object[key] as? NSNumber else { return nil }
            let count = value.intValue
            return (0...100_000_000).contains(count) ? count : nil
        }
        let usage = TokenUsage(inputTokens: count("input_tokens"),
                                       outputTokens: count("output_tokens"),
                                       totalTokens: count("total_tokens"))
        return usage.inputTokens == nil && usage.outputTokens == nil && usage.totalTokens == nil ? nil : usage
    }
}

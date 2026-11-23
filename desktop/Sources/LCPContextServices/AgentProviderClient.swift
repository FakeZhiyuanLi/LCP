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

    public init(text: String, requestID: String? = nil, usage: TokenUsage? = nil) {
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

public enum AgentProviderError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidCredential
    case inputTooLarge
    case unsupportedProvider
    case invalidResponse
    case requestFailed
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Enter an HTTPS provider URL, a name, and a model."
        case .invalidCredential:
            return "Enter an API key without spaces or line breaks."
        case .inputTooLarge:
            return "The selected class context is too large for this provider request. Narrow the class context and try again."
        case .unsupportedProvider:
            return "This provider connection is not supported yet. Choose OpenAI-compatible Responses API."
        case .invalidResponse:
            return "The provider returned an unexpected response. Check the endpoint and model."
        case .requestFailed:
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

    public func checkConnection() async throws -> AgentProviderCheckResult {
        guard profile.providerKind == "openai-compatible" else { throw AgentProviderError.unsupportedProvider }
        let base = try AgentProviderProfile.validateBaseURL(profile.baseURL)
        guard let host = base.host?.lowercased() else { throw AgentProviderError.invalidConfiguration }
        let endpoint = base.appendingPathComponent("responses")
        let body = try Self.requestBody(model: profile.model)
        do {
            let data = try await http.postJSON(endpoint, body: body, bearer: apiKey, host: host)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentProviderError.invalidResponse
            }
            let requestID = object["id"] as? String
            return AgentProviderCheckResult(model: profile.model, endpoint: endpoint, requestID: requestID)
        } catch let error as AgentProviderError {
            throw error
        } catch let error as UniversityServiceError {
            switch error {
            case .http(let status): throw AgentProviderError.http(status)
            case .message: throw AgentProviderError.requestFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentProviderError.requestFailed
        }
    }

    /// Generate a bounded answer from an explicit, user-visible class context.
    /// The context is sent as quoted study data so source text cannot alter the
    /// provider request's permissions or LCP records.
    public func generate(prompt: String, maxOutputTokens: Int = 1_200) async throws -> AgentProviderGenerationResult {
        guard profile.providerKind == "openai-compatible" else { throw AgentProviderError.unsupportedProvider }
        guard (1...4_096).contains(maxOutputTokens), prompt.utf8.count <= 3_000_000 else {
            throw AgentProviderError.inputTooLarge
        }
        let base = try AgentProviderProfile.validateBaseURL(profile.baseURL)
        guard let host = base.host?.lowercased() else { throw AgentProviderError.invalidConfiguration }
        let endpoint = base.appendingPathComponent("responses")
        let body = try Self.generationBody(model: profile.model, prompt: prompt, maxOutputTokens: maxOutputTokens)
        do {
            let data = try await http.postJSON(endpoint, body: body, bearer: apiKey, host: host)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = Self.responseText(from: object), !text.isEmpty else {
                throw AgentProviderError.invalidResponse
            }
            return AgentProviderGenerationResult(text: text, requestID: object["id"] as? String,
                                                 usage: Self.usage(from: object["usage"] as? [String: Any]))
        } catch let error as AgentProviderError {
            throw error
        } catch let error as UniversityServiceError {
            switch error {
            case .http(let status): throw AgentProviderError.http(status)
            case .message: throw AgentProviderError.requestFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentProviderError.requestFailed
        }
    }

    /// Generate a bounded answer while forwarding text deltas as they arrive.
    /// The callback receives only provider output and sanitized usage metadata.
    public func generateStream(prompt: String, maxOutputTokens: Int = 1_200,
                               onUpdate: @escaping @Sendable (AgentProviderStreamUpdate) -> Void) async throws -> AgentProviderGenerationResult {
        guard profile.providerKind == "openai-compatible" else { throw AgentProviderError.unsupportedProvider }
        guard (1...4_096).contains(maxOutputTokens), prompt.utf8.count <= 3_000_000 else {
            throw AgentProviderError.inputTooLarge
        }
        let base = try AgentProviderProfile.validateBaseURL(profile.baseURL)
        guard let host = base.host?.lowercased() else { throw AgentProviderError.invalidConfiguration }
        let endpoint = base.appendingPathComponent("responses")
        let body = try Self.generationBody(model: profile.model, prompt: prompt,
                                           maxOutputTokens: maxOutputTokens, stream: true)
        do {
            let chunks = try http.postJSONStream(endpoint, body: body, bearer: apiKey, host: host,
                                                 limit: 3_500_000)
            var parser = StreamParser(onUpdate: onUpdate)
            for try await chunk in chunks {
                try Task.checkCancellation()
                try parser.consume(chunk)
            }
            let result = try parser.finish()
            guard !result.text.isEmpty else { throw AgentProviderError.invalidResponse }
            return result
        } catch let error as AgentProviderError {
            throw error
        } catch let error as UniversityServiceError {
            switch error {
            case .http(let status): throw AgentProviderError.http(status)
            case .message: throw AgentProviderError.requestFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentProviderError.requestFailed
        }
    }

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
        try generationBody(model: model, prompt: prompt, maxOutputTokens: maxOutputTokens, stream: false)
    }

    private static func generationBody(model: String, prompt: String, maxOutputTokens: Int, stream: Bool) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "input": prompt,
            "max_output_tokens": maxOutputTokens,
            "store": false,
            "stream": stream
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { throw AgentProviderError.invalidConfiguration }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard data.count <= 3_500_000 else { throw AgentProviderError.inputTooLarge }
        return data
    }

    private static func responseText(from object: [String: Any]) -> String? {
        if let direct = object["output_text"] as? String {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        var fragments: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where (part["type"] as? String) == "output_text" {
                if let text = part["text"] as? String { fragments.append(text) }
            }
        }
        let result = fragments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func usage(from object: [String: Any]?) -> TokenUsage? {
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

    private struct StreamParser {
        private var bytes = Data()
        private var eventData: [String] = []
        private var text = ""
        private var requestID: String?
        private var usage: TokenUsage?
        private let onUpdate: @Sendable (AgentProviderStreamUpdate) -> Void

        init(onUpdate: @escaping @Sendable (AgentProviderStreamUpdate) -> Void) {
            self.onUpdate = onUpdate
        }

        mutating func consume(_ chunk: Data) throws {
            guard bytes.count + chunk.count <= 3_500_000 else { throw AgentProviderError.inputTooLarge }
            bytes.append(chunk)
            while let newline = bytes.firstIndex(of: 0x0A) {
                let line = bytes[..<newline]
                bytes.removeSubrange(...newline)
                try consumeLine(String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            }
        }

        mutating func finish() throws -> AgentProviderGenerationResult {
            if !bytes.isEmpty {
                try consumeLine(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                bytes.removeAll(keepingCapacity: false)
            }
            try finishEvent()
            guard !text.isEmpty else { throw AgentProviderError.invalidResponse }
            onUpdate(AgentProviderStreamUpdate(delta: "", text: text, requestID: requestID,
                                                usage: usage, finished: true))
            return AgentProviderGenerationResult(text: text, requestID: requestID, usage: usage)
        }

        private mutating func consumeLine(_ line: String) throws {
            if line.isEmpty {
                try finishEvent()
            } else if line.hasPrefix("data:") {
                eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if !line.hasPrefix(":") && eventData.isEmpty {
                // A few compatible gateways ignore stream=true and return one JSON object.
                eventData.append(line)
            }
        }

        private mutating func finishEvent() throws {
            guard !eventData.isEmpty else { return }
            let raw = eventData.joined(separator: "\n")
            eventData.removeAll(keepingCapacity: true)
            guard raw != "[DONE]" else { return }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentProviderError.invalidResponse
            }
            if let id = object["id"] as? String { requestID = id }
            if let error = object["error"] as? [String: Any], error["message"] != nil {
                throw AgentProviderError.requestFailed
            }
            let eventType = object["type"] as? String
            let response = object["response"] as? [String: Any]
            if let responseID = response?["id"] as? String { requestID = responseID }
            if let responseUsage = OpenAICompatibleAgentClient.usage(from: response?["usage"] as? [String: Any]) {
                usage = responseUsage
            } else if let eventUsage = OpenAICompatibleAgentClient.usage(from: object["usage"] as? [String: Any]) {
                usage = eventUsage
            }
            if eventType == "response.failed" { throw AgentProviderError.requestFailed }
            if let delta = object["delta"] as? String {
                try append(delta)
            } else if let choice = (object["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String {
                try append(content)
            } else if let finalText = OpenAICompatibleAgentClient.responseText(from: response ?? object), text.isEmpty, !finalText.isEmpty {
                try append(finalText)
            }
        }

        private mutating func append(_ delta: String) throws {
            guard delta.utf8.count <= 3_500_000 - text.utf8.count else { throw AgentProviderError.inputTooLarge }
            guard delta.rangeOfCharacter(from: .controlCharacters.subtracting(.newlines)) == nil else {
                throw AgentProviderError.invalidResponse
            }
            text.append(delta)
            onUpdate(AgentProviderStreamUpdate(delta: delta, text: text, requestID: requestID, usage: usage))
        }
    }
}

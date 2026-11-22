import Foundation

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

public enum AgentProviderError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidCredential
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
}

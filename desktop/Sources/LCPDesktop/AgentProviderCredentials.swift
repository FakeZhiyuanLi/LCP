import Foundation
import CryptoKit
import LCPContextServices
import Security

enum AgentProviderCredentialError: LocalizedError {
    case keychain
    case configurationFile
    case missingConfiguration

    var errorDescription: String? {
        switch self {
        case .keychain:
            return "LCP could not access the provider connection in the Mac Keychain."
        case .configurationFile:
            return "LCP could not read the Codex provider configuration."
        case .missingConfiguration:
            return "The Codex configuration does not contain an OpenAI-compatible API key and base URL."
        }
    }
}

struct ImportedCodexProvider: Sendable {
    let baseURL: String
    let model: String
    let apiKey: String
}

@MainActor
final class AgentProviderCredentials {
    static func forLibrary(_ url: URL) -> AgentProviderCredentials {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256Digest.hex(path)
        if let existing = profiles[digest] { return existing }
        let instance = AgentProviderCredentials(service: "org.lcp.Desktop.agent-provider." + digest)
        profiles[digest] = instance
        return instance
    }

    private static var profiles: [String: AgentProviderCredentials] = [:]
    private let service: String
    private let indexAccount = "profiles"

    private init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw AgentProviderCredentialError.keychain }
        return data
    }

    private func write(_ data: Data, _ account: String) throws {
        let request = query(account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(request as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AgentProviderCredentialError.keychain }
        var item = request
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "LCP Desktop · Agent provider connection"
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AgentProviderCredentialError.keychain }
    }

    private func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentProviderCredentialError.keychain }
    }

    func profilesList() throws -> [AgentProviderProfile] {
        guard let bytes = try read(indexAccount) else { return [] }
        guard let values = try? JSONDecoder().decode([AgentProviderProfile].self, from: bytes) else {
            throw AgentProviderCredentialError.keychain
        }
        return values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func hasAPIKey(for profile: AgentProviderProfile) throws -> Bool {
        try read(secretAccount(for: profile.id)) != nil
    }

    func apiKey(for profile: AgentProviderProfile) throws -> String {
        guard let bytes = try read(secretAccount(for: profile.id)),
              let value = String(data: bytes, encoding: .utf8) else {
            throw AgentProviderCredentialError.missingConfiguration
        }
        return try AgentProviderProfile.validateAPIKey(value)
    }

    func save(profile: AgentProviderProfile, apiKey: String) throws {
        let profile = try profile.validated()
        let key = try AgentProviderProfile.validateAPIKey(apiKey)
        let previousValues = try profilesList()
        let previousSecret = try read(secretAccount(for: profile.id))
        var values = previousValues
        values.removeAll { $0.id == profile.id }
        values.append(profile)
        try write(try JSONEncoder().encode(values), indexAccount)
        do {
            try write(Data(key.utf8), secretAccount(for: profile.id))
        } catch {
            if previousValues.isEmpty { try? remove(indexAccount) }
            else { try? write(try JSONEncoder().encode(previousValues), indexAccount) }
            if let previousSecret { try? write(previousSecret, secretAccount(for: profile.id)) }
            else { try? remove(secretAccount(for: profile.id)) }
            throw error
        }
    }

    func remove(profile: AgentProviderProfile) throws {
        let previousValues = try profilesList()
        let previousSecret = try read(secretAccount(for: profile.id))
        var values = previousValues
        values.removeAll { $0.id == profile.id }
        do {
            if values.isEmpty { try remove(indexAccount) }
            else { try write(try JSONEncoder().encode(values), indexAccount) }
            try remove(secretAccount(for: profile.id))
        } catch {
            if previousValues.isEmpty { try? remove(indexAccount) }
            else { try? write(try JSONEncoder().encode(previousValues), indexAccount) }
            if let previousSecret { try? write(previousSecret, secretAccount(for: profile.id)) }
            throw error
        }
    }

    func importCodexConfiguration() throws -> ImportedCodexProvider {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.isReadableFile(atPath: url.path),
              let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              bytes.count <= 128 * 1_024,
              let text = String(data: bytes, encoding: .utf8) else {
            throw AgentProviderCredentialError.configurationFile
        }
        let values = CodexConfigParser.parse(text)
        guard let baseURL = values.baseURL, let apiKey = values.apiKey, !apiKey.isEmpty else {
            throw AgentProviderCredentialError.missingConfiguration
        }
        _ = try AgentProviderProfile.validateBaseURL(baseURL)
        let model = values.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? values.model!
            : "gpt-6.2-sol"
        _ = try AgentProviderProfile.validateAPIKey(apiKey)
        return ImportedCodexProvider(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    private func secretAccount(for id: UUID) -> String { "secret.\(id.uuidString)" }
}

private enum SHA256Digest {
    static func hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CodexConfigValues {
    var baseURL: String?
    var model: String?
    var apiKey: String?
}

private enum CodexConfigParser {
    static func parse(_ text: String) -> CodexConfigValues {
        var section = ""
        var values = CodexConfigValues()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            guard let parsed = quoted(value) else { continue }
            if section == "model_providers.OpenAI" {
                if key == "base_url" { values.baseURL = parsed }
                if key == "experimental_bearer_token" { values.apiKey = parsed }
            } else if section.isEmpty, key == "model" {
                values.model = parsed
            }
        }
        return values
    }

    private static func quoted(_ value: String) -> String? {
        guard value.first == "\"", let end = value.lastIndex(of: "\""), end > value.startIndex else { return nil }
        let content = value[value.index(after: value.startIndex)..<end]
        return content.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

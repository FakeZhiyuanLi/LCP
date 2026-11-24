import CryptoKit
import Foundation
import LCPContextServices
import Security

enum ElevenLabsCredentialError: LocalizedError {
    case keychain
    case missing

    var errorDescription: String? {
        switch self {
        case .keychain:
            return "LCP could not read or update the ElevenLabs key in the Mac Keychain."
        case .missing:
            return "Add an ElevenLabs API key in Settings before transcribing locally."
        }
    }
}

/// Stores the optional ElevenLabs key separately for each local LCP library.
@MainActor
final class ElevenLabsCredentials {
    private static var profiles: [String: ElevenLabsCredentials] = [:]
    private let service: String
    private let account = "ElevenLabs API key"

    static func forLibrary(_ root: URL) -> ElevenLabsCredentials {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = profiles[digest] { return existing }
        let value = ElevenLabsCredentials(service: "org.lcp.Desktop.elevenlabs." + digest)
        profiles[digest] = value
        return value
    }

    private init(service: String) { self.service = service }

    func hasAPIKeyAsync() async throws -> Bool {
        let service = service
        let account = account
        return try await Task.detached(priority: .utility) {
            try Self.read(service: service, account: account) != nil
        }.value
    }

    func apiKeyAsync() async throws -> String {
        let service = service
        let account = account
        return try await Task.detached(priority: .utility) {
            guard let bytes = try Self.read(service: service, account: account),
                  let value = String(data: bytes, encoding: .utf8) else {
                throw ElevenLabsCredentialError.missing
            }
            return try ElevenLabsTranscriptionClient.validateAPIKey(value)
        }.value
    }

    /// Checks the candidate before writing it, so a failed key never replaces
    /// a working credential.
    func checkAndSave(_ candidate: String) async throws {
        let key = try ElevenLabsTranscriptionClient.validateAPIKey(candidate)
        try await ElevenLabsTranscriptionClient(apiKey: key).checkConnection()
        let service = service
        let account = account
        try await Task.detached(priority: .userInitiated) {
            try Self.write(Data(key.utf8), service: service, account: account)
        }.value
    }

    func removeAsync() async throws {
        let service = service
        let account = account
        try await Task.detached(priority: .utility) {
            try Self.remove(service: service, account: account)
        }.value
    }

    nonisolated private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    nonisolated private static func read(service: String, account: String) throws -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = value as? Data else {
            throw ElevenLabsCredentialError.keychain
        }
        return bytes
    }

    nonisolated private static func write(_ bytes: Data, service: String, account: String) throws {
        let request = query(service: service, account: account)
        let update = [kSecValueData as String: bytes]
        let status = SecItemUpdate(request as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ElevenLabsCredentialError.keychain }
        var item = request
        item[kSecValueData as String] = bytes
        item[kSecAttrLabel as String] = "LCP Desktop · ElevenLabs transcription"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ElevenLabsCredentialError.keychain
        }
    }

    nonisolated private static func remove(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ElevenLabsCredentialError.keychain
        }
    }
}

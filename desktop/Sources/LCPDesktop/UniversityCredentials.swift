import AppKit
import CryptoKit
import Foundation
import LCPContextCore
import LCPContextServices
import Security

enum UniversityCredentialError: LocalizedError {
    case invalidCanvas, missingCanvas, missingClient, missingGoogle, folderPermission, differentDriveAccount, changed, keychain, configurationFile
    var errorDescription: String? {
        switch self {
        case .invalidCanvas: return "Enter a Canvas access token without spaces or line breaks."
        case .missingCanvas: return "Connect UCI Canvas with a personal access token."
        case .missingClient: return "Choose a Google Cloud Desktop OAuth client JSON first."
        case .missingGoogle: return "Sign in to Google for this service."
        case .folderPermission: return "Enable Folder Creation in Connections → Google Drive."
        case .differentDriveAccount: return "Choose the same Google account you connected to LCP to enable folder creation."
        case .changed: return "This connection changed. Try again with its current settings."
        case .keychain: return "LCP could not access its credentials in the Mac Keychain."
        case .configurationFile: return "LCP could not read the selected Google Cloud Desktop OAuth client JSON."
        }
    }
}

@MainActor final class UniversityCredentials {
    static var shared: UniversityCredentials { forLibrary(ContextRepository.defaultRootURL) }
    private static var profiles: [String: UniversityCredentials] = [:]

    static func forLibrary(_ url: URL) -> UniversityCredentials {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let id = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = profiles[id] { return existing }
        let instance = UniversityCredentials(service: "org.lcp.Desktop.university." + id)
        profiles[id] = instance
        return instance
    }

    private let service: String
    private var pending: [String: UUID] = [:]
    private var checks: [UniversitySource: UUID] = [:]
    private var checkResults: [UniversitySource: UniversityConnectionStatus] = [:]
    private init(service: String) { self.service = service }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false]
    }

    private func data(_ name: String) throws -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result = value as? Data else { throw UniversityCredentialError.keychain }
        return result
    }

    private func contains(_ name: String) throws -> Bool {
        var q = query(name)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = SecItemCopyMatching(q as CFDictionary, nil)
        if result == errSecItemNotFound { return false }
        guard result == errSecSuccess else { throw UniversityCredentialError.keychain }
        return true
    }

    private func put(_ bytes: Data, _ name: String) throws {
        let q = query(name)
        let update = [kSecValueData as String: bytes]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw UniversityCredentialError.keychain }
        var item = q
        item[kSecValueData as String] = bytes
        item[kSecAttrLabel as String] = "LCP Desktop · " + name
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UniversityCredentialError.keychain }
    }

    private func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UniversityCredentialError.keychain }
    }

    private let canvasAccount = "canvas.eee.uci.edu"
    func hasCanvasToken() throws -> Bool { try contains(canvasAccount) }

    /// Keychain presence checks can wait for macOS approval. Keep them away
    /// from SwiftUI's main actor so the workspace remains interactive while
    /// the prompt is visible.
    func hasCanvasTokenAsync() async throws -> Bool {
        let service = service
        let account = canvasAccount
        return try await Task.detached(priority: .utility) {
            try Self.contains(service: service, account: account)
        }.value
    }

    private func validatedCanvasToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 16_384, token.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw UniversityCredentialError.invalidCanvas }
        return token
    }

    func saveCanvasToken(_ value: String) throws {
        let token = try validatedCanvasToken(value)
        try put(Data(token.utf8), canvasAccount)
        clearCheck(.canvas)
    }

    func saveCanvasTokenAsync(_ value: String) async throws {
        let token = try validatedCanvasToken(value)
        try await putAsync(Data(token.utf8), canvasAccount)
        clearCheck(.canvas)
    }

    func canvasToken() throws -> String {
        guard let bytes = try data(canvasAccount), let token = String(data: bytes, encoding: .utf8), !token.isEmpty
        else { throw UniversityCredentialError.missingCanvas }
        return token
    }

    /// Reading a protected Canvas token can wait for Keychain approval. Keep
    /// automatic refreshes from blocking the workspace's main actor.
    func canvasTokenAsync() async throws -> String {
        let service = service
        let account = canvasAccount
        return try await Task.detached(priority: .utility) {
            try Self.readCanvasToken(service: service, account: account)
        }.value
    }

    nonisolated private static func readCanvasToken(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { throw UniversityCredentialError.missingCanvas }
        guard status == errSecSuccess, let bytes = value as? Data,
              let token = String(data: bytes, encoding: .utf8), !token.isEmpty else {
            throw UniversityCredentialError.keychain
        }
        return token
    }

    func removeCanvasToken() throws {
        try remove(canvasAccount)
        clearCheck(.canvas)
    }

    func removeCanvasTokenAsync() async throws {
        try await removeAsync(canvasAccount)
        clearCheck(.canvas)
    }

    private let clientAccount = "Google desktop OAuth client"
    private func client() throws -> GoogleDesktopClient {
        guard let stored = try data(clientAccount) else { throw UniversityCredentialError.missingClient }
        guard let client = try? JSONDecoder().decode(GoogleDesktopClient.self, from: stored)
        else { throw UniversityCredentialError.keychain }
        return client
    }

    private func clientAsync() async throws -> GoogleDesktopClient {
        let service = service
        return try await Task.detached(priority: .utility) {
            try Self.client(service: service)
        }.value
    }

    func hasGoogleClient() throws -> Bool { try contains(clientAccount) }

    /// Keychain reads can present a macOS approval prompt. Keep automatic
    /// startup work off the main actor so the workspace can render while the
    /// user approves access.
    func hasGoogleClientAsync() async throws -> Bool {
        let service = service
        return try await Task.detached(priority: .utility) {
            try Self.contains(service: service, account: "Google desktop OAuth client")
        }.value
    }

    func configureGoogle(from url: URL) throws {
        guard url.isFileURL else { throw UniversityCredentialError.configurationFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let file = try? FileHandle(forReadingFrom: url) else { throw UniversityCredentialError.configurationFile }
        defer { try? file.close() }
        let bytes: Data
        do { bytes = try file.read(upToCount: 128 * 1024 + 1) ?? Data() }
        catch { throw UniversityCredentialError.configurationFile }
        let next = try GoogleDesktopClient.read(bytes)
        if try contains(clientAccount), try client() == next { return }
        try put(JSONEncoder().encode(next), clientAccount)
        pending.removeAll()
        for source in UniversitySource.allCases where source.googleKind != nil { clearCheck(source) }
    }

    /// Importing a Google OAuth client can trigger a Keychain approval prompt.
    /// Read the selected file and persist the client away from the main actor.
    func configureGoogleAsync(from url: URL) async throws {
        let bytes = try await Task.detached(priority: .utility) {
            try Self.configurationBytes(from: url)
        }.value
        let next = try GoogleDesktopClient.read(bytes)
        let service = service
        let current: GoogleDesktopClient? = try await Task.detached(priority: .utility) {
            guard try Self.contains(service: service, account: "Google desktop OAuth client") else { return nil }
            return try Self.client(service: service)
        }.value
        if current == next { return }
        try await putAsync(JSONEncoder().encode(next), clientAccount)
        pending.removeAll()
        for source in UniversitySource.allCases where source.googleKind != nil { clearCheck(source) }
    }

    private func scope(_ kind: GoogleUniversityKind) -> String {
        switch kind {
        case .drive: return "https://www.googleapis.com/auth/drive.readonly"
        case .gmail: return "https://www.googleapis.com/auth/gmail.readonly"
        case .calendar: return "https://www.googleapis.com/auth/calendar.readonly"
        }
    }

    private func account(_ kind: GoogleUniversityKind) -> String {
        switch kind {
        case .drive: return "Google Drive"
        case .gmail: return "Gmail"
        case .calendar: return "Google Calendar"
        }
    }

    private struct StoredGrant: Codable, Equatable {
        let clientID: String
        let grant: GoogleDesktopGrant
    }

    private func readGrant(_ name: String, clientID: String) throws -> StoredGrant? {
        guard let bytes = try data(name) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredGrant.self, from: bytes) else { throw UniversityCredentialError.keychain }
        return stored.clientID == clientID ? stored : nil
    }

    func isGoogleConnected(_ kind: GoogleUniversityKind) throws -> Bool {
        guard try hasGoogleClient(), try contains(account(kind)) else { return false }
        return try readGrant(account(kind), clientID: client().client_id) != nil
    }

    func isGoogleConnectedAsync(_ kind: GoogleUniversityKind) async throws -> Bool {
        let service = service
        return try await Task.detached(priority: .utility) {
            try Self.isGoogleConnected(service: service, kind: kind)
        }.value
    }

    private let driveFileScope = "https://www.googleapis.com/auth/drive.file"

    func canCreateDriveFolders() throws -> Bool {
        guard try hasGoogleClient() else { return false }
        let grant = try readGrant(account(.drive), clientID: client().client_id)
        return grant?.grant.scopes?.contains(driveFileScope) == true
    }

    func canCreateDriveFoldersAsync() async throws -> Bool {
        let service = service
        return try await Task.detached(priority: .utility) {
            try Self.canCreateDriveFolders(service: service)
        }.value
    }

    func signInGoogle(_ kind: GoogleUniversityKind, enableDriveFolders: Bool = false) async throws {
        let config = try await clientAsync()
        let name = account(kind)
        let attempt = UUID()
        pending[name] = attempt
        defer { if pending[name] == attempt { pending[name] = nil } }
        let requestingFolders = kind == .drive && enableDriveFolders
        var originalDriveAccount: String?
        if requestingFolders, try await isGoogleConnectedAsync(.drive) {
            originalDriveAccount = try await driveAccountID(token: googleTokenAsync(.drive))
        }
        let requested = requestingFolders ? scope(kind) + " " + driveFileScope : scope(kind)
        guard pending[name] == attempt, try await clientAsync() == config else { throw UniversityCredentialError.changed }
        let grant = try await GoogleDesktopOAuth.signIn(client: config, scope: requested) { NSWorkspace.shared.open($0) }
        if let originalDriveAccount, try await driveAccountID(token: grant.accessToken) != originalDriveAccount {
            throw UniversityCredentialError.differentDriveAccount
        }
        try Task.checkCancellation()
        guard pending[name] == attempt, try await clientAsync() == config else { throw UniversityCredentialError.changed }
        try await putAsync(JSONEncoder().encode(StoredGrant(clientID: config.client_id, grant: grant)), name)
        clearGoogleCheck(kind)
    }

    private func driveAccountID(token: String) async throws -> String {
        let endpoint = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(permissionId)")!
        let (data, _) = try await UniversityHTTP().get(endpoint, bearer: token, allowedHosts: ["www.googleapis.com"], limit: 16_384)
        struct About: Decodable {
            struct User: Decodable { let permissionId: String }
            let user: User
        }
        guard let id = try? JSONDecoder().decode(About.self, from: data).user.permissionId, !id.isEmpty else {
            throw UniversityServiceError.message("Google Drive could not confirm which account is connected.")
        }
        return id
    }

    func googleToken(_ kind: GoogleUniversityKind) async throws -> String {
        try await googleGrant(kind).accessToken
    }

    /// Async counterpart used by background sync. Every Keychain operation,
    /// including token refresh persistence, runs on a utility task.
    func googleTokenAsync(_ kind: GoogleUniversityKind) async throws -> String {
        try await googleGrantAsync(kind).accessToken
    }

    func driveFolderToken() async throws -> String {
        let grant = try await googleGrant(.drive)
        guard grant.scopes?.contains(driveFileScope) == true else { throw UniversityCredentialError.folderPermission }
        return grant.accessToken
    }

    func driveFolderTokenAsync() async throws -> String {
        let grant = try await googleGrantAsync(.drive)
        guard grant.scopes?.contains(driveFileScope) == true else { throw UniversityCredentialError.folderPermission }
        return grant.accessToken
    }

    private func googleGrant(_ kind: GoogleUniversityKind) async throws -> GoogleDesktopGrant {
        let config = try client()
        let name = account(kind)
        guard let previous = try readGrant(name, clientID: config.client_id) else { throw UniversityCredentialError.missingGoogle }
        if previous.grant.expiresAt.timeIntervalSinceNow > 60 { return previous.grant }
        let refreshed: GoogleDesktopGrant
        do {
            refreshed = try await GoogleDesktopOAuth.refresh(client: config, scope: scope(kind), token: previous.grant.refreshToken,
                                                              previousScopes: previous.grant.scopes)
        } catch GoogleDesktopOAuthError.expired {
            if try client() == config, try readGrant(name, clientID: config.client_id) == previous {
                try remove(name)
                clearGoogleCheck(kind)
            }
            throw GoogleDesktopOAuthError.expired
        }
        try Task.checkCancellation()
        guard try client() == config, try readGrant(name, clientID: config.client_id) == previous
        else { throw UniversityCredentialError.changed }
        try put(JSONEncoder().encode(StoredGrant(clientID: config.client_id, grant: refreshed)), name)
        return refreshed
    }

    private func googleGrantAsync(_ kind: GoogleUniversityKind) async throws -> GoogleDesktopGrant {
        let service = service
        return try await Task.detached(priority: .utility) {
            try await Self.googleGrant(service: service, kind: kind)
        }.value
    }

    private func putAsync(_ bytes: Data, _ name: String) async throws {
        let service = service
        try await Task.detached(priority: .utility) {
            try Self.write(bytes, service: service, account: name)
        }.value
    }

    private func removeAsync(_ name: String) async throws {
        let service = service
        try await Task.detached(priority: .utility) {
            try Self.remove(service: service, account: name)
        }.value
    }

    private nonisolated static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private nonisolated static func data(service: String, account: String) throws -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result = value as? Data else { throw UniversityCredentialError.keychain }
        return result
    }

    private nonisolated static func contains(service: String, account: String) throws -> Bool {
        var request = query(service: service, account: account)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw UniversityCredentialError.keychain }
        return true
    }

    private nonisolated static func write(_ bytes: Data, service: String, account: String) throws {
        let request = query(service: service, account: account)
        let update = [kSecValueData as String: bytes]
        let status = SecItemUpdate(request as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw UniversityCredentialError.keychain }
        var item = request
        item[kSecValueData as String] = bytes
        item[kSecAttrLabel as String] = "LCP Desktop · \(account)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UniversityCredentialError.keychain }
    }

    private nonisolated static func remove(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UniversityCredentialError.keychain }
    }

    private nonisolated static func configurationBytes(from url: URL) throws -> Data {
        guard url.isFileURL else { throw UniversityCredentialError.configurationFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let file = try? FileHandle(forReadingFrom: url) else { throw UniversityCredentialError.configurationFile }
        defer { try? file.close() }
        do { return try file.read(upToCount: 128 * 1024 + 1) ?? Data() }
        catch { throw UniversityCredentialError.configurationFile }
    }

    private nonisolated static func client(service: String) throws -> GoogleDesktopClient {
        guard let stored = try data(service: service, account: "Google desktop OAuth client") else {
            throw UniversityCredentialError.missingClient
        }
        guard let client = try? JSONDecoder().decode(GoogleDesktopClient.self, from: stored) else {
            throw UniversityCredentialError.keychain
        }
        return client
    }

    private nonisolated static func account(_ kind: GoogleUniversityKind) -> String {
        switch kind {
        case .drive: return "Google Drive"
        case .gmail: return "Gmail"
        case .calendar: return "Google Calendar"
        }
    }

    private nonisolated static func scope(_ kind: GoogleUniversityKind) -> String {
        switch kind {
        case .drive: return "https://www.googleapis.com/auth/drive.readonly"
        case .gmail: return "https://www.googleapis.com/auth/gmail.readonly"
        case .calendar: return "https://www.googleapis.com/auth/calendar.readonly"
        }
    }

    private nonisolated static func readGrant(service: String, name: String, clientID: String) throws -> StoredGrant? {
        guard let bytes = try data(service: service, account: name) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredGrant.self, from: bytes) else {
            throw UniversityCredentialError.keychain
        }
        return stored.clientID == clientID ? stored : nil
    }

    private nonisolated static func isGoogleConnected(service: String, kind: GoogleUniversityKind) throws -> Bool {
        guard try contains(service: service, account: "Google desktop OAuth client") else { return false }
        guard try contains(service: service, account: account(kind)) else { return false }
        let client = try client(service: service)
        return try readGrant(service: service, name: account(kind), clientID: client.client_id) != nil
    }

    private nonisolated static func canCreateDriveFolders(service: String) throws -> Bool {
        guard try contains(service: service, account: "Google desktop OAuth client") else { return false }
        let client = try client(service: service)
        let grant = try readGrant(service: service, name: account(.drive), clientID: client.client_id)
        return grant?.grant.scopes?.contains("https://www.googleapis.com/auth/drive.file") == true
    }

    private nonisolated static func googleGrant(service: String, kind: GoogleUniversityKind) async throws -> GoogleDesktopGrant {
        let config = try client(service: service)
        let name = account(kind)
        guard let previous = try readGrant(service: service, name: name, clientID: config.client_id) else {
            throw UniversityCredentialError.missingGoogle
        }
        if previous.grant.expiresAt.timeIntervalSinceNow > 60 { return previous.grant }
        let refreshed = try await GoogleDesktopOAuth.refresh(client: config, scope: scope(kind),
                                                               token: previous.grant.refreshToken,
                                                               previousScopes: previous.grant.scopes)
        try Task.checkCancellation()
        guard try client(service: service) == config,
              try readGrant(service: service, name: name, clientID: config.client_id) == previous else {
            throw UniversityCredentialError.changed
        }
        try write(JSONEncoder().encode(StoredGrant(clientID: config.client_id, grant: refreshed)),
                  service: service, account: name)
        return refreshed
    }

    func disconnectGoogle(_ kind: GoogleUniversityKind) throws {
        let name = account(kind)
        try remove(name)
        pending[name] = nil
        clearGoogleCheck(kind)
    }

    func disconnectGoogleAsync(_ kind: GoogleUniversityKind) async throws {
        let name = account(kind)
        try await removeAsync(name)
        pending[name] = nil
        clearGoogleCheck(kind)
    }

    private func clearGoogleCheck(_ kind: GoogleUniversityKind) {
        if let source = UniversitySource.allCases.first(where: { $0.googleKind == kind }) { clearCheck(source) }
    }

    private func clearCheck(_ source: UniversitySource) {
        checks[source] = nil
        checkResults[source] = nil
    }

    func lastCheck(for source: UniversitySource) -> UniversityConnectionStatus? { checkResults[source] }

    /// A candidate Canvas token is saved only after the courses API accepts it.
    func checkConnection(_ source: UniversitySource, candidateCanvasToken: String? = nil,
                         http: UniversityHTTP = .init()) async throws {
        let attempt = UUID()
        checks[source] = attempt
        defer { if checks[source] == attempt { checks[source] = nil } }
        do {
            if source == .canvas {
                let token: String
                if let candidateCanvasToken {
                    token = try validatedCanvasToken(candidateCanvasToken)
                } else {
                    token = try await canvasTokenAsync()
                }
                _ = try await UciCanvasClient(token: token, http: http).courses()
                try Task.checkCancellation()
                guard checks[source] == attempt else { throw UniversityCredentialError.changed }
                if candidateCanvasToken != nil { try await saveCanvasTokenAsync(token) }
            } else if let kind = source.googleKind {
                let token = try await googleTokenAsync(kind)
                try Task.checkCancellation()
                guard checks[source] == attempt else { throw UniversityCredentialError.changed }
                try await checkGoogleAPI(kind, token: token, http: http)
                try Task.checkCancellation()
                guard checks[source] == attempt else { throw UniversityCredentialError.changed }
            } else { return }
            checkResults[source] = .verified(Date())
        } catch {
            if checks[source] == attempt, !Task.isCancelled, candidateCanvasToken == nil {
                checkResults[source] = .checkFailed
            }
            throw error
        }
    }

    private func checkGoogleAPI(_ kind: GoogleUniversityKind, token: String, http: UniversityHTTP) async throws {
        let endpoint: URL
        switch kind {
        case .drive: endpoint = URL(string: "https://www.googleapis.com/drive/v3/about?fields=kind")!
        case .gmail: endpoint = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=historyId")!
        case .calendar: endpoint = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary?fields=kind")!
        }
        let (data, _) = try await http.get(endpoint, bearer: token, allowedHosts: [endpoint.host!], limit: 16_384)
        struct Reply: Decodable { let kind: String?; let historyId: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let valid: Bool
        switch kind {
        case .drive: valid = reply.kind == "drive#about"
        case .gmail: valid = reply.historyId?.isEmpty == false
        case .calendar: valid = reply.kind == "calendar#calendar"
        }
        guard valid else { throw UniversityServiceError.message("Google returned an unexpected response to the connection check.") }
    }
}

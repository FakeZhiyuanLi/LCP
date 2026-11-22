import CryptoKit
import Darwin
import Foundation

public enum GoogleDesktopOAuthError: LocalizedError {
    case configuration, listener, browser, timedOut, denied, transport, expired, response

    public var errorDescription: String? {
        switch self {
        case .configuration: return "Choose a Google Cloud OAuth client JSON downloaded for a Desktop app."
        case .listener: return "Google sign-in could not open its local callback. Start sign-in again."
        case .browser: return "The default browser could not open Google sign-in."
        case .timedOut: return "Google sign-in timed out. Start sign-in again."
        case .denied: return "Google sign-in was declined or cancelled."
        case .transport: return "LCP could not reach Google to complete authorization. Check the connection and try again."
        case .expired: return "Google authorization expired or was revoked. Connect this service again."
        case .response: return "Google did not return the credentials needed for this service. Check the OAuth client and its consent settings."
        }
    }
}

public struct GoogleDesktopClient: Codable, Equatable, Sendable {
    public let client_id: String
    public let client_secret: String?

    public static func read(_ data: Data) throws -> Self {
        struct Download: Decodable { let installed: GoogleDesktopClient }
        guard data.count <= 128 * 1024,
              let client = try? JSONDecoder().decode(Download.self, from: data).installed,
              client.client_id.hasSuffix(".apps.googleusercontent.com"), client.client_id.utf8.count < 512,
              client.client_id.utf8.allSatisfy({ (33...126).contains($0) }),
              (client.client_secret?.utf8.count ?? 0) <= 4_096 else { throw GoogleDesktopOAuthError.configuration }
        return client
    }
}

public struct GoogleDesktopGrant: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    /// Absent in grants saved before LCP tracked permissions. Those grants were read-only.
    public let scopes: Set<String>?
}

struct GoogleConsentCode: Sendable {
    let code: String
    let redirect: URL
    let verifier: String
}

public enum GoogleDesktopOAuth {
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func randomValue() -> String {
        var rng = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizationURL(client: GoogleDesktopClient, scope: String, redirect: URL,
                                 state: String, verifier: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": client.client_id, "response_type": "code", "scope": scope,
                          "redirect_uri": redirect.absoluteString, "state": state, "access_type": "offline",
                          "prompt": "consent select_account", "code_challenge_method": "S256",
                          "code_challenge": challenge(for: verifier)].map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    public static func signIn(client: GoogleDesktopClient, scope: String,
                              open: @escaping @MainActor @Sendable (URL) -> Bool) async throws -> GoogleDesktopGrant {
        let result = try await requestCode(client: client, scope: scope, open: open)
        return try await exchange(client: client, scope: scope,
                                  fields: ["grant_type": "authorization_code", "code": result.code,
                                           "redirect_uri": result.redirect.absoluteString, "code_verifier": result.verifier],
                                  existingRefreshToken: nil)
    }

    public static func refresh(client: GoogleDesktopClient, scope: String, token: String,
                               previousScopes: Set<String>? = nil) async throws -> GoogleDesktopGrant {
        try await exchange(client: client, scope: scope, fields: ["grant_type": "refresh_token", "refresh_token": token],
                           existingRefreshToken: token, previousScopes: previousScopes)
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = fields.keys.sorted().map { key in
            let value = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
            return "\(key)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func exchange(client: GoogleDesktopClient, scope: String, fields: [String: String],
                                 existingRefreshToken: String?, previousScopes: Set<String>? = nil) async throws -> GoogleDesktopGrant {
        var fields = fields
        fields["client_id"] = client.client_id
        fields["client_secret"] = client.client_secret
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: GoogleTokenRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw GoogleDesktopOAuthError.response }
            var body = Data()
            for try await byte in stream {
                guard body.count < 65_536 else { throw GoogleDesktopOAuthError.response }
                body.append(byte)
            }
            return try grant(response: body, status: response.statusCode, scope: scope,
                             previousRefresh: existingRefreshToken, previousScopes: previousScopes)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GoogleDesktopOAuthError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw GoogleDesktopOAuthError.transport
        }
    }

    static func grant(response: Data, status: Int, scope: String, previousRefresh: String?,
                      previousScopes: Set<String>? = nil) throws -> GoogleDesktopGrant {
        struct Reply: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Int?
            var token_type: String?
            var scope: String?
            var error: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response) else { throw GoogleDesktopOAuthError.response }
        if reply.error == "invalid_grant" { throw GoogleDesktopOAuthError.expired }
        let required = Set(scope.split(separator: " ").map(String.init))
        let allowed = required.union(previousScopes ?? [])
        let granted: Set<String>
        if let reported = reply.scope {
            granted = allowed.intersection(reported.split(separator: " ").map(String.init))
        } else if let previousScopes {
            granted = previousScopes
        } else if required.count == 1 {
            // Older, single read-scope grants can omit the scope on sign-in or refresh.
            granted = required
        } else {
            throw GoogleDesktopOAuthError.response
        }
        guard status == 200, let access = reply.access_token, !access.isEmpty, access.utf8.count <= 16_384,
              access.utf8.allSatisfy({ (33...126).contains($0) }),
              let refresh = reply.refresh_token ?? previousRefresh, !refresh.isEmpty, refresh.utf8.count <= 16_384,
              let duration = reply.expires_in, (1...86400).contains(duration), reply.token_type?.lowercased() == "bearer",
              !required.isEmpty, required.isSubset(of: granted) else {
            throw GoogleDesktopOAuthError.response
        }
        return GoogleDesktopGrant(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(Double(duration)),
                                  scopes: granted)
    }

    static func requestCode(client: GoogleDesktopClient, scope: String, timeout: Duration = .seconds(180),
                            open: @escaping @MainActor @Sendable (URL) -> Bool) async throws -> GoogleConsentCode {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw GoogleDesktopOAuthError.listener }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                guard bind(socketFD, raw, length) == 0, listen(socketFD, 8) == 0,
                      fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0,
                      getsockname(socketFD, raw, &length) == 0 else { throw GoogleDesktopOAuthError.listener }
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let redirect = URL(string: "http://127.0.0.1:\(port)")!
        let state = randomValue()
        let verifier = randomValue()
        try Task.checkCancellation()
        guard await open(authorizationURL(client: client, scope: scope, redirect: redirect, state: state, verifier: verifier))
        else { throw GoogleDesktopOAuthError.browser }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let peer = accept(socketFD, nil, nil)
            if peer >= 0 {
                defer { close(peer) }
                if let code = try await receiveCallback(peer, port: port, state: state, deadline: deadline) {
                    return GoogleConsentCode(code: code, redirect: redirect, verifier: verifier)
                }
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw GoogleDesktopOAuthError.listener
            } else {
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        throw GoogleDesktopOAuthError.timedOut
    }

    private static func receiveCallback(_ fd: Int32, port: UInt16, state: String,
                                        deadline: ContinuousClock.Instant) async throws -> String? {
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { return nil }
        var header = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let end = min(deadline, ContinuousClock.now + .seconds(2))
        while ContinuousClock.now < end && header.count < 16_384 {
            try Task.checkCancellation()
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { return nil }
            if count < 0 {
                guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return nil }
                try await Task.sleep(for: .milliseconds(30))
                continue
            }
            header.append(contentsOf: buffer.prefix(count))
            guard let boundary = header.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let text = String(decoding: header[..<boundary.lowerBound], as: UTF8.self)
            do {
                if let code = try callback(header: text, port: port, state: state) {
                    respond(fd, status: "200 OK", message: "Google returned to LCP Desktop. You can close this tab.")
                    return code
                }
            } catch {
                respond(fd, status: "200 OK", message: "Google sign-in was cancelled. You can close this tab.")
                throw error
            }
            respond(fd, status: "400 Bad Request", message: "This request does not match the current LCP sign-in.")
            return nil
        }
        return nil
    }

    static func callback(header: String, port: UInt16, state: String) throws -> String? {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[0] == "GET", request[2].hasPrefix("HTTP/1."),
              lines.dropFirst().filter({ $0.lowercased().hasPrefix("host:") }).map({
                  $0.dropFirst(5).trimmingCharacters(in: .whitespaces)
              }) == ["127.0.0.1:\(port)"],
              let url = URLComponents(string: String(request[1])), url.scheme == nil, url.host == nil,
              url.path == "/", url.fragment == nil else { return nil }
        let values = Dictionary(grouping: url.queryItems ?? [], by: \.name)
        guard values["state"]?.count == 1, values["state"]?.first?.value == state else { return nil }
        if values["error"] != nil { throw GoogleDesktopOAuthError.denied }
        guard values["code"]?.count == 1, let code = values["code"]?.first?.value, !code.isEmpty else { return nil }
        return code
    }

    private static func respond(_ fd: Int32, status: String, message: String) {
        let reply = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n" +
            "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n" +
            "Content-Length: \(message.utf8.count)\r\n\r\n\(message)"
        reply.withCString { bytes in _ = send(fd, bytes, reply.utf8.count, 0) }
    }
}

private final class GoogleTokenRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

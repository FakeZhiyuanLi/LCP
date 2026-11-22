import Foundation
import XCTest
@testable import LCPContextServices

final class GoogleDesktopOAuthTests: XCTestCase {
    private let scope = "https://www.googleapis.com/auth/drive.readonly"

    private func client() throws -> GoogleDesktopClient {
        try GoogleDesktopClient.read(Data(#"{"installed":{"client_id":"example.apps.googleusercontent.com","client_secret":"fixture"}}"#.utf8))
    }

    func testDesktopFileAndFixedEndpoints() throws {
        let config = try client()
        for invalid in [#"{"web":{"client_id":"example.apps.googleusercontent.com"}}"#, #"{"installed":{"client_id":"invalid"}}"#] {
            XCTAssertThrowsError(try GoogleDesktopClient.read(Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try GoogleDesktopClient.read(Data(repeating: 32, count: 131_073)))
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(GoogleDesktopOAuth.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = GoogleDesktopOAuth.authorizationURL(client: config, scope: scope, redirect: URL(string: "http://127.0.0.1:1234")!, state: "test", verifier: verifier)
        XCTAssertEqual(url.host, "accounts.google.com")
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(fields["scope"], scope)
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["access_type"], "offline")
        XCTAssertFalse(url.absoluteString.contains(verifier))
        XCTAssertFalse(url.absoluteString.contains("fixture"))
        XCTAssertEqual(String(data: GoogleDesktopOAuth.form(["code": "a+=& b"]), encoding: .utf8), "code=a%2B%3D%26%20b")
    }

    func testStateAndCallbackHost() throws {
        func callback(_ path: String, _ host: String = "127.0.0.1:3210") throws -> String? {
            try GoogleDesktopOAuth.callback(header: "GET \(path) HTTP/1.1\r\nHost: \(host)", port: 3210, state: "right")
        }
        XCTAssertNil(try callback("/?code=123&state=wrong"))
        XCTAssertNil(try callback("/favicon.ico?code=123&state=right"))
        XCTAssertNil(try callback("/?code=123&state=right&state=wrong"))
        XCTAssertNil(try callback("/?code=123&state=right", "elsewhere.invalid"))
        XCTAssertNil(try callback("https://elsewhere.invalid/?code=123&state=right"))
        XCTAssertEqual(try callback("/?code=123%2B456&state=right"), "123+456")
        XCTAssertThrowsError(try callback("/?error=access_denied&state=right"))
    }

    func testRotateAndRefresh() throws {
        let authorized = Data(#"{"access_token":"fixture-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.readonly"}"#.utf8)
        let grant = try GoogleDesktopOAuth.grant(response: authorized, status: 200, scope: scope, previousRefresh: "old")
        XCTAssertEqual(grant.refreshToken, "new-refresh")
        let refreshed = Data(#"{"access_token":"fixture-access2","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        XCTAssertEqual(try GoogleDesktopOAuth.grant(response: refreshed, status: 200, scope: scope, previousRefresh: "original").refreshToken, "original")
        XCTAssertThrowsError(try GoogleDesktopOAuth.grant(response: refreshed, status: 200, scope: scope, previousRefresh: nil))
        XCTAssertThrowsError(try GoogleDesktopOAuth.grant(response: authorized, status: 200, scope: "gmail", previousRefresh: nil))
        XCTAssertThrowsError(try GoogleDesktopOAuth.grant(response: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400, scope: scope, previousRefresh: nil))
    }

    func testFolderConsentRequiresBothScopesInEitherOrder() throws {
        let file = "https://www.googleapis.com/auth/drive.file"
        let required = scope + " " + file
        func signIn(_ scopes: String?) throws -> GoogleDesktopGrant {
            var response: [String: Any] = ["access_token": "access", "refresh_token": "refresh",
                                           "expires_in": 3600, "token_type": "Bearer"]
            response["scope"] = scopes
            return try GoogleDesktopOAuth.grant(response: JSONSerialization.data(withJSONObject: response),
                                                status: 200, scope: required, previousRefresh: nil)
        }
        XCTAssertEqual(try signIn(required).scopes, [scope, file])
        XCTAssertEqual(try signIn(file + " " + scope).scopes, [scope, file])
        XCTAssertThrowsError(try signIn(scope))
        XCTAssertThrowsError(try signIn(file))
        XCTAssertThrowsError(try signIn(nil))
    }

    func testRefreshPreservesOrNarrowsConfirmedScopes() throws {
        let file = "https://www.googleapis.com/auth/drive.file"
        let missing = Data(#"{"access_token":"access","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        let readOnly = Data(#"{"access_token":"access","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.readonly"}"#.utf8)
        let both = Data(#"{"access_token":"access","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/drive.readonly"}"#.utf8)
        func refresh(_ response: Data, previous: Set<String>?) throws -> GoogleDesktopGrant {
            try GoogleDesktopOAuth.grant(response: response, status: 200, scope: scope, previousRefresh: "refresh",
                                         previousScopes: previous)
        }
        XCTAssertEqual(try refresh(missing, previous: [scope, file]).scopes, [scope, file])
        XCTAssertEqual(try refresh(readOnly, previous: [scope, file]).scopes, [scope])
        XCTAssertEqual(try refresh(both, previous: [scope]).scopes, [scope])
        XCTAssertEqual(try refresh(missing, previous: nil).scopes, [scope])
    }

    func testLegacyGrantDecodesWithoutFolderPermission() throws {
        let legacy = Data(#"{"accessToken":"access","refreshToken":"refresh","expiresAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(GoogleDesktopGrant.self, from: legacy).scopes)
    }

    func testRealLoopbackAcceptsBrowserReply() async throws {
        let received = expectation(description: "browser received confirmation")
        let result = try await GoogleDesktopOAuth.requestCode(client: client(), scope: scope, timeout: .seconds(5)) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let state = items.first { $0.name == "state" }!.value!
            var callback = URLComponents(string: items.first { $0.name == "redirect_uri" }!.value!)!
            XCTAssertEqual(callback.host, "127.0.0.1")
            callback.queryItems = [URLQueryItem(name: "code", value: "fixture-code"), URLQueryItem(name: "state", value: state)]
            let target = callback.url!
            Task {
                defer { received.fulfill() }
                do {
                    let (body, response) = try await URLSession.shared.data(from: target)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                    XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-code"))
                } catch { XCTFail("The browser did not receive a local response.") }
            }
            return true
        }
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(result.code, "fixture-code")
        XCTAssertEqual(result.verifier.count, 43)
    }

    func testBoundedDeadlineAndCancel() async throws {
        do {
            _ = try await GoogleDesktopOAuth.requestCode(client: client(), scope: scope, timeout: .milliseconds(50)) { _ in true }
            XCTFail("expected deadline")
        } catch GoogleDesktopOAuthError.timedOut { }
        let started = expectation(description: "browser opened")
        let cfg = try client()
        let authScope = scope
        let task = Task {
            try await GoogleDesktopOAuth.requestCode(client: cfg, scope: authScope) { _ in
                started.fulfill()
                return true
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
    }
}

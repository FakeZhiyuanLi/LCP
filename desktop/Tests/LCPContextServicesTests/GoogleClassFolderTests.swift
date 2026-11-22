import Foundation
import XCTest
@testable import LCPContextServices

/// Each client gets its own ordered script of Drive responses, addressed by a fictional bearer token.
private final class FolderDriveFixture: URLProtocol {
    struct Reply {
        var method = "GET"
        let path: String
        var status = 200
        var json: [String: Any] = [:]
        var networkError: URLError.Code?
        var inspect: ((URLRequest) throws -> Void)?
    }

    final class Scripts: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: [Reply]] = [:]

        func set(_ script: [Reply], for token: String) {
            lock.withLock { replies[token] = script }
        }

        func next(for token: String) -> Reply? {
            lock.withLock {
                guard replies[token]?.isEmpty == false else { return nil }
                return replies[token]?.removeFirst()
            }
        }

        func finish(_ token: String) -> [Reply] {
            lock.withLock { replies.removeValue(forKey: token) ?? [] }
        }
    }

    static let scripts = Scripts()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "www.googleapis.com")
            let bearer = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            let reply = try XCTUnwrap(Self.scripts.next(for: bearer), "Unexpected Drive request: \(url.path)")
            XCTAssertEqual(request.httpMethod, reply.method)
            XCTAssertEqual(url.path, "/drive/v3/files" + reply.path)
            try reply.inspect?(request)
            if let error = reply.networkError {
                client?.urlProtocol(self, didFailWithError: URLError(error))
                return
            }
            let bytes = try JSONSerialization.data(withJSONObject: reply.json)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: reply.status,
                                                         httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class GoogleClassFolderTests: XCTestCase {
    private typealias Reply = FolderDriveFixture.Reply
    private let mime = "application/vnd.google-apps.folder"

    private func client(_ script: [Reply]) -> GoogleUniversityClient {
        let token = UUID().uuidString
        let bearer = "Bearer " + token
        FolderDriveFixture.scripts.set(script, for: bearer)
        addTeardownBlock {
            let remaining = FolderDriveFixture.scripts.finish(bearer)
            XCTAssertTrue(remaining.isEmpty, "Expected more requests: \(remaining.map(\.path))")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FolderDriveFixture.self]
        return GoogleUniversityClient(token: token, http: UniversityHTTP(configuration: configuration))
    }

    private func folder(_ id: String, _ name: String, parent: String = "parent") -> [String: Any] {
        ["id": id, "name": name, "mimeType": mime, "parents": [parent], "trashed": false,
         "capabilities": ["canAddChildren": true]]
    }

    private var parent: Reply {
        Reply(path: "/parent", json: folder("parent", "School Lectures", parent: "my-drive"))
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func postBody(_ request: URLRequest) throws -> [String: Any] {
        var bytes = Data()
        if let data = request.httpBody {
            bytes = data
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func assertFails<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("Expected the Drive operation to fail", file: file, line: line)
        } catch {}
    }

    func testReusesUniqueMatchAcrossSharedDrivePagesWithItsOriginalSpelling() async throws {
        var sharedParent = folder("parent", "School Lectures")
        sharedParent["driveId"] = "shared-id"
        let first = Reply(path: "", json: ["files": [folder("other", "Other")], "nextPageToken": "cursor+1"]) { request in
            XCTAssertEqual(self.query(request, "driveId"), "shared-id")
            XCTAssertEqual(self.query(request, "corpora"), "drive")
            XCTAssertEqual(self.query(request, "includeItemsFromAllDrives"), "true")
            let filter = try XCTUnwrap(self.query(request, "q"))
            XCTAssertTrue(filter.contains("'parent' in parents"))
            XCTAssertTrue(filter.contains(self.mime))
            XCTAssertTrue(filter.contains("trashed"))
        }
        let second = Reply(path: "", json: ["files": [folder("existing", "Études 2")]]) { request in
            XCTAssertEqual(self.query(request, "pageToken"), "cursor+1")
        }
        let drive = client([Reply(path: "/parent", json: sharedParent), first, second])
        let found = try await drive.findClassFolder(named: "ETUDES 2", under: "parent")
        XCTAssertEqual(found?.id, "existing")
        XCTAssertEqual(found?.name, "Études 2")
    }

    func testResolvesMyDriveRootAliasAndReportsMissingChild() async throws {
        let root = Reply(path: "/root", json: folder("my-drive", "My Drive"))
        let list = Reply(path: "", json: ["files": []]) { request in
            XCTAssertTrue(self.query(request, "q")?.contains("'my-drive' in parents") == true)
        }
        let found = try await client([root, list]).findClassFolder(named: "School Lectures", under: "root")
        XCTAssertNil(found)
    }

    func testRejectsAmbiguousMatchesEvenWhenSecondIsOnALaterPage() async {
        let first = Reply(path: "", json: ["files": [folder("first", "HIST 7")], "nextPageToken": "next"])
        let second = Reply(path: "", json: ["files": [folder("second", "Hist 7")]])
        let drive = client([parent, first, second])
        await assertFails { try await drive.findClassFolder(named: "Hist 7", under: "parent") }
    }

    func testRepeatedFolderIDIsOneMatchButRepeatedCursorFails() async throws {
        let match = folder("same", "HIST 7")
        let first = Reply(path: "", json: ["files": [match], "nextPageToken": "again"])
        let last = Reply(path: "", json: ["files": [match]])
        let drive = client([parent, first, last])
        let result = try await drive.findClassFolder(named: "HIST 7", under: "parent")
        XCTAssertEqual(result?.id, "same")
        let repeating = client([parent, first, first])
        await assertFails { try await repeating.findClassFolder(named: "HIST 7", under: "parent") }
    }

    func testIncompleteSearchOrMissingFilesDoesNotCountAsAbsence() async {
        let incomplete: [[String: Any]] = [["files": [], "incompleteSearch": true], [:]]
        for list in incomplete {
            let drive = client([parent, Reply(path: "", json: list)])
            await assertFails { try await drive.findClassFolder(named: "Hist 7", under: "parent") }
        }
    }

    func testReserveAndCreateFolderSendsOnlyMetadataToResolvedParent() async throws {
        let reserve = Reply(path: "/generateIds", json: ["ids": ["reserved"]])
        let root = Reply(path: "/root", json: folder("my-drive", "My Drive"))
        let create = Reply(method: "POST", path: "", json: folder("reserved", "School Lectures", parent: "my-drive")) { request in
            let body = try self.postBody(request)
            XCTAssertEqual(body["id"] as? String, "reserved")
            XCTAssertEqual(body["name"] as? String, "School Lectures")
            XCTAssertEqual(body["parents"] as? [String], ["my-drive"])
            XCTAssertEqual(body["mimeType"] as? String, self.mime)
            XCTAssertNil(body["permissions"])
            XCTAssertNil(self.query(request, "uploadType"))
        }
        let drive = client([reserve, root, create])
        let id = try await drive.generateDriveFolderID()
        let created = try await drive.createClassFolder(named: "School Lectures", under: "root", reservedID: id)
        XCTAssertEqual(created.id, "reserved")
    }

    func testRetryAfterLostCreateResponseReconcilesReservedID() async throws {
        let lost = Reply(method: "POST", path: "", networkError: .networkConnectionLost)
        let conflict = Reply(method: "POST", path: "", status: 409)
        let recovered = Reply(path: "/reserved", json: folder("reserved", "HIST 7"))
        let drive = client([parent, lost, parent, conflict, recovered])
        await assertFails { try await drive.createClassFolder(named: "HIST 7", under: "parent", reservedID: "reserved") }
        let result = try await drive.createClassFolder(named: "HIST 7", under: "parent", reservedID: "reserved")
        XCTAssertEqual(result.id, "reserved")
        XCTAssertEqual(result.name, "HIST 7")
    }

    func testConflictingIDMustStillIdentifyTheRequestedLiveFolder() async {
        let conflict = Reply(method: "POST", path: "", status: 409)
        let modifications: [(String, Any)] = [("parents", ["elsewhere"]), ("mimeType", "text/plain"),
                                               ("trashed", true), ("id", "different"), ("name", "HIST 8")]
        for (field, value) in modifications {
            var wrongFile = folder("reserved", "HIST 7")
            wrongFile[field] = value
            let drive = client([parent, conflict, Reply(path: "/reserved", json: wrongFile)])
            await assertFails { try await drive.createClassFolder(named: "HIST 7", under: "parent", reservedID: "reserved") }
        }
    }

    func testInvalidIDsAreRejectedBeforeNetworkAccess() async {
        let drive = client([])
        await assertFails { try await drive.getClassFolder(id: "../outside") }
        await assertFails { try await drive.findClassFolder(named: "HIST 7", under: "/bad") }
        await assertFails { try await drive.createClassFolder(named: "HIST 7", under: "parent", reservedID: "../outside") }
    }

    func testInvalidReservationsDoNotReturnAnIDForCreation() async {
        for ids in [[], ["first", "second"], ["root"], ["bad/id"]] {
            let drive = client([Reply(path: "/generateIds", json: ["ids": ids])])
            await assertFails { try await drive.generateDriveFolderID() }
        }
    }
}

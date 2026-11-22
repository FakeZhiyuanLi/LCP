import Foundation
import XCTest
@testable import LCPContextServices

private final class UniversityGoogleFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            struct BadRequest: Error {}
            guard request.httpMethod == "GET", let bearer = request.value(forHTTPHeaderField: "Authorization"), ["Bearer fic-a", "Bearer fic-b"].contains(bearer) else { throw BadRequest() }
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            func encoded(_ string: String) -> String { Data(string.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
            func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
            func part(_ text: String, type: String) -> [String: Any] {
                ["mimeType": type, "filename": "", "body": ["size": text.utf8.count, "data": encoded(text)]]
            }
            var status = 200
            var bytes: Data
            switch (url.host, url.path) {
            case ("www.googleapis.com", "/drive/v3/files"):
                guard value("pageToken") == "p+2", value("q")?.contains("ICS \\'46\\' + \\\\slides") == true,
                      value("corpora") == "allDrives", value("includeItemsFromAllDrives") == "true",
                      value("supportsAllDrives") == "true" else { throw BadRequest() }
                bytes = try json(["nextPageToken": "pg3", "files": [["id": "slides", "name": "Lecture 7", "mimeType": "application/vnd.google-apps.presentation"]]])
            case ("www.googleapis.com", let path) where path.hasPrefix("/drive/v3/files/"):
                let paths = url.pathComponents
                let id = paths[4]
                let types = ["doc":"document", "slides":"presentation", "sheet":"spreadsheet", "form":"form"]
                if paths.last == "export" {
                    guard value("mimeType") == "application/pdf", ["doc","slides","sheet"].contains(id) else { throw BadRequest() }
                    bytes = Data("%PDF-1.7 fictional export".utf8)
                } else if value("alt") == "media" {
                    guard id == "handout" else { throw BadRequest() }
                    bytes = Data("unmodified file".utf8)
                } else {
                    let type = types[id].map { "application/vnd.google-apps." + $0 } ?? "text/plain"
                    bytes = try json(["id": id, "name": id == "handout" ? "Week 7.txt" : "Week 7", "mimeType": type,
                                      "capabilities":["canDownload":id != "denied"], "size":id == "big" ? "33554433" : "15"])
                }
            case ("www.googleapis.com", "/calendar/v3/calendars/primary/events"):
                guard value("q") == "ICS 46", value("singleEvents") == "true",
                      value("orderBy") == "startTime", value("pageToken") == "p+1" else { throw BadRequest() }
                bytes = try json(["nextPageToken": "p+2", "items": [[
                    "id": "event7", "summary": "ICS 46 Lecture 7", "description": "Hash tables and review",
                    "location": "ICS 174", "htmlLink": "https://calendar.google.com/calendar/event?eid=event7&access_token=fictional-secret",
                    "status": "confirmed", "updated": "2026-11-20T18:00:00Z",
                    "start": ["dateTime": "2026-11-20T16:00:00-08:00"],
                    "end": ["dateTime": "2026-11-20T17:20:00-08:00"]
                ]]])
            case ("www.googleapis.com", let path) where path == "/calendar/v3/calendars/primary/events/event7":
                bytes = try json([
                    "id": "event7", "summary": "ICS 46 Lecture 7", "description": "Hash tables and review",
                    "location": "ICS 174", "htmlLink": "https://calendar.google.com/calendar/event?eid=event7&access_token=fictional-secret",
                    "status": "confirmed", "updated": "2026-11-20T18:00:00Z",
                    "start": ["dateTime": "2026-11-20T16:00:00-08:00"],
                    "end": ["dateTime": "2026-11-20T17:20:00-08:00"]
                ])
            case ("gmail.googleapis.com", "/gmail/v1/users/me/profile"):
                bytes = try json(["emailAddress":bearer == "Bearer fic-a" ? "student+class@example.invalid" : "other@example.invalid"])
            case ("gmail.googleapis.com", "/gmail/v1/users/me/messages"):
                guard value("q") == "subject:(ICS 46) after:2026/11/01", value("pageToken") == "next+2" else { throw BadRequest() }
                bytes = try json(["nextPageToken":"next+3", "messages":[["id":"plain","threadId":"thread7"],["id":"html","threadId":"thread7"]]])
            case ("gmail.googleapis.com", "/gmail/v1/users/me/messages/html/attachments/part7"):
                let html = "<body><script>private-script</script><h1>Lecture &amp; notes</h1><p>See <a href='https://example.invalid/read'>reading</a></p><img src='https://image.invalid/pixel'></body>"
                bytes = try json(["data":encoded(html), "size":html.utf8.count])
            case ("gmail.googleapis.com", "/gmail/v1/users/me/messages/attached/attachments/file9"):
                let pdf = "%PDF-1.7 fictional attachment"
                bytes = try json(["data":encoded(pdf), "size":pdf.utf8.count])
            case ("gmail.googleapis.com", let path) where path.hasPrefix("/gmail/v1/users/me/messages/"):
                let id = url.lastPathComponent
                let headers = [["name":"Subject","value":"Lecture \(id)"], ["name":"From","value":"Course Staff"], ["name":"Date","value":"Fri, 20 Nov 2026"]]
                var payload: [String: Any] = ["headers": headers]
                if value("format") == "metadata" {
                    guard Set(query.filter { $0.name == "metadataHeaders" }.compactMap(\.value)) == ["Subject","From","Date"] else { throw BadRequest() }
                } else {
                    guard value("format") == "full" else { throw BadRequest() }
                    payload["mimeType"] = "multipart/mixed"
                    let alternate: [String: Any] = ["mimeType":"multipart/alternative", "parts":[part("<p>duplicate-html</p>",type:"text/html"),part("readable plain body",type:"text/plain")]]
                    let skip: [String: Any] = ["mimeType":"text/plain","filename":"other.txt","body":["attachmentId":"must-not-fetch","size":10]]
                    switch id {
                    case "plain": payload["parts"] = [alternate, skip]
                    case "html": payload["parts"] = [["mimeType":"text/html", "body":["attachmentId":"part7"]], skip]
                    case "attached": payload["parts"] = [["mimeType":"application/pdf", "filename":"slides.pdf", "body":["attachmentId":"file9", "size":29]]]
                    case "inline": payload["parts"] = [["mimeType":"application/pdf", "filename":"handout.pdf", "body":["data":encoded("%PDF inline"), "size":11]]]
                    case "bad": payload["parts"] = [["mimeType":"text/plain", "body":["data":"**bad base64**"]]]
                    case "latin":
                        payload["parts"] = [["mimeType":"text/plain", "headers":[["name":"Content-Type","value":"text/plain; charset=iso-8859-1"]], "body":["data":"Y2Fm6Q==","size":4]]]
                    case "forbidden": status = 403
                    default: throw BadRequest()
                    }
                }
                bytes = try json(["id":id, "threadId":"thread7","payload":payload])
            default: throw BadRequest()
            }
            let response = try XCTUnwrap(HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class GoogleUniversityClientTests: XCTestCase {
    private func client(_ token: String = "fic-a") -> GoogleUniversityClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UniversityGoogleFixture.self]
        return GoogleUniversityClient(token: token, http: UniversityHTTP(configuration: configuration))
    }

    private func selected(_ id: String) -> UniversityItem {
        UniversityItem(id: id, title: "Chosen file", detail: "", metadata: ["mailbox":"student+class@example.invalid"])
    }

    private func selectedCalendar(_ id: String) -> UniversityItem {
        UniversityItem(id: id, title: "Calendar event", detail: "", metadata: ["calendarID": "primary"])
    }

    func testDriveEscapedSearchAndPageCursor() async throws {
        let page = try await client().items(kind: .drive, query: "ICS '46' + \\slides", cursor: "p+2")
        XCTAssertEqual(page.items.map(\.id), ["slides"])
        XCTAssertEqual(page.items.first?.title, "Lecture 7")
        XCTAssertEqual(page.next, "pg3")
    }

    func testWorkspaceExportsArePDFAndOrdinaryFileKeepsOriginal() async throws {
        for id in ["doc","slides","sheet"] {
            let file = try await client().document(kind: .drive, item: selected(id))
            XCTAssertEqual(file.filename, "Week 7.pdf")
            XCTAssertEqual(file.data, Data("%PDF-1.7 fictional export".utf8))
            let editor = ["doc": "document", "sheet": "spreadsheets", "slides": "presentation"][id]!
            XCTAssertEqual(file.sourceURL.absoluteString, "https://docs.google.com/\(editor)/d/\(id)/edit")
        }
        let file = try await client().document(kind: .drive, item: selected("handout"))
        XCTAssertEqual(file.filename, "Week 7.txt")
        XCTAssertEqual(file.data, Data("unmodified file".utf8))
    }

    func testDriveDeniedOversizeUnsupportedAndInvalidSelections() async throws {
        for id in ["denied","big","form","../files"] {
            do { _ = try await client().document(kind:.drive,item:selected(id)); XCTFail("Unexpected import") }
            catch { XCTAssertTrue(error is UniversityServiceError) }
        }
    }

    func testCalendarSearchAndEventImportPreserveExactIdentity() async throws {
        let page = try await client().items(kind: .calendar, query: "ICS 46", cursor: "p+1")
        let event = try XCTUnwrap(page.items.first)
        XCTAssertEqual(event.id, "event7")
        XCTAssertEqual(event.title, "ICS 46 Lecture 7")
        XCTAssertEqual(event.detail, "2026-11-20T16:00:00-08:00")
        XCTAssertEqual(page.next, "p+2")
        let document = try await client().document(kind: .calendar, item: selectedCalendar("event7"))
        XCTAssertEqual(document.remoteID, "primary/event7")
        XCTAssertEqual(document.sourceURL.host, "calendar.google.com")
        XCTAssertEqual(URLComponents(url: document.sourceURL, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["eid"])
        XCTAssertEqual(URLComponents(url: document.sourceURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "event7")
        let text = String(decoding: document.data, as: UTF8.self)
        XCTAssertTrue(text.contains("Hash tables and review"))
        XCTAssertTrue(text.contains("Location: ICS 174"))
    }

    func testGmailSearchListsMetadataAndPaginationWithMailboxIdentity() async throws {
        let page = try await client().items(kind:.gmail, query:"subject:(ICS 46) after:2026/11/01", cursor:"next+2")
        XCTAssertEqual(page.items.map(\.title),["Lecture plain","Lecture html"])
        XCTAssertEqual(page.items.first?.detail,"Course Staff · Fri, 20 Nov 2026")
        XCTAssertEqual(page.items.first?.metadata["importID"],"student+class@example.invalid/plain")
        XCTAssertEqual(page.next,"next+3")
    }

    func testGmailPlainAlternativeSkipsAttachmentsAndOpensExactThreadForAccount() async throws {
        let file = try await client().document(kind:.gmail,item:selected("plain"))
        let text = String(decoding:file.data,as:UTF8.self)
        XCTAssertTrue(text.contains("Subject: Lecture plain"))
        XCTAssertTrue(text.contains("Gmail message ID: plain"))
        XCTAssertTrue(text.contains("readable plain body"))
        XCTAssertFalse(text.contains("duplicate-html"))
        XCTAssertEqual(file.sourceURL.absoluteString,"https://mail.google.com/mail/u/?authuser=student%2Bclass@example.invalid#all/thread7")
        XCTAssertEqual(file.filename,"Lecture plain.txt")
    }

    func testGmailHTMLBodyStoredAsAttachmentAndLatin1Text() async throws {
        let file = try await client().document(kind:.gmail,item:selected("html"))
        let text = String(decoding:file.data,as:UTF8.self)
        XCTAssertTrue(text.contains("Lecture & notes"))
        XCTAssertTrue(text.contains("reading (https://example.invalid/read)"))
        XCTAssertFalse(text.contains("image.invalid"))
        XCTAssertFalse(text.contains("private-script"))
        let latin = try await client().document(kind:.gmail,item:selected("latin"))
        XCTAssertTrue(String(decoding:latin.data,as:UTF8.self).contains("café"))
    }

    func testGmailFileAttachmentMetadataAndDownload() async throws {
        let message = selected("attached")
        let attachments = try await client().gmailAttachments(for: message)
        XCTAssertEqual(attachments.map(\.title), ["slides.pdf"])
        XCTAssertEqual(attachments.first?.metadata["gmailMessageID"], "attached")
        XCTAssertEqual(attachments.first?.metadata["gmailBodyAttachmentID"], "file9")
        let file = try await client().document(kind: .gmail, item: try XCTUnwrap(attachments.first))
        XCTAssertEqual(file.filename, "slides.pdf")
        XCTAssertEqual(file.data, Data("%PDF-1.7 fictional attachment".utf8))
        XCTAssertEqual(file.remoteID, "student+class@example.invalid/attached/file9")
    }

    func testGmailInlineAttachmentUsesBoundedPartIdentity() async throws {
        let attachments = try await client().gmailAttachments(for: selected("inline"))
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertTrue(attachment.id.hasPrefix("inline-"))
        XCTAssertEqual(attachment.metadata["gmailPartPath"], "0.0")
        let file = try await client().document(kind: .gmail, item: attachment)
        XCTAssertEqual(file.filename, "handout.pdf")
        XCTAssertEqual(file.data, Data("%PDF inline".utf8))
    }

    func testAccountSwitchAndMalformedMessageFailWithoutImport() async throws {
        do { _ = try await client("fic-b").document(kind:.gmail,item:selected("plain")); XCTFail("Imported a different mailbox") }
        catch { XCTAssertTrue(error.localizedDescription.contains("account changed")) }
        for id in ["bad","forbidden"] {
            do { _ = try await client().document(kind:.gmail,item:selected(id)); XCTFail("Unexpected import") }
            catch { XCTAssertTrue(error is UniversityServiceError) }
        }
    }
}

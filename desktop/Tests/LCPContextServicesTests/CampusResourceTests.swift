import CoreGraphics
import Foundation
import XCTest
@testable import LCPContextServices

final class CampusResourceTests: XCTestCase {
    func testUciCampusLinksKeepStablePathAndStripTransientCredentials() throws {
        let piazza = try UciCampusLink(kind: .piazza,
                                       address: "https://piazza.com/class/abc123?token=private#recent")
        XCTAssertEqual(piazza.url.absoluteString, "https://piazza.com/class/abc123")
        XCTAssertEqual(piazza.kind, .piazza)

        let zoom = try UciCampusLink(kind: .zoom,
                                     address: "https://uci.zoom.us/j/123456789?pwd=private")
        XCTAssertEqual(zoom.url.absoluteString, "https://uci.zoom.us/j/123456789")
        XCTAssertEqual(zoom.kind, .zoom)

        for invalid in [
            "http://piazza.com/class/abc123",
            "https://piazza.com/login",
            "https://piazza.com.evil.invalid/class/abc123",
            "https://uci.zoom.us/login",
            "https://zoom.us/login",
            "https://account@uci.zoom.us/j/123"
        ] {
            XCTAssertThrowsError(try UciCampusLink(kind: invalid.contains("zoom") ? .zoom : .piazza, address: invalid))
        }
    }

    func testGradescopeSelectsCanonicalCourseAssignmentOrSubmission() throws {
        let assignment = try GradescopeResource(address: "https://gradescope.com/courses/123/assignments/43/submissions/321/?session=secret#question")
        XCTAssertTrue(assignment.isAssignment)
        XCTAssertEqual(assignment.url.absoluteString, "https://www.gradescope.com/courses/123/assignments/43/submissions/321")
        XCTAssertFalse(try GradescopeResource(address: "https://www.gradescope.com/courses/123").isAssignment)
        XCTAssertTrue(try GradescopeResource(address: "https://www.gradescope.com/assignments/99").isAssignment)
        for invalid in ["https://gradescope.com.evil.invalid/courses/1", "https://account@gradescope.com/courses/1",
                        "http://www.gradescope.com/courses/1", "https://www.gradescope.com/login",
                        "https://www.gradescope.com/courses/2/assignments", "https://www.gradescope.com/courses/%31"] {
            XCTAssertThrowsError(try GradescopeResource(address: invalid))
        }
    }

    func testDownloadedPDFUsesAssignmentProvenance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Reviewed submission.pdf")
        let url = try GradescopeResource(address: "https://www.gradescope.com/courses/10/assignments/22")
        let output = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: output))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &rect, nil))
        context.beginPDFPage(nil)
        context.fill(rect)
        context.endPDFPage()
        context.closePDF()
        let bytes = output as Data
        try bytes.write(to: file)
        let doc = try url.gradedPDF(at: file)
        XCTAssertEqual(doc.sourceURL, url.url)
        XCTAssertEqual(doc.filename, file.lastPathComponent)
        XCTAssertEqual(doc.data, bytes)
        XCTAssertThrowsError(try GradescopeResource(address: "https://www.gradescope.com/courses/10").gradedPDF(at: file))
        try Data("unexpected sign-in page".utf8).write(to: file)
        XCTAssertThrowsError(try url.gradedPDF(at: file))
    }

    func testRegistrarLookupUsesExactCourseAndSeparatesTextAndBrowserRequests() throws {
        let q = try UciRegistrarQuery(department: "ics", courseNumber: "h2a", year: 2026, term: .fall)
        XCTAssertEqual(q.department, "I&C SCI")
        XCTAssertEqual(q.courseNumber, "H2A")
        XCTAssertEqual(q.remoteID, "2026-92/I&C SCI/H2A")
        XCTAssertEqual(URLComponents(url: q.url(text: true), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name:"YearTerm",value:"2026-92"), URLQueryItem(name:"Dept",value:"I&C SCI"),
                        URLQueryItem(name:"CourseNum",value:"H2A"), URLQueryItem(name:"Submit",value:"Display Text Results")])
        XCTAssertFalse(q.url().absoluteString.contains("Submit"))
        XCTAssertThrowsError(try UciRegistrarQuery(department: "ALL", courseNumber: "0-999", year: 2026, term: .fall))
    }

    func testRegistrarTextImportAndEmptyResults() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistrarFixtureProtocol.self]
        let http = UniversityHTTP(configuration: config)
        let q = try UciRegistrarQuery(department: "I&C SCI", courseNumber: "46", year: 2026, term: .fall)
        let doc = try await q.load(using: http)
        let text = String(decoding: doc.data, as: UTF8.self)
        XCTAssertTrue(text.contains("FICTIONAL 46"))
        XCTAssertEqual(doc.sourceURL, q.url())
        for invalid in ["999", "23"] {
            let other = try UciRegistrarQuery(department: "I&C SCI", courseNumber: invalid, year: 2026, term: .fall)
            do { _ = try await other.load(using: http); XCTFail("Empty or invalid response must not become a source") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
}

private final class RegistrarFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.reg.uci.edu" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              params.contains(URLQueryItem(name: "Submit", value: "Display Text Results")) else { return }
        let empty = params.contains(URLQueryItem(name:"CourseNum",value:"999"))
        let html = params.contains(URLQueryItem(name:"CourseNum",value:"23"))
        let ending = empty ? "**** No courses matched your search criteria for this term." : "FICTIONAL 46\n*** Total Classes Displayed: 1"
        let text = "UC Irvine Office of the Registrar\nSchedule of Classes\n" + ending
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": html ? "text/html" : "text/plain; charset=ISO-8859-1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

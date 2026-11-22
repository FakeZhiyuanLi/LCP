import Foundation
import XCTest
@testable import LCPContextServices

final class UniversityHTTPTests: XCTestCase {
    func testRedirectToAssetCDNStripsBearerForRemainderOfChain() throws {
        let origin = URL(string: "https://canvas.example.edu/api/v1/files/12")!
        let asset = URL(string: "https://files.cdn.example.edu/material.pdf")!
        var request = URLRequest(url: origin)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        let (_, result) = AsyncThrowingStream<(Data, HTTPURLResponse), Error>.makeStream()
        let delegate = UniversityResponse(allowedHosts: ["canvas.example.edu", "*.cdn.example.edu"], limit: 100, result: result)
        func redirect(to destination: URL) -> URLRequest? {
            var next = request
            next.url = destination
            let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var redirected: URLRequest?
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) { redirected = $0 }
            return redirected
        }
        XCTAssertEqual(redirect(to: origin)?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(redirect(to: asset)?.url, asset)
        XCTAssertNil(redirect(to: asset)?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(redirect(to: origin)?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(redirect(to: URL(string: "https://other.example.edu/material.pdf")!))
    }

    func testStreamedBodyEnforcesLimitWithoutContentLength() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UniversityChunkProtocol.self]
        let http = UniversityHTTP(configuration: config)
        let url = URL(string: "https://course.example.edu/lecture")!
        let (data, _) = try await http.get(url, allowedHosts: ["course.example.edu"], limit: 8)
        XCTAssertEqual(data, Data("12345678".utf8))
        do {
            _ = try await http.get(url, allowedHosts: ["course.example.edu"], limit: 7)
            XCTFail("An oversized streamed response should be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
    }
}

private final class UniversityChunkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("1234".utf8))
        client?.urlProtocol(self, didLoad: Data("5678".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

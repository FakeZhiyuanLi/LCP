import CryptoKit
import Foundation
import XCTest
@testable import LCPContextServices

final class ElevenLabsTranscriptionClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ElevenLabsFixtureProtocol.response = [:]
        ElevenLabsFixtureProtocol.apiKey = nil
        ElevenLabsFixtureProtocol.didReceiveRequest = false
    }

    func testTranscribeSkipsSpacingAndReadsAudioEvents() async throws {
        let audio = Data("fictional-audio".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("lecture.m4a")
        try audio.write(to: audioURL)

        ElevenLabsFixtureProtocol.response = [
            "language_code": "en",
            "audio_duration_secs": 2.5,
            "words": [
                ["type": "word", "start": 0.0, "end": 0.4, "text": "Hello", "speaker_id": "speaker_0"],
                ["type": "spacing", "start": 0.4, "end": 0.5, "text": " "],
                ["type": "word", "start": 0.5, "end": 1.0, "text": "world", "speaker_id": "speaker_0"]
            ],
            "audio_events": [["type": "audio_event", "start": 1.1, "end": 1.4, "text": "door closes"]]
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElevenLabsFixtureProtocol.self]
        let client = try ElevenLabsTranscriptionClient(apiKey: "fixture-key", configuration: configuration)

        let result = try await client.transcribe(audioURL: audioURL,
                                                 expectedSize: UInt64(audio.count),
                                                 expectedSHA256: SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined())

        XCTAssertEqual(result.languageCode, "en")
        XCTAssertEqual(result.cues.map(\.text), ["Hello", "world"])
        XCTAssertEqual(result.cues.map(\.speaker), ["speaker_0", "speaker_0"])
        XCTAssertEqual(result.audioEvents.map(\.text), ["door closes"])
        XCTAssertEqual(result.duration, 2.5)
        XCTAssertEqual(ElevenLabsFixtureProtocol.apiKey, "fixture-key")
    }

    func testInvalidAudioIdentityIsRejectedBeforeUpload() async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fictional-audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ElevenLabsFixtureProtocol.self]
        let client = try ElevenLabsTranscriptionClient(apiKey: "fixture-key", configuration: configuration)

        do {
            _ = try await client.transcribe(audioURL: audioURL, expectedSize: 1, expectedSHA256: "0")
            XCTFail("A changed recording identity must be rejected before upload")
        } catch let error as ElevenLabsTranscriptionError {
            XCTAssertEqual(error, .invalidAudio)
        }
        XCTAssertFalse(ElevenLabsFixtureProtocol.didReceiveRequest)
    }
}

private final class ElevenLabsFixtureProtocol: URLProtocol {
    static var response: [String: Any] = [:]
    static var apiKey: String?
    static var didReceiveRequest = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.didReceiveRequest = true
        Self.apiKey = request.value(forHTTPHeaderField: "xi-api-key")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = (try? JSONSerialization.data(withJSONObject: Self.response)) ?? Data()
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

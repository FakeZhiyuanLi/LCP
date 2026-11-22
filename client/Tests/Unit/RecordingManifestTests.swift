import Foundation
import XCTest
@testable import LCPClient

final class RecordingManifestTests: XCTestCase {
    func testWritesExactManifestAtomicallyBesideUnchangedAudio() throws {
        let directory = try temporaryDirectory()
        let audio = directory.appendingPathComponent("CS182_2026-10-18_1430.m4a")
        let bytes = Data("abc".utf8)
        try bytes.write(to: audio)

        let ready = try RecordingManifest.write(for: audio)
        XCTAssertEqual(ready.lastPathComponent, "CS182_2026-10-18_1430.m4a.ready.json")
        let data = try Data(contentsOf: ready)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "filename", "size_bytes", "sha256"])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["filename"] as? String, audio.lastPathComponent)
        XCTAssertEqual(json["size_bytes"] as? Int, 3)
        XCTAssertEqual(json["sha256"] as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), [audio.lastPathComponent, ready.lastPathComponent])
    }

    func testHashesAllBytesAcrossMultipleReadChunks() throws {
        let audio = try temporaryDirectory().appendingPathComponent("CS182_2026-10-18_1430.m4a")
        let count = 2 * 1_048_576 + 17
        try Data(repeating: 0x5a, count: count).write(to: audio)
        let ready = try RecordingManifest.write(for: audio)
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: ready))
        XCTAssertEqual(manifest.sizeBytes, UInt64(count))
        XCTAssertEqual(manifest.sha256, "c8eb7ce230a6e501f7a84684fbe5108a58703a22733e7b579039c939f38f9a88")
    }

    func testMissingEmptyAndDirectorySourcesCannotPublishManifest() throws {
        let directory = try temporaryDirectory()
        let audio = directory.appendingPathComponent("CS182_2026-10-18_1430.m4a")
        XCTAssertThrowsError(try RecordingManifest.write(for: audio))
        try Data().write(to: audio)
        XCTAssertThrowsError(try RecordingManifest.write(for: audio))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingManifest.readyURL(for: audio).path))
        XCTAssertThrowsError(try RecordingManifest.write(for: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingManifest.readyURL(for: directory).path))
    }

    func testMarkerWriteFailurePreservesRecordingAndLeavesNoTemporaryFiles() throws {
        let directory = try temporaryDirectory()
        let audio = directory.appendingPathComponent("CS182_2026-10-18_1430.m4a")
        let bytes = Data("preserve the lecture".utf8)
        try bytes.write(to: audio)
        let ready = RecordingManifest.readyURL(for: audio)
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: false)

        XCTAssertThrowsError(try RecordingManifest.write(for: audio))
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), [audio.lastPathComponent, ready.lastPathComponent])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

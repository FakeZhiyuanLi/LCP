import XCTest
import CryptoKit
import LCPContextCore
@testable import LCPContextServices

@MainActor
final class FeedImporterTests: XCTestCase {
    private static let sourceDigest = String(repeating: "a", count: 64)
    private static let filename = "Fictional CS_2026-11-19_1100.m4a"
    private func fixture() throws -> (ContextRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-feed-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let feed = root.appendingPathComponent("feed")
        try FileManager.default.createDirectory(at: feed.appendingPathComponent("payloads"), withIntermediateDirectories: true)
        return (try ContextRepository(rootURL: root.appendingPathComponent("library")), feed)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    @discardableResult
    private func feed(_ directory: URL, generation: String = "g1", exported: String = "2026-11-19T10:00:00Z",
                      text: String = "A hash table maps keys to values.", quality: String = "eligible",
                      withPayload: Bool = true, retired: Bool = false, change: ((inout [String: Any]) -> Void)? = nil) throws -> URL? {
        var payload: [String: Any] = ["schema_version": 1, "filename": Self.filename, "size_bytes": 123,
            "sha256": Self.sourceDigest, "accepted_job_id": "opaque-job-v1", "generated_at": exported,
            "cues": [["start": 0.0, "end": 2.0, "text": text, "speaker": "speaker_0"]], "audio_events": []]
        change?(&payload)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let digest = hash(data)
        let payloadURL = directory.appendingPathComponent("payloads/\(digest).json")
        try data.write(to: payloadURL)
        let identity: [String: Any] = ["filename": Self.filename, "size_bytes": 123, "sha256": Self.sourceDigest]
        var recording = identity
        recording["accepted_job_id"] = "opaque-job-v1"
        recording["status"] = ["server_received": true, "processing": "complete", "quality": quality,
            "drive_publication": "pending", "external_ingestion": "unknown"]
        recording["transcript"] = withPayload ? ["path": "payloads/\(digest).json", "sha256": digest,
            "size_bytes": data.count, "accepted_job_id": "opaque-job-v1"] : NSNull()
        var retirement = identity; retirement["reason"] = "explicitly retired"
        let index: [String: Any] = ["schema_version": 1, "generation_id": generation, "exported_at": exported,
            "producer": ["id": "fixture-exporter", "environment": "synthetic"], "complete": true,
            "recordings": retired ? [] : [recording], "retirements": retired ? [retirement] : []]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        return withPayload ? payloadURL : nil
    }
    private func editIndex(_ directory: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent("index.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        mutate(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    func testCompleteGenerationPersistsAndDuplicateIsIdempotent() throws {
        let (repository, directory) = try fixture(); try feed(directory)
        let importer = FeedImporter(repository: repository, now: { ISO8601DateFormatter().date(from: "2026-11-19T11:00:00Z")! })
        let result = try importer.importGeneration(from: directory)
        XCTAssertEqual(result.importedRecordings, 1); XCTAssertEqual(result.importedTranscripts, 1)
        XCTAssertFalse(result.isDuplicate); XCTAssertFalse(result.isStale)
        XCTAssertNil(repository.state.recordings[0].classID); XCTAssertNil(repository.state.recordings[0].capturedAt)
        XCTAssertEqual(repository.state.recordings[0].legacyLocalTimestamp, "2026-11-19_1100")
        XCTAssertEqual(repository.state.recordings[0].status.drivePublication, "pending")
        XCTAssertEqual(repository.state.recordings[0].status.externalIngestion, "unknown")
        let state = repository.state
        XCTAssertTrue(try importer.importGeneration(from: directory).isDuplicate); XCTAssertEqual(repository.state, state)
        let reopened = try ContextRepository(rootURL: repository.rootURL); XCTAssertEqual(reopened.state, state)
    }
    func testMissingAndCorruptPayloadPreserveLastGoodThenArrivalRecovers() throws {
        let (repository, directory) = try fixture(); try feed(directory)
        let importer = FeedImporter(repository: repository); try importer.importGeneration(from: directory); let good = repository.state
        let payload = try XCTUnwrap(feed(directory, generation: "g2", exported: "2026-11-19T11:00:00Z", text: "A repaired transcript."))
        let valid = try Data(contentsOf: payload); try FileManager.default.removeItem(at: payload)
        XCTAssertThrowsError(try importer.importGeneration(from: directory)); XCTAssertEqual(repository.state, good)
        try Data("corrupt".utf8).write(to: payload)
        XCTAssertThrowsError(try importer.importGeneration(from: directory)); XCTAssertEqual(repository.state, good)
        try valid.write(to: payload)
        XCTAssertEqual(try importer.importGeneration(from: directory).importedTranscripts, 1)
        XCTAssertEqual(repository.state.transcriptRevisions.count, 2)
    }
    func testSameJobRepairPreservesMappingNotesAndHistoricalPayload() throws {
        let (repository, directory) = try fixture(); try feed(directory)
        let importer = FeedImporter(repository: repository); try importer.importGeneration(from: directory)
        let term = AcademicTerm(name: "Fictional term")
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "CS", title: "Fictional structures")
        let note = ActivityEntry(classID: enrollment.id, title: "My local note", body: "Keep this.")
        try repository.update { state in
            state.terms.append(term); state.classes.append(enrollment); state.activities.append(note)
            state.recordings[0].classID = enrollment.id; state.recordings[0].localAudioPath = "/fictional/audio.m4a"
        }
        let old = repository.state.transcriptRevisions[0]; let oldBytes = try repository.payloadData(old.content)
        try feed(directory, generation: "g2", exported: "2026-11-19T11:00:00Z", text: "Repaired source version.")
        try importer.importGeneration(from: directory)
        XCTAssertEqual(repository.state.recordings[0].classID, enrollment.id)
        XCTAssertEqual(repository.state.recordings[0].localAudioPath, "/fictional/audio.m4a")
        XCTAssertEqual(repository.state.activities[0].body, "Keep this.")
        XCTAssertEqual(repository.state.transcriptRevisions.count, 2); XCTAssertEqual(repository.state.transcriptRevisions[0], old)
        XCTAssertEqual(try repository.payloadData(old.content), oldBytes)
        XCTAssertEqual(Set(repository.state.transcriptRevisions.map(\.acceptedJobID)), ["opaque-job-v1"])
        try feed(directory, generation: "g3", exported: "2026-11-19T12:00:00Z", retired: true)
        try importer.importGeneration(from: directory)
        XCTAssertTrue(repository.state.recordings[0].retired)
        XCTAssertEqual(repository.state.transcriptRevisions.count, 2); XCTAssertEqual(repository.state.activities[0].body, "Keep this.")
    }
    func testFutureSchemaAndIncompleteIndexDoNotCommit() throws {
        let (repository, directory) = try fixture(); try feed(directory); let state = repository.state
        try editIndex(directory) { $0["schema_version"] = 99 }
        XCTAssertThrowsError(try FeedImporter(repository: repository).importGeneration(from: directory)); XCTAssertEqual(repository.state, state)
        try feed(directory); try editIndex(directory) { $0["complete"] = false }
        XCTAssertThrowsError(try FeedImporter(repository: repository).importGeneration(from: directory)); XCTAssertEqual(repository.state, state)
    }
    func testTraversalAndSymlinkPayloadsAreRejected() throws {
        let (repository, directory) = try fixture(); let payload = try XCTUnwrap(feed(directory)); let original = try Data(contentsOf: payload)
        try editIndex(directory) { index in
            var recordings = index["recordings"] as! [[String: Any]]
            var reference = recordings[0]["transcript"] as! [String: Any]
            reference["path"] = "../outside.json"; recordings[0]["transcript"] = reference; index["recordings"] = recordings
        }
        XCTAssertThrowsError(try FeedImporter(repository: repository).importGeneration(from: directory))
        try feed(directory)
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.json")
        try original.write(to: outside); try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
        XCTAssertThrowsError(try FeedImporter(repository: repository).importGeneration(from: directory)); XCTAssertTrue(repository.state.recordings.isEmpty)
    }
    func testInvalidCueAndMismatchedIdentityAreRejected() throws {
        let (repository, directory) = try fixture()
        try feed(directory, change: { $0["cues"] = [["start": 1.0, "end": 1.0, "text": "Not speech."]] })
        XCTAssertThrowsError(try FeedImporter(repository: repository).importGeneration(from: directory))
        try feed(directory, change: { $0["sha256"] = String(repeating: "b", count: 64) })
        XCTAssertThrowsError(try FeedImporter(repository: repository).importGeneration(from: directory)); XCTAssertTrue(repository.state.recordings.isEmpty)
    }
    func testBlockedQualityNeverImportsAttachedContent() throws {
        let (repository, directory) = try fixture(); try feed(directory, quality: "blocked")
        XCTAssertThrowsError(try FeedImporter(repository: repository).importGeneration(from: directory)); XCTAssertTrue(repository.state.recordings.isEmpty)
        try feed(directory, quality: "blocked", withPayload: false)
        try FeedImporter(repository: repository).importGeneration(from: directory)
        XCTAssertEqual(repository.state.recordings[0].status.quality, "blocked"); XCTAssertTrue(repository.state.transcriptRevisions.isEmpty)
    }
    func testOldGenerationAndReusedGenerationIDCannotReplaceCurrent() throws {
        let (repository, directory) = try fixture(); try feed(directory, exported: "2026-11-19T12:00:00Z")
        let importer = FeedImporter(repository: repository); try importer.importGeneration(from: directory); let good = repository.state
        try feed(directory, generation: "old", exported: "2026-11-19T10:00:00Z")
        XCTAssertThrowsError(try importer.importGeneration(from: directory)); XCTAssertEqual(repository.state, good)
        try feed(directory, exported: "2026-11-19T12:00:00Z", text: "Changed same generation.")
        XCTAssertThrowsError(try importer.importGeneration(from: directory)); XCTAssertEqual(repository.state, good)
    }
    func testOtherProcessNewerGenerationIsRefreshedBeforeImport() throws {
        let (first, directory) = try fixture(); let staleReader = try ContextRepository(rootURL: first.rootURL)
        try feed(directory, generation: "new", exported: "2026-11-19T12:00:00Z")
        try FeedImporter(repository: first).importGeneration(from: directory)
        try feed(directory, generation: "old", exported: "2026-11-19T10:00:00Z")
        XCTAssertThrowsError(try FeedImporter(repository: staleReader).importGeneration(from: directory))
        XCTAssertEqual(staleReader.state.feedGeneration?.id, "new")
    }
    func testAbsentItemsDoNotRetireAndChangedProducerRejected() throws {
        let (repository, directory) = try fixture(); try feed(directory)
        let importer = FeedImporter(repository: repository); try importer.importGeneration(from: directory)
        try feed(directory, generation: "empty", exported: "2026-11-19T11:00:00Z"); try editIndex(directory) { $0["recordings"] = [] }
        try importer.importGeneration(from: directory); XCTAssertFalse(repository.state.recordings[0].retired)
        try feed(directory, generation: "other", exported: "2026-11-19T12:00:00Z")
        try editIndex(directory) { $0["producer"] = ["id": "unrelated", "environment": "synthetic"] }
        XCTAssertThrowsError(try importer.importGeneration(from: directory)); XCTAssertEqual(repository.state.feedGeneration?.id, "empty")
    }
    func testReturningToAlreadyRetainedRevisionSelectsExactCurrentPointer() throws {
        let (repository, directory) = try fixture(); try feed(directory)
        let originalIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let importer = FeedImporter(repository: repository); try importer.importGeneration(from: directory)
        let originalRevisionID = repository.state.recordings[0].currentTranscriptRevisionID
        try feed(directory, generation: "repair", exported: "2026-11-19T11:00:00Z", text: "Revision B.")
        try importer.importGeneration(from: directory)
        XCTAssertNotEqual(repository.state.recordings[0].currentTranscriptRevisionID, originalRevisionID)
        try originalIndex.write(to: directory.appendingPathComponent("index.json"))
        try editIndex(directory) { $0["generation_id"] = "return-to-a"; $0["exported_at"] = "2026-11-19T12:00:00Z" }
        let result = try importer.importGeneration(from: directory)
        XCTAssertEqual(result.importedTranscripts, 0)
        XCTAssertEqual(repository.state.transcriptRevisions.count, 2)
        XCTAssertEqual(repository.state.recordings[0].currentTranscriptRevisionID, originalRevisionID)
    }

    func testIdenticalGenerationRehydratesExplicitlyPurgedCurrentCache() throws {
        let (repository, directory) = try fixture(); try feed(directory)
        let importer = FeedImporter(repository: repository); try importer.importGeneration(from: directory)
        let recordingID = repository.state.recordings[0].id
        let firstDigest = repository.state.transcriptRevisions[0].content.sha256
        let cleanup = try repository.purgeUnpinnedTranscriptCaches()
        XCTAssertEqual(cleanup.revisionsRemoved, 1)
        XCTAssertTrue(repository.state.transcriptRevisions.isEmpty)
        XCTAssertNil(repository.state.recordings[0].currentTranscriptRevisionID)
        XCTAssertEqual(repository.state.recordings[0].status.transcriptAvailable, "not_cached")
        let result = try importer.importGeneration(from: directory)
        XCTAssertFalse(result.isDuplicate)
        XCTAssertEqual(result.importedRecordings, 0)
        XCTAssertEqual(result.importedTranscripts, 1)
        XCTAssertEqual(repository.state.recordings[0].id, recordingID)
        XCTAssertEqual(repository.state.transcriptRevisions[0].content.sha256, firstDigest)
        XCTAssertEqual(repository.state.recordings[0].status.transcriptAvailable, "available")
        XCTAssertEqual(repository.state.recordings[0].currentTranscriptRevisionID, repository.state.transcriptRevisions[0].id)
        XCTAssertEqual(repository.state.feedGenerations.count, 1)
        XCTAssertTrue(try importer.importGeneration(from: directory).isDuplicate)
    }

}

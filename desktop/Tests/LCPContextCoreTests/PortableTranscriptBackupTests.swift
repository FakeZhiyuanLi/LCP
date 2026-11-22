import Foundation
import XCTest
@testable import LCPContextCore

final class PortableTranscriptBackupTests: XCTestCase {
    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-portable-transcript-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func addRevision(_ repository: ContextRepository, recording: LectureRecording,
                                         text: String) throws -> TranscriptRevision {
        let reference = try repository.storePayload(Data(text.utf8), mediaType: "text/plain")
        let revision = TranscriptRevision(recordingID: recording.id, acceptedJobID: "same-fictional-job",
            content: reference, cues: [TranscriptCue(start: 0, end: 1, text: text)],
            audioEvents: [TranscriptAudioEvent(start: 1, end: 2, text: "Event for " + text)], duration: 2)
        try repository.update {
            $0.transcriptRevisions.append(revision)
            $0.recordings[0].currentTranscriptRevisionID = revision.id
            $0.recordings[0].acceptedJobID = revision.acceptedJobID
            $0.recordings[0].status.transcriptAvailable = "available"
        }
        return revision
    }

    @MainActor func testPortableBackupOmitsCurrentCacheAndResolvesHistoricalCitationOffline() async throws {
        let root = temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let term = AcademicTerm(name: "Fictional spring")
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "SYN", title: "Synthetic seminar")
        let recording = LectureRecording(classID: enrollment.id, filename: "SYN_seminar.m4a",
            sizeBytes: 2, sha256: String(repeating: "a", count: 64),
            status: LectureStatusFacts(quality: "eligible", drivePublication: "published"))
        try repository.update {
            $0.terms.append(term)
            $0.classes.append(enrollment)
            $0.recordings.append(recording)
        }
        let pinned = try addRevision(repository, recording: recording, text: "Fictional historical cue.")
        let citation = SourceCitation(classID: enrollment.id, sourceKind: "transcript", sourceID: recording.id,
            revisionID: pinned.id, payloadSHA256: pinned.content.sha256, locator: .cues(start: 0, end: 0))
        try repository.update { $0.pinnedCitations.append(citation) }
        try repository.update { $0.recordings[0].classID = nil }
        // The association ledger is now the sole owner of the source citation.
        try repository.update { $0.pinnedCitations = []; $0.pinnedPayloads = [] }
        let disposableText = "Only the disposable replacement mentions a fictional silver kite."
        let disposable = try addRevision(repository, recording: recording, text: disposableText)
        let before = repository.state
        let backup = root.appendingPathComponent("portable")
        try repository.exportBackup(to: backup)

        let contextBytes = try Data(contentsOf: backup.appendingPathComponent("context.json"))
        XCTAssertNil(contextBytes.range(of: Data(disposableText.utf8)), "A cache can also leak through inline cues or audio events.")
        let manifestURL = backup.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ContextBackupManifest.self, from: manifestBytes)
        XCTAssertTrue(manifest.payloads.contains(pinned.content))
        XCTAssertFalse(manifest.payloads.contains(disposable.content))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            backup.appendingPathComponent("payloads/\(disposable.content.sha256).blob").path))
        let manifestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        let omissions = manifestJSON["omittedTranscriptCaches"] as? [[String: String]]
        XCTAssertEqual(omissions, [["recordingID": recording.id.uuidString, "revisionID": disposable.id.uuidString,
                                    "payloadSHA256": disposable.content.sha256]])

        let offline = try ContextRepository(rootURL: root.appendingPathComponent("fresh"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(offline.state.transcriptRevisions, [pinned])
        XCTAssertEqual(offline.state.recordingForCitation(citation)?.id, recording.id)
        XCTAssertEqual(try offline.payloadData(pinned.content), Data(pinned.cues[0].text.utf8))
        var expectedRecording = before.recordings[0]
        expectedRecording.currentTranscriptRevisionID = nil
        expectedRecording.status.transcriptAvailable = "not_cached"
        XCTAssertEqual(offline.state.recordings, [expectedRecording])
        XCTAssertThrowsError(try offline.payloadData(disposable.content))
        try repository.refresh()
        XCTAssertEqual(repository.state, before)
        XCTAssertEqual(try repository.payloadData(disposable.content), Data(disposableText.utf8))
    }

    @MainActor func testFullRecoveryCopyAndOlderBackupWithoutOmissionListRestoreCurrentCache() async throws {
        let root = temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let emptyBackup = root.appendingPathComponent("before-recording")
        try repository.exportBackup(to: emptyBackup)
        let recording = LectureRecording(filename: "SYN_recovery.m4a", sizeBytes: 2, sha256: String(repeating: "b", count: 64))
        try repository.update { $0.recordings.append(recording) }
        let revision = try addRevision(repository, recording: recording, text: "Private recovery copy fixture.")
        let originalRecordings = repository.state.recordings
        try repository.restoreBackup(from: emptyBackup)
        XCTAssertTrue(repository.state.recordings.isEmpty)
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: repository.rootURL.appendingPathComponent("backups"), includingPropertiesForKeys: nil).first)
        let url = recovery.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((manifest["omittedTranscriptCaches"] as? [Any])?.count, 0)
        // Earlier version-one archives included the cache and predate this field.
        manifest.removeValue(forKey: "omittedTranscriptCaches")
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        let restored = try ContextRepository(rootURL: root.appendingPathComponent("legacy-restore"))
        try restored.restoreBackup(from: recovery)
        XCTAssertEqual(restored.state.transcriptRevisions, [revision])
        XCTAssertEqual(restored.state.recordings, originalRecordings)
        XCTAssertEqual(try restored.payloadData(revision.content), Data(revision.cues[0].text.utf8))
    }

    @MainActor func testAbsentDisposableFileDoesNotPreventBackupButMissingExplicitPinDoes() async throws {
        let root = temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let recording = LectureRecording(filename: "SYN_damaged.m4a", sizeBytes: 2, sha256: String(repeating: "c", count: 64))
        try repository.update { $0.recordings.append(recording) }
        let disposable = try addRevision(repository, recording: recording, text: "Disposable fictional bytes.")
        let pinned = try addRevision(repository, recording: recording, text: "Explicitly pinned fictional bytes.")
        try repository.update { $0.pinnedPayloads.append(pinned.content) }
        try FileManager.default.removeItem(at: repository.payloadURL(disposable.content))
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let restored = try ContextRepository(rootURL: root.appendingPathComponent("restored"))
        try restored.restoreBackup(from: backup)
        XCTAssertEqual(restored.state.transcriptRevisions, [pinned])
        XCTAssertEqual(restored.state.recordings, repository.state.recordings)
        try FileManager.default.removeItem(at: repository.payloadURL(pinned.content))
        let incomplete = root.appendingPathComponent("incomplete")
        XCTAssertThrowsError(try repository.exportBackup(to: incomplete))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomplete.path))
    }
}

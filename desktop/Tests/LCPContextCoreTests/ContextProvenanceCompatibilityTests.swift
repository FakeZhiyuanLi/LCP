import CryptoKit
import Foundation
import XCTest
@testable import LCPContextCore

final class ContextProvenanceCompatibilityTests: XCTestCase {
    @MainActor private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-provenance-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor private func seed(_ repository: ContextRepository) throws -> ClassEnrollment {
        let term = AcademicTerm(name: "Fictional university term")
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "SYN 101", title: "Synthetic source context")
        try repository.update { $0.terms.append(term); $0.classes.append(enrollment) }
        return enrollment
    }

    private func legacyBytes(_ state: ContextState) throws -> Data {
        let bytes = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (collection, keys) in [
            ("classes", ["sessionDetails", "location"]),
            ("activities", ["inputContextManifest"]),
            ("activityRevisions", ["inputContextManifest", "agentIdentity"]),
            ("grants", ["eventFrom", "eventUntil"]),
        ] {
            let records = try XCTUnwrap(object[collection] as? [[String: Any]])
            object[collection] = records.map { record in
                var record = record
                for key in keys { record.removeValue(forKey: key) }
                return record
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @MainActor func testPreAdditionV1BytesDecodeWithoutInventingFields() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let enrollment = try seed(repository)
        let connection = AgentConnection(name: "Fictional previous connection")
        try repository.update {
            $0.connections.append(connection)
            $0.grants.append(AgentGrant(connectionID: connection.id, allowedClassIDs: [enrollment.id]))
            $0.activities.append(ActivityEntry(classID: enrollment.id, kind: "agent_artifact", title: "Historical answer", agentIdentity: "Fictional agent"))
        }
        let legacy = try JSONDecoder().decode(ContextState.self, from: legacyBytes(repository.state))
        XCTAssertNil(legacy.classes[0].sessionDetails)
        XCTAssertNil(legacy.classes[0].location)
        XCTAssertNil(legacy.activities[0].inputContextManifest)
        XCTAssertNil(legacy.activityRevisions[0].inputContextManifest)
        XCTAssertNil(legacy.activityRevisions[0].agentIdentity)
        XCTAssertEqual(legacy.activities[0].agentIdentity, "Fictional agent")
        XCTAssertNil(legacy.grants[0].eventFrom)
        XCTAssertNil(legacy.grants[0].eventUntil)
    }

    @MainActor func testLegacyBackupAndPersistedStoreRemainWritableWithoutBackfilledHistory() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("original"))
        let enrollment = try seed(repository)
        try repository.update {
            $0.activities.append(ActivityEntry(classID: enrollment.id, kind: "agent_artifact", title: "Old answer", body: "Fictional old answer", agentIdentity: "Historical agent"))
        }
        let backup = root.appendingPathComponent("legacy-backup")
        try repository.exportBackup(to: backup)
        let contextURL = backup.appendingPathComponent("context.json")
        let original = try JSONDecoder().decode(ContextState.self, from: Data(contentsOf: contextURL))
        let oldBytes = try legacyBytes(original)
        try oldBytes.write(to: contextURL)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(ContextBackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.stateByteCount = UInt64(oldBytes.count)
        manifest.stateSHA256 = SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let target = root.appendingPathComponent("restored")
        let restored = try ContextRepository(rootURL: target)
        try restored.restoreBackup(from: backup)
        let historicalRevision = try XCTUnwrap(restored.state.activityRevisions.first)
        XCTAssertNil(historicalRevision.agentIdentity)
        let reopened = try ContextRepository(rootURL: target)
        try reopened.update { $0.terms[0].name = "Fictional renamed term" }
        XCTAssertEqual(reopened.state.activityRevisions, [historicalRevision])
        XCTAssertEqual(reopened.state.activities[0].agentIdentity, "Historical agent")
        XCTAssertNil(reopened.state.activities[0].inputContextManifest)
        try reopened.update { $0.activities[0].body = "Explicitly corrected answer" }
        XCTAssertEqual(reopened.state.activityRevisions.count, 2)
        XCTAssertEqual(reopened.state.activityRevisions[0], historicalRevision)
        XCTAssertEqual(reopened.state.activityRevisions[1].agentIdentity, "Historical agent")
    }

    @MainActor func testClassSessionDetailsSurviveReopenAndPortableRestore() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        _ = try seed(repository)
        try repository.update {
            $0.classes[0].sessionDetails = "Lecture Tuesday/Thursday; Friday discussion"
            $0.classes[0].location = "Fictional Hall 123"
        }
        let reopened = try ContextRepository(rootURL: repository.rootURL)
        XCTAssertEqual(reopened.state.classes, repository.state.classes)
        let backup = root.appendingPathComponent("backup")
        try reopened.exportBackup(to: backup)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(offline.state.classes[0].sessionDetails, "Lecture Tuesday/Thursday; Friday discussion")
        XCTAssertEqual(offline.state.classes[0].location, "Fictional Hall 123")
    }

    @MainActor func testManualInputManifestPinsOriginalTranscriptThroughCorrectionCleanupAndRestore() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let enrollment = try seed(repository)
        let content = try repository.storePayload(Data("Fictional immutable original transcript".utf8), mediaType: "application/json")
        let recording = LectureRecording(classID: enrollment.id, filename: "SYN_2026-11-19_1200.m4a", sizeBytes: 1, sha256: String(repeating: "c", count: 64))
        let transcript = TranscriptRevision(recordingID: recording.id, acceptedJobID: "fictional-original", content: content,
                                            cues: [TranscriptCue(start: 0, end: 1, text: "Original source")], duration: 1)
        let input = SourceCitation(classID: enrollment.id, sourceKind: "transcript", sourceID: recording.id,
                                   revisionID: transcript.id, payloadSHA256: content.sha256, locator: .cues(start: 0, end: 0))
        try repository.update {
            $0.recordings.append(recording); $0.transcriptRevisions.append(transcript)
            $0.activities.append(ActivityEntry(classID: enrollment.id, kind: "agent_artifact", title: "Reviewed answer", body: "Fictional answer",
                                               agentIdentity: "Fictional external agent", inputContextManifest: [input]))
        }
        let originalRevision = try XCTUnwrap(repository.state.activityRevisions.first)
        XCTAssertEqual(originalRevision.inputContextManifest, [input])
        XCTAssertTrue(repository.state.pinnedPayloads.contains(content))
        try repository.update {
            $0.activities[0].body = "A student correction"
            $0.activities[0].inputContextManifest = nil // Unknown new inputs do not erase old revision evidence.
            $0.recordings[0].retired = true
        }
        XCTAssertEqual(repository.state.activityRevisions[0], originalRevision)
        XCTAssertNil(repository.state.activityRevisions[1].inputContextManifest)
        try repository.update { $0.activities[0].inputContextManifest = [] }
        XCTAssertEqual(repository.state.activities[0].inputContextManifest, [SourceCitation]())
        let cleanup = try repository.purgeUnpinnedTranscriptCaches()
        XCTAssertEqual(cleanup.revisionsRemoved, 0)
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(offline.state.activityRevisions[0].inputContextManifest, [input])
        XCTAssertNil(offline.state.activityRevisions[1].inputContextManifest)
        XCTAssertEqual(offline.state.activityRevisions[2].inputContextManifest, [SourceCitation]())
        XCTAssertEqual(try offline.payloadData(content), Data("Fictional immutable original transcript".utf8))
        XCTAssertEqual(offline.state.transcriptRevisions, [transcript])
    }

    @MainActor func testInputManifestRequiresSameClassValidLocatorBytesAndBoundedSize() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let first = try seed(repository)
        let other = ClassEnrollment(termID: first.termID, courseCode: "SYN 202", title: "Different fictional class")
        try repository.update {
            $0.classes.append(other)
            $0.activities.append(ActivityEntry(classID: other.id, title: "Other class note", body: "Other fictional context"))
        }
        let source = try XCTUnwrap(repository.state.activities.first)
        let payload = try XCTUnwrap(source.content)
        let citation = SourceCitation(classID: other.id, sourceKind: "activity", sourceID: source.id,
                                      revisionID: source.revisionID, payloadSHA256: payload.sha256)
        let before = repository.state
        XCTAssertThrowsError(try repository.update {
            $0.activities.append(ActivityEntry(classID: first.id, title: "Wrong class input", inputContextManifest: [citation]))
        })
        var badLocator = citation
        badLocator.locator = .text(startUTF8: 99_999, lengthUTF8: 10)
        XCTAssertThrowsError(try repository.update {
            $0.activities.append(ActivityEntry(classID: other.id, title: "Invalid input locator", inputContextManifest: [badLocator]))
        })
        XCTAssertThrowsError(try repository.update {
            $0.activities.append(ActivityEntry(classID: other.id, title: "Too many inputs", inputContextManifest: Array(repeating: citation, count: 129)))
        })
        XCTAssertEqual(repository.state, before)
        try FileManager.default.removeItem(at: repository.payloadURL(payload))
        XCTAssertThrowsError(try repository.update {
            $0.activities.append(ActivityEntry(classID: other.id, title: "Missing input bytes", inputContextManifest: [citation]))
        })
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testGrantTimeBoundsAreFiniteOrderedAndPreservedOnReopen() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root)
        let enrollment = try seed(repository)
        let connection = AgentConnection(name: "Fictional bounded grant")
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        try repository.update {
            $0.connections.append(connection)
            $0.grants.append(AgentGrant(connectionID: connection.id, allowedClassIDs: [enrollment.id], eventFrom: start, eventUntil: end))
        }
        let before = repository.state
        XCTAssertThrowsError(try repository.update { $0.grants[0].eventFrom = end.addingTimeInterval(1) })
        XCTAssertThrowsError(try repository.update { $0.grants[0].eventUntil = Date(timeIntervalSinceReferenceDate: .infinity) })
        XCTAssertThrowsError(try repository.update { $0.grants[0].eventFrom = Date(timeIntervalSinceReferenceDate: .nan) })
        XCTAssertEqual(repository.state, before)
        let reopened = try ContextRepository(rootURL: root)
        XCTAssertEqual(reopened.state.grants[0].eventFrom, start)
        XCTAssertEqual(reopened.state.grants[0].eventUntil, end)
    }
}

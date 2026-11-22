import CryptoKit
import Foundation
import XCTest
@testable import LCPContextCore

final class ContextRepositoryTests: XCTestCase {
    @MainActor private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor @discardableResult
    private func seedClass(_ repository: ContextRepository, name: String = "Fictional fall") throws -> ClassEnrollment {
        let term = AcademicTerm(name: name)
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "SYN 101", title: "Synthetic context")
        try repository.update { state in state.terms.append(term); state.classes.append(enrollment) }
        return enrollment
    }

    @MainActor
    private func seedMaterial(_ repository: ContextRepository, classID: UUID, text: String = "A fictional source.") throws -> (SourceMaterial, MaterialRevision) {
        let original = try repository.storePayload(Data(text.utf8), mediaType: "text/plain")
        var material = SourceMaterial(classID: classID, title: "Fictional reading")
        let revision = MaterialRevision(materialID: material.id, original: original, text: original,
                                        extractorVersion: "synthetic-1", extractionState: "ready")
        material.currentRevisionID = revision.id
        try repository.update { $0.materials.append(material); $0.materialRevisions.append(revision) }
        return (material, revision)
    }

    @MainActor func testRepeatedCourseCodesRemainSeparateAfterReopen() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root)
        let first = try seedClass(repository)
        let second = try seedClass(repository, name: "Fictional winter")
        let date = LocalDate(year: 2028, month: 2, day: 29)
        try repository.update {
            $0.coursework.append(CourseworkItem(classID: first.id, title: "Date only", due: .dateOnly(date)))
            $0.coursework.append(CourseworkItem(classID: second.id, title: "Timed", due: .timed(instant: Date(timeIntervalSince1970: 100), timeZoneID: "UTC")))
        }
        let reopened = try ContextRepository(rootURL: root)
        XCTAssertEqual(reopened.state.classes.count, 2)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(reopened.state.coursework[0].due, .dateOnly(date))
        XCTAssertEqual(reopened.state.coursework[1].due, .timed(instant: Date(timeIntervalSince1970: 100), timeZoneID: "UTC"))
        XCTAssertNotEqual(reopened.state.classes[0].termID, reopened.state.classes[1].termID)
    }

    @MainActor func testNameOnlyClassCanReopenAndRestoreWithNoTerms() async throws {
        let root = try temporaryRoot()
        let library = root.appendingPathComponent("library")
        let repository = try ContextRepository(rootURL: library)
        let seminar = ClassEnrollment(title: "Film seminar")
        try repository.update { $0.classes.append(seminar) }
        XCTAssertEqual(seminar.shortLabel, seminar.title)
        XCTAssertEqual(seminar.displayLabel, seminar.title)
        XCTAssertEqual(try ContextRepository(rootURL: library).state.classes, [seminar])
        XCTAssertThrowsError(try repository.update { $0.classes[0].termID = UUID() })
        XCTAssertThrowsError(try repository.update { $0.classes[0].title = "  \n  " })
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let restored = try ContextRepository(rootURL: root.appendingPathComponent("restored"))
        try restored.restoreBackup(from: backup)
        XCTAssertEqual(restored.state.classes, [seminar])
        XCTAssertTrue(restored.state.terms.isEmpty)
    }

    @MainActor func testThrowingOrInvalidTransactionLeavesDiskAndMemoryUnchanged() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        try seedClass(repository)
        let before = repository.state
        enum Deliberate: Error { case stop }
        XCTAssertThrowsError(try repository.update { $0.terms.removeAll(); throw Deliberate.stop })
        XCTAssertEqual(repository.state, before)
        XCTAssertThrowsError(try repository.update { $0.terms.append($0.terms[0]) })
        XCTAssertThrowsError(try repository.update { $0.terms[0].startDate = LocalDate(year: 2026, month: 2, day: 29) })
        try repository.refresh()
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testConcurrentRepositoryInstancesReloadBeforeMutatingAndObserveRevocation() async throws {
        let root = try temporaryRoot()
        let desktop = try ContextRepository(rootURL: root)
        let enrollment = try seedClass(desktop)
        let connection = AgentConnection(name: "Synthetic agent", mode: "stdio")
        let grant = AgentGrant(connectionID: connection.id, allowedClassIDs: [enrollment.id])
        try desktop.update { $0.connections.append(connection); $0.grants.append(grant) }
        let bridge = try ContextRepository(rootURL: root)
        try desktop.update { $0.grants[0].revokedAt = Date() }
        try bridge.update { $0.activities.append(ActivityEntry(classID: enrollment.id, title: "Independent note")) }
        XCTAssertFalse(bridge.state.grants[0].isActive)
        try desktop.refresh()
        XCTAssertEqual(desktop.state.activities.count, 1)
        XCTAssertFalse(desktop.state.grants[0].isActive)
    }

    @MainActor func testActivityCorrectionsRetainExactCitablePayloads() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let enrollment = try seedClass(repository)
        let entry = ActivityEntry(classID: enrollment.id, title: "A note", body: "Original fictional observation.")
        try repository.update { $0.activities.append(entry) }
        let original = try XCTUnwrap(repository.state.activities.first)
        let content = try XCTUnwrap(original.content)
        let citation = SourceCitation(classID: enrollment.id, sourceKind: "activity", sourceID: original.id,
                                      revisionID: original.revisionID, payloadSHA256: content.sha256)
        try repository.update { $0.pinnedCitations.append(citation); $0.activities[0].body = "Corrected observation." }
        XCTAssertEqual(repository.state.activityRevisions.count, 2)
        XCTAssertEqual(repository.state.activities[0].version, 2)
        XCTAssertNotEqual(repository.state.activities[0].revisionID, original.revisionID)
        XCTAssertEqual(try repository.payloadData(content), Data(original.body.utf8))
        XCTAssertTrue(repository.state.pinnedPayloads.contains(content))
        let before = repository.state
        XCTAssertThrowsError(try repository.update { $0.activityRevisions[0].body = "Overwritten evidence" })
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testImmutableMaterialAndTranscriptIdentityCannotBeMutated() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let enrollment = try seedClass(repository)
        _ = try seedMaterial(repository, classID: enrollment.id)
        let content = try repository.storePayload(Data("fictional transcript".utf8), mediaType: "application/json")
        let recording = LectureRecording(classID: enrollment.id, filename: "SYN 101_2026-11-19_1200.m4a", sizeBytes: 1,
                                         sha256: String(repeating: "a", count: 64), acceptedJobID: "opaque-job")
        let transcript = TranscriptRevision(recordingID: recording.id, acceptedJobID: "opaque-job", content: content,
                                             cues: [TranscriptCue(start: 0, end: 1, text: "Fictional speech")], duration: 1)
        try repository.update { $0.recordings.append(recording); $0.transcriptRevisions.append(transcript) }
        XCTAssertThrowsError(try repository.update { $0.materialRevisions[0].extractorVersion = "changed" })
        XCTAssertThrowsError(try repository.update { $0.transcriptRevisions[0].cues[0].text = "changed" })
        XCTAssertThrowsError(try repository.update { $0.recordings[0].sha256 = String(repeating: "b", count: 64) })
        XCTAssertThrowsError(try repository.update { $0.transcriptRevisions.removeAll() })
    }

    @MainActor func testBackupRestoresOriginalsPinsAndActivityHistoryWithoutGrants() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let enrollment = try seedClass(repository)
        let (material, revision) = try seedMaterial(repository, classID: enrollment.id)
        let citation = SourceCitation(classID: enrollment.id, sourceKind: "material", sourceID: material.id,
                                      revisionID: revision.id, payloadSHA256: revision.original.sha256)
        let connection = AgentConnection(name: "Synthetic client")
        try repository.update {
            $0.connections.append(connection)
            $0.grants.append(AgentGrant(connectionID: connection.id, allowedClassIDs: [enrollment.id]))
            $0.activities.append(ActivityEntry(classID: enrollment.id, title: "Cited note", body: "Fictional reasoning", citations: [citation]))
        }
        try repository.update { $0.activities[0].body = "An explicit correction" }
        let backup = root.appendingPathComponent("portable")
        try repository.exportBackup(to: backup)
        let restored = try ContextRepository(rootURL: root.appendingPathComponent("restored"))
        try restored.restoreBackup(from: backup)
        XCTAssertEqual(restored.state.classes, repository.state.classes)
        XCTAssertEqual(restored.state.materialRevisions, repository.state.materialRevisions)
        XCTAssertEqual(restored.state.activityRevisions, repository.state.activityRevisions)
        XCTAssertEqual(restored.state.activities, repository.state.activities)
        XCTAssertTrue(restored.state.grants.isEmpty)
        XCTAssertEqual(try restored.payloadData(revision.original), Data("A fictional source.".utf8))
        XCTAssertTrue(restored.state.pinnedPayloads.contains(revision.original))
    }

    @MainActor func testIncompleteFutureAndSymlinkBackupsDoNotReplaceCurrentLibrary() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let enrollment = try seedClass(repository)
        let (_, revision) = try seedMaterial(repository, classID: enrollment.id)
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let before = repository.state
        let payload = backup.appendingPathComponent("payloads").appendingPathComponent(revision.original.sha256 + ".blob")
        try FileManager.default.removeItem(at: payload)
        XCTAssertThrowsError(try repository.restoreBackup(from: backup))
        XCTAssertEqual(repository.state, before)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: repository.payloadURL(revision.original))
        XCTAssertThrowsError(try repository.restoreBackup(from: backup))
        XCTAssertEqual(repository.state, before)
        try FileManager.default.removeItem(at: payload)
        try repository.payloadData(revision.original).write(to: payload)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(ContextBackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.version = 99
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        XCTAssertThrowsError(try repository.restoreBackup(from: backup))
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testMissingPayloadKeepsLibraryReadableAndCanBeRelinkedOrRestored() async throws {
        let root = try temporaryRoot()
        let library = root.appendingPathComponent("library")
        let repository = try ContextRepository(rootURL: library)
        let enrollment = try seedClass(repository)
        let (_, revision) = try seedMaterial(repository, classID: enrollment.id)
        let original = try repository.payloadData(revision.original)
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let path = try repository.payloadURL(revision.original)
        try FileManager.default.removeItem(at: path)
        let reopened = try ContextRepository(rootURL: library)
        XCTAssertEqual(reopened.state.classes.count, 1)
        XCTAssertEqual(reopened.unavailablePayloads.map(\.sha256), [revision.original.sha256])
        try reopened.update { $0.activities.append(ActivityEntry(classID: enrollment.id, title: "Offline note")) }
        XCTAssertThrowsError(try reopened.exportBackup(to: root.appendingPathComponent("incomplete")))
        _ = try reopened.storePayload(original, mediaType: revision.original.mediaType)
        try reopened.refresh()
        XCTAssertTrue(reopened.unavailablePayloads.isEmpty)
        try Data("corrupt bytes".utf8).write(to: path)
        _ = try reopened.storePayload(original, mediaType: revision.original.mediaType)
        XCTAssertEqual(try reopened.payloadData(revision.original), original)
        try FileManager.default.removeItem(at: path)
        try reopened.restoreBackup(from: backup)
        XCTAssertEqual(try reopened.payloadData(revision.original), original)
        XCTAssertTrue(reopened.unavailablePayloads.isEmpty)
    }

    @MainActor func testNewCitationsCannotPinMissingBytesOrWrongClass() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let enrollment = try seedClass(repository)
        let other = try seedClass(repository, name: "Another term")
        let (material, revision) = try seedMaterial(repository, classID: enrollment.id)
        let wrong = SourceCitation(classID: other.id, sourceKind: "material", sourceID: material.id,
                                  revisionID: revision.id, payloadSHA256: revision.original.sha256)
        XCTAssertThrowsError(try repository.update { $0.pinnedCitations.append(wrong) })
        let path = try repository.payloadURL(revision.original)
        try FileManager.default.removeItem(at: path)
        let missing = SourceCitation(classID: enrollment.id, sourceKind: "material", sourceID: material.id,
                                    revisionID: revision.id, payloadSHA256: revision.original.sha256)
        let before = repository.state
        XCTAssertThrowsError(try repository.update { $0.activities.append(ActivityEntry(classID: enrollment.id, title: "Bad pin", citations: [missing])) })
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testCitationLocatorsAreResolvableAndForgedBackupLocatorsFail() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let enrollment = try seedClass(repository)
        try repository.update { $0.activities.append(ActivityEntry(classID: enrollment.id, title: "Unicode note", body: "évidence")) }
        let activity = try XCTUnwrap(repository.state.activities.first)
        let activityContent = try XCTUnwrap(activity.content)
        var activityCitation = SourceCitation(classID: enrollment.id, sourceKind: "activity", sourceID: activity.id,
                                              revisionID: activity.revisionID, payloadSHA256: activityContent.sha256,
                                              locator: .text(startUTF8: 100, lengthUTF8: 1))
        XCTAssertThrowsError(try repository.update { $0.pinnedCitations.append(activityCitation) })
        activityCitation.locator = .text(startUTF8: 0, lengthUTF8: 1) // Half a UTF-8 scalar.
        XCTAssertThrowsError(try repository.update { $0.pinnedCitations.append(activityCitation) })
        activityCitation.locator = .page(1)
        XCTAssertThrowsError(try repository.update { $0.pinnedCitations.append(activityCitation) })
        activityCitation.locator = .text(startUTF8: 0, lengthUTF8: 2)
        try repository.update { $0.pinnedCitations.append(activityCitation) }

        struct Passage: Codable { var locator: SourceLocator; var text: String }
        struct Extraction: Codable { var schemaVersion = 1; var plainText: String; var passages: [Passage] }
        let text = "Fictional page evidence"
        let extracted = try repository.storePayload(JSONEncoder().encode(Extraction(plainText: text, passages: [Passage(locator: .page(1), text: text)])),
                                                   mediaType: "application/vnd.lcp.extracted+json")
        let original = try repository.storePayload(Data("fictional original".utf8))
        var material = SourceMaterial(classID: enrollment.id, title: "Page source")
        let revision = MaterialRevision(materialID: material.id, original: original, text: extracted, extractionState: "ready")
        material.currentRevisionID = revision.id
        try repository.update { $0.materials.append(material); $0.materialRevisions.append(revision) }
        var citation = SourceCitation(classID: enrollment.id, sourceKind: "material", sourceID: material.id,
                                      revisionID: revision.id, payloadSHA256: extracted.sha256, locator: .page(99))
        XCTAssertThrowsError(try repository.update { $0.pinnedCitations.append(citation) })
        citation.locator = .page(1)
        try repository.update { $0.pinnedCitations.append(citation) }
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let stateURL = backup.appendingPathComponent("context.json")
        var forged = try JSONDecoder().decode(ContextState.self, from: Data(contentsOf: stateURL))
        forged.pinnedCitations[1].locator = .page(99)
        let forgedBytes = try JSONEncoder().encode(forged)
        try forgedBytes.write(to: stateURL)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(ContextBackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.stateByteCount = UInt64(forgedBytes.count)
        manifest.stateSHA256 = SHA256.hash(data: forgedBytes).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let before = repository.state
        XCTAssertThrowsError(try repository.restoreBackup(from: backup))
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testCacheCleanupKeepsPinnedHistoricalTranscriptAndBackupReadable() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let enrollment = try seedClass(repository)
        let historical = try repository.storePayload(Data("original transcript A".utf8), mediaType: "application/json")
        let replacement = try repository.storePayload(Data("corrected transcript B".utf8), mediaType: "application/json")
        var recording = LectureRecording(classID: enrollment.id, filename: "SYN 101_2026-11-19_1200.m4a", sizeBytes: 2,
                                         sha256: String(repeating: "c", count: 64), acceptedJobID: "same-opaque-job")
        let a = TranscriptRevision(recordingID: recording.id, acceptedJobID: "same-opaque-job", content: historical,
                                   cues: [TranscriptCue(start: 0, end: 1, text: "Original A")], duration: 1)
        let b = TranscriptRevision(recordingID: recording.id, acceptedJobID: "same-opaque-job", content: replacement,
                                   cues: [TranscriptCue(start: 0, end: 1, text: "Replacement B")], duration: 1)
        recording.currentTranscriptRevisionID = b.id
        let citation = SourceCitation(classID: enrollment.id, sourceKind: "transcript", sourceID: recording.id,
                                      revisionID: a.id, payloadSHA256: historical.sha256, locator: .cues(start: 0, end: 0))
        try repository.update {
            $0.recordings.append(recording); $0.transcriptRevisions.append(contentsOf: [a, b])
            $0.activities.append(ActivityEntry(classID: enrollment.id, title: "Historical answer", citations: [citation]))
        }
        let result = try repository.purgeUnpinnedTranscriptCaches()
        XCTAssertEqual(result.revisionsRemoved, 1)
        XCTAssertEqual(result.payloadsRemoved, 1)
        XCTAssertEqual(repository.state.transcriptRevisions.map(\.id), [a.id])
        XCTAssertNil(repository.state.recordings[0].currentTranscriptRevisionID)
        XCTAssertEqual(repository.state.recordings[0].status.transcriptAvailable, "not_cached")
        XCTAssertThrowsError(try repository.payloadData(replacement))
        XCTAssertEqual(try repository.payloadData(historical), Data("original transcript A".utf8))
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(offline.state.transcriptRevisions, [a])
        XCTAssertEqual(try offline.payloadData(historical), Data("original transcript A".utf8))
    }

    @MainActor func testCorrectionLinksRequireSameClassAndAcyclicHistoryIncludingRestore() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let firstClass = try seedClass(repository)
        let secondClass = try seedClass(repository, name: "Different term")
        let first = ActivityEntry(classID: firstClass.id, title: "Original")
        let other = ActivityEntry(classID: secondClass.id, title: "Unrelated class")
        try repository.update { $0.activities.append(contentsOf: [first, other]) }
        let initial = repository.state
        XCTAssertThrowsError(try repository.update { $0.activities[0].supersedesID = UUID() })
        XCTAssertThrowsError(try repository.update { $0.activities[0].supersedesID = first.id })
        XCTAssertThrowsError(try repository.update { $0.activities[0].supersedesID = other.id })
        XCTAssertEqual(repository.state, initial)
        let correction = ActivityEntry(classID: firstClass.id, title: "Correction", supersedesID: first.id)
        let latest = ActivityEntry(classID: firstClass.id, title: "Later correction", supersedesID: correction.id)
        try repository.update { $0.activities.append(contentsOf: [correction, latest]) }
        let valid = repository.state
        XCTAssertThrowsError(try repository.update { $0.activities[0].supersedesID = latest.id })
        XCTAssertEqual(repository.state, valid)
        let backup = root.appendingPathComponent("backup")
        try repository.exportBackup(to: backup)
        let stateURL = backup.appendingPathComponent("context.json")
        var forged = try JSONDecoder().decode(ContextState.self, from: Data(contentsOf: stateURL))
        forged.activities[0].supersedesID = latest.id
        let forgedBytes = try JSONEncoder().encode(forged)
        try forgedBytes.write(to: stateURL)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(ContextBackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.stateByteCount = UInt64(forgedBytes.count)
        manifest.stateSHA256 = SHA256.hash(data: forgedBytes).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        XCTAssertThrowsError(try repository.restoreBackup(from: backup))
        XCTAssertEqual(repository.state, valid)
        try repository.refresh()
        XCTAssertEqual(repository.state, valid)
    }
}

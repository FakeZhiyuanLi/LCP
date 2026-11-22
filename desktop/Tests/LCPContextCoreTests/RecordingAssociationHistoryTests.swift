import CryptoKit
import Foundation
import XCTest
@testable import LCPContextCore

final class RecordingAssociationHistoryTests: XCTestCase {
    @MainActor private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-association-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor private func seed(_ repository: ContextRepository) throws -> (ClassEnrollment, ClassEnrollment) {
        let term = AcademicTerm(name: "Fictional association term")
        let first = ClassEnrollment(termID: term.id, courseCode: "SYN A", title: "Original fictional class")
        let second = ClassEnrollment(termID: term.id, courseCode: "SYN B", title: "Corrected fictional class")
        try repository.update { $0.terms.append(term); $0.classes.append(contentsOf: [first, second]) }
        return (first, second)
    }

    @MainActor private func transcript(_ repository: ContextRepository, recordingID: UUID, job: String) throws -> TranscriptRevision {
        let content = try repository.storePayload(Data("Fictional \(job) immutable payload".utf8), mediaType: "application/json")
        return TranscriptRevision(recordingID: recordingID, acceptedJobID: job, content: content,
            cues: (0..<8).map { TranscriptCue(start: Double($0), end: Double($0 + 1), text: "Fictional \(job) cue \($0)") }, duration: 8)
    }

    private func citation(_ recording: LectureRecording, revision: TranscriptRevision, classID: UUID, cue: Int) -> SourceCitation {
        SourceCitation(classID: classID, sourceKind: "transcript", sourceID: recording.id, revisionID: revision.id,
                       payloadSHA256: revision.content.sha256, locator: .cues(start: cue, end: cue), label: "Exact fictional cue \(cue)")
    }

    @MainActor func testCorrectionPreservesExactSavedCitationsAndSourceFactsThroughUnassignCleanupAndRestore() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let (first, second) = try seed(repository)
        var recording = LectureRecording(classID: first.id, filename: "SYN_2026-11-19_1200.m4a", sizeBytes: 123,
            sha256: String(repeating: "a", count: 64), capturedAt: Date(timeIntervalSince1970: 100), timeZoneID: "UTC",
            legacyLocalTimestamp: "2026-11-19_1200", acceptedJobID: "job-A", status: LectureStatusFacts(serverReceived: "yes", quality: "eligible"),
            localAudioPath: "/fictional/audio.m4a")
        let original = try transcript(repository, recordingID: recording.id, job: "job-A")
        recording.currentTranscriptRevisionID = original.id
        let pinned = citation(recording, revision: original, classID: first.id, cue: 0)
        let cited = citation(recording, revision: original, classID: first.id, cue: 1)
        let input = citation(recording, revision: original, classID: first.id, cue: 2)
        let proposalInput = citation(recording, revision: original, classID: first.id, cue: 3)
        let proposalCitation = citation(recording, revision: original, classID: first.id, cue: 4)
        let proposed = AgentProposal(classID: first.id, agentIdentity: "Fictional agent", idempotencyKey: "fictional-association",
                                    title: "Fictional proposal", body: "Fictional", citations: [proposalCitation], contextManifest: [proposalInput])
        try repository.update {
            $0.recordings.append(recording); $0.transcriptRevisions.append(original)
            $0.pinnedCitations.append(pinned)
            $0.activities.append(ActivityEntry(classID: first.id, title: "Old answer", citations: [cited],
                                               agentIdentity: "Fictional agent", inputContextManifest: [input]))
            $0.proposals.append(proposed)
        }
        // Current activity no longer cites this cue, but its immutable earlier revision does.
        try repository.update { $0.activities[0].citations = []; $0.activities[0].inputContextManifest = nil }
        let sourceBefore = repository.state.recordings[0]
        try repository.update { $0.recordings[0].classID = second.id }
        let moved = repository.state.recordings[0]
        XCTAssertEqual(moved.associationHistory?.count, 1)
        let transition = try XCTUnwrap(moved.associationHistory?.first)
        XCTAssertEqual(transition.fromClassID, first.id)
        XCTAssertEqual(transition.toClassID, second.id)
        XCTAssertEqual(transition.retainedCitations.count, 5)
        for saved in [pinned, cited, input, proposalInput, proposalCitation] {
            XCTAssertTrue(transition.retainedCitations.contains(saved))
            XCTAssertEqual(repository.state.recordingForCitation(saved)?.id, recording.id)
        }
        var sourceAfter = moved
        sourceAfter.classID = sourceBefore.classID; sourceAfter.associationHistory = sourceBefore.associationHistory
        XCTAssertEqual(sourceAfter, sourceBefore, "Association correction must not rewrite capture, source or processing facts")
        var uncited = pinned
        uncited.locator = .cues(start: 7, end: 7)
        XCTAssertNil(repository.state.recordingForCitation(uncited))
        var changedIdentity = pinned
        changedIdentity.id = UUID()
        XCTAssertNil(repository.state.recordingForCitation(changedIdentity))
        let repaired = try transcript(repository, recordingID: recording.id, job: "job-B")
        try repository.update {
            $0.transcriptRevisions.append(repaired)
            $0.recordings[0].acceptedJobID = repaired.acceptedJobID
            $0.recordings[0].currentTranscriptRevisionID = repaired.id
        }
        let futureInOldClass = citation(recording, revision: repaired, classID: first.id, cue: 0)
        XCTAssertNil(repository.state.recordingForCitation(futureInOldClass))
        XCTAssertThrowsError(try repository.update { $0.pinnedCitations.append(futureInOldClass) })
        let secondSaved = citation(recording, revision: repaired, classID: second.id, cue: 0)
        try repository.update { $0.pinnedCitations.append(secondSaved) }
        try repository.update { $0.recordings[0].classID = nil }
        XCTAssertNil(repository.state.recordings[0].classID)
        XCTAssertEqual(repository.state.recordings[0].associationHistory?.count, 2)
        XCTAssertEqual(repository.state.recordings[0].associationHistory?[1].retainedCitations, [secondSaved])
        XCTAssertEqual(repository.state.recordingForCitation(secondSaved)?.id, recording.id)
        // Retention survives removal of mutable explicit pins because the ledger owns its exact dependencies.
        try repository.update { $0.pinnedCitations = []; $0.pinnedPayloads = [] }
        let cleanup = try repository.purgeUnpinnedTranscriptCaches()
        XCTAssertEqual(cleanup.revisionsRemoved, 0)
        let reopened = try ContextRepository(rootURL: repository.rootURL)
        XCTAssertEqual(reopened.state.recordings, repository.state.recordings)
        let backup = root.appendingPathComponent("backup")
        try reopened.exportBackup(to: backup)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(offline.state.recordings[0].associationHistory, repository.state.recordings[0].associationHistory)
        for saved in [pinned, cited, input, proposalInput, proposalCitation, secondSaved] {
            XCTAssertEqual(offline.state.recordingForCitation(saved)?.id, recording.id)
        }
        XCTAssertEqual(try offline.payloadData(original.content), try repository.payloadData(original.content))
        XCTAssertEqual(try offline.payloadData(repaired.content), try repository.payloadData(repaired.content))
        XCTAssertNil(offline.state.recordingForCitation(futureInOldClass))
        XCTAssertNil(offline.state.recordingForCitation(uncited))
        XCTAssertNil(offline.state.recordings[0].localAudioPath, "Existing backup audio omission stays intact")
    }

    @MainActor func testUncitedCorrectionsDoNotRetainBroadTranscriptAccessOrUncitedCaches() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let (first, second) = try seed(repository)
        var recording = LectureRecording(classID: first.id, filename: "SYN_uncited.m4a", sizeBytes: 2, sha256: String(repeating: "b", count: 64), acceptedJobID: "uncited")
        let revision = try transcript(repository, recordingID: recording.id, job: "uncited")
        recording.currentTranscriptRevisionID = revision.id
        try repository.update { $0.recordings.append(recording); $0.transcriptRevisions.append(revision) }
        let neverSaved = citation(recording, revision: revision, classID: first.id, cue: 0)
        try repository.update { $0.recordings[0].classID = second.id }
        try repository.update { $0.recordings[0].classID = nil }
        XCTAssertEqual(repository.state.recordings[0].associationHistory?.count, 2)
        XCTAssertTrue(repository.state.recordings[0].associationHistory?.allSatisfy { $0.retainedCitations.isEmpty } == true)
        XCTAssertNil(repository.state.recordingForCitation(neverSaved))
        let cleanup = try repository.purgeUnpinnedTranscriptCaches()
        XCTAssertEqual(cleanup.revisionsRemoved, 1)
        XCTAssertTrue(repository.state.transcriptRevisions.isEmpty)
        XCTAssertEqual(repository.state.recordings[0].filename, recording.filename)
        XCTAssertEqual(repository.state.recordings[0].sha256, recording.sha256)
    }

    @MainActor func testHistoryCannotBeErasedRewrittenAppendedOrForgedByCaller() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let (first, second) = try seed(repository)
        let recording = LectureRecording(classID: first.id, filename: "SYN_history.m4a", sizeBytes: 2, sha256: String(repeating: "c", count: 64))
        try repository.update { $0.recordings.append(recording) }
        try repository.update { $0.recordings[0].classID = second.id }
        let before = repository.state
        XCTAssertThrowsError(try repository.update { $0.recordings[0].associationHistory = nil })
        XCTAssertThrowsError(try repository.update { $0.recordings[0].associationHistory = [] })
        XCTAssertThrowsError(try repository.update { $0.recordings[0].associationHistory?[0].changedAt = .distantPast })
        XCTAssertThrowsError(try repository.update { $0.recordings[0].associationHistory?[0].changedAt = Date(timeIntervalSinceReferenceDate: .infinity) })
        XCTAssertThrowsError(try repository.update {
            $0.recordings[0].associationHistory?.append(RecordingAssociationRevision(fromClassID: second.id, toClassID: first.id))
            $0.recordings[0].classID = first.id
        })
        let fake = LectureRecording(classID: second.id, filename: "SYN_forged.m4a", sizeBytes: 1, sha256: String(repeating: "d", count: 64),
            associationHistory: [RecordingAssociationRevision(fromClassID: first.id, toClassID: second.id)])
        XCTAssertThrowsError(try repository.update { $0.recordings.append(fake) })
        XCTAssertEqual(repository.state, before)
        try repository.update { $0.recordings[0].retired = true }
        XCTAssertEqual(repository.state.recordings[0].associationHistory, before.recordings[0].associationHistory)
    }

    @MainActor func testFirstAssignmentFromNilIsRecordedAndCurrentTransactionCannotInventHistoricalCitation() async throws {
        let repository = try ContextRepository(rootURL: temporaryRoot())
        let (first, second) = try seed(repository)
        let recording = LectureRecording(filename: "SYN_unassigned.m4a", sizeBytes: 2, sha256: String(repeating: "e", count: 64))
        let revision = try transcript(repository, recordingID: recording.id, job: "unassigned")
        try repository.update { $0.recordings.append(recording); $0.transcriptRevisions.append(revision) }
        try repository.update { $0.recordings[0].classID = first.id }
        let initial = try XCTUnwrap(repository.state.recordings[0].associationHistory?.first)
        XCTAssertNil(initial.fromClassID)
        XCTAssertEqual(initial.toClassID, first.id)
        XCTAssertTrue(initial.retainedCitations.isEmpty)
        let unsaved = citation(recording, revision: revision, classID: first.id, cue: 0)
        let before = repository.state
        XCTAssertThrowsError(try repository.update {
            $0.recordings[0].classID = second.id
            $0.pinnedCitations.append(unsaved)
        })
        XCTAssertEqual(repository.state, before)
    }

    @MainActor func testOldSchemaBackupRestoresNilHistoryExactlyWithoutInferredTransition() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("source"))
        let (first, _) = try seed(repository)
        let recording = LectureRecording(classID: first.id, filename: "SYN_legacy.m4a", sizeBytes: 2, sha256: String(repeating: "f", count: 64))
        try repository.update { $0.recordings.append(recording) }
        let backup = root.appendingPathComponent("old-backup")
        try repository.exportBackup(to: backup)
        try rewriteBackup(backup) { object in
            var recordings = object["recordings"] as! [[String: Any]]
            for index in recordings.indices { recordings[index].removeValue(forKey: "associationHistory") }
            object["recordings"] = recordings
        }
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("restored"))
        try offline.restoreBackup(from: backup)
        XCTAssertEqual(offline.state.recordings, [recording])
        XCTAssertNil(offline.state.recordings[0].associationHistory)
        try offline.update { $0.terms[0].name = "Unrelated class context edit" }
        XCTAssertNil(offline.state.recordings[0].associationHistory)
        let reopened = try ContextRepository(rootURL: offline.rootURL)
        XCTAssertEqual(reopened.state.recordings, [recording])
    }

    @MainActor func testMalformedRestoredAssociationChainsPreserveCurrentStore() async throws {
        let root = try temporaryRoot()
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let (first, second) = try seed(repository)
        let recording = LectureRecording(classID: first.id, filename: "SYN_chain.m4a", sizeBytes: 2, sha256: String(repeating: "a", count: 64))
        try repository.update { $0.recordings.append(recording) }
        try repository.update { $0.recordings[0].classID = second.id }
        try repository.update { $0.recordings[0].classID = nil }
        let before = repository.state
        let cases: [(inout ContextState) -> Void] = [
            { $0.recordings[0].classID = first.id },
            { $0.recordings[0].associationHistory?[1].fromClassID = first.id },
            { $0.recordings[0].associationHistory?[0].fromClassID = UUID() },
            { state in
                let duplicate = state.recordings[0].associationHistory![0].id
                state.recordings[0].associationHistory?[1].id = duplicate
            },
            { $0.recordings[0].associationHistory = [] },
            { $0.recordings[0].associationHistory?[0].retainedCitations = [SourceCitation(classID: first.id, sourceKind: "transcript", sourceID: UUID(), revisionID: UUID(), payloadSHA256: String(repeating: "a", count: 64))] },
        ]
        for (index, mutate) in cases.enumerated() {
            let backup = root.appendingPathComponent("malformed-\(index)")
            try repository.exportBackup(to: backup)
            try rewriteBackup(backup) { object in
                var state = try JSONDecoder().decode(ContextState.self, from: JSONSerialization.data(withJSONObject: object))
                mutate(&state)
                object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            }
            XCTAssertThrowsError(try repository.restoreBackup(from: backup), "Malformed chain case \(index)")
            XCTAssertEqual(repository.state, before)
        }
    }

    private func rewriteBackup(_ backup: URL, mutation: (inout [String: Any]) throws -> Void) throws {
        let stateURL = backup.appendingPathComponent("context.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        try mutation(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: stateURL)
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(ContextBackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.stateByteCount = UInt64(bytes.count)
        manifest.stateSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(manifest).write(to: manifestURL)
    }
}

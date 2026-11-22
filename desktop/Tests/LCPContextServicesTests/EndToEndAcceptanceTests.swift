import XCTest
import Foundation
import CryptoKit
import LCPContextCore
@testable import LCPContextServices

/// Cross-component acceptance tests use fictional course content and isolated roots.
/// They exercise public user workflows rather than the shape of internal storage.
@MainActor
final class EndToEndAcceptanceTests: XCTestCase {
    private let audioDigest = String(repeating: "b", count: 64)
    private let filename = "Fictional Algorithms_2026-10-29_1530.m4a"
    private let instant = Date(timeIntervalSince1970: 1_798_761_600)

    func testClassContextToReviewedAnswerAndOfflineHistoricalCitationRecovery() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = try ContextRepository(rootURL: temporary.appendingPathComponent("profile"))
        let classes = try academicFixture(repository)
        let selected = classes[0]
        let differentTerm = classes[3]
        XCTAssertEqual(selected.courseCode, differentTerm.courseCode)
        XCTAssertNotEqual(selected.id, differentTerm.id)
        XCTAssertNotEqual(selected.termID, differentTerm.termID)

        let imports = MaterialService(repository: repository)
        for (index, enrollment) in classes.enumerated() {
            let input = temporary.appendingPathComponent("class-\(index).md")
            let text = index == 0
                ? "# Fictional algorithms\nA red-black tree has logarithmic height. Rotate carefully.\n"
                : "# Fictional other class\nPrivate class-\(index) phrase.\n"
            try Data(text.utf8).write(to: input)
            _ = try imports.importMaterial(from: input, classID: enrollment.id, title: "Class \(index) reading")
        }
        let retrieval = RetrievalService(repository: repository)
        let page = try retrieval.search(ContextQuery(classIDs: [selected.id], text: "logarithmic"))
        let materialCitation = try XCTUnwrap(page.results.first?.citation)
        XCTAssertEqual(materialCitation.classID, selected.id)
        XCTAssertEqual(materialCitation.sourceKind, "material")
        XCTAssertEqual(try CitationLink.decode(CitationLink.url(for: materialCitation)), materialCitation)
        XCTAssertTrue(try retrieval.resolve(materialCitation).text.contains("logarithmic"))
        XCTAssertTrue(try retrieval.search(ContextQuery(classIDs: [differentTerm.id], text: "logarithmic")).results.isEmpty)
        _ = try retrieval.pin(materialCitation)

        let connection = AgentConnection(name: "Acceptance fixture agent", clientVersion: "fixture-1", mode: "stdio",
                                         capabilities: ["read_context", "propose_note", "propose_study_log"])
        let grant = AgentGrant(connectionID: connection.id, allowedClassIDs: [selected.id])
        let originalNote = ActivityEntry(classID: selected.id, title: "My study question", body: "Why does height stay logarithmic?",
                                         eventAt: instant.addingTimeInterval(-3_600), recordedAt: instant)
        let dateOnly = CourseworkItem(classID: selected.id, title: "Reading", kind: "reading",
                                      due: .dateOnly(LocalDate(year: 2026, month: 11, day: 23)))
        let timed = CourseworkItem(classID: selected.id, title: "Timed project", kind: "project",
                                   due: .timed(instant: instant, timeZoneID: "America/Los_Angeles"))
        try repository.update { state in
            state.connections.append(connection); state.grants.append(grant)
            state.activities.append(originalNote); state.coursework.append(contentsOf: [dateOnly, timed])
        }
        let proposals = ProposalService(repository: repository)
        let proposal = try proposals.propose(classID: selected.id, agentIdentity: "Untrusted display name",
            title: "Tree review", body: "Logarithmic height follows the balancing invariants.", idempotencyKey: "answer-1",
            citations: [materialCitation], grantID: grant.id)
        XCTAssertFalse(repository.state.activities.contains { $0.id == proposal.id })
        let accepted = try proposals.accept(proposal.id)
        XCTAssertEqual(accepted.agentIdentity, connection.name)
        XCTAssertEqual(accepted.kind, "agent_study_log")
        XCTAssertEqual(try proposals.accept(proposal.id).id, accepted.id)
        XCTAssertEqual(try proposals.propose(classID: selected.id, agentIdentity: connection.name, title: "Tree review",
            body: "Logarithmic height follows the balancing invariants.", idempotencyKey: "answer-1",
            citations: [materialCitation], grantID: grant.id).id, proposal.id)
        XCTAssertEqual(repository.state.activities.filter { $0.id == accepted.id }.count, 1)

        let rejected = try proposals.propose(classID: selected.id, agentIdentity: connection.name,
            title: "Discard this", body: "A draft only.", idempotencyKey: "answer-reject", grantID: grant.id)
        let countBeforeReject = repository.state.activities.count
        try proposals.reject(rejected.id)
        XCTAssertEqual(repository.state.activities.count, countBeforeReject)
        XCTAssertThrowsError(try proposals.accept(rejected.id))

        let stale = try proposals.propose(classID: selected.id, agentIdentity: connection.name, title: "Suggested correction",
            body: "Clarify the invariant.", kind: .note, targetID: originalNote.id,
            expectedVersion: originalNote.version, idempotencyKey: "answer-stale", grantID: grant.id)
        try repository.update { state in
            let index = state.activities.firstIndex { $0.id == originalNote.id }!
            state.activities[index].body = "My revised question, edited before accepting the draft."
            state.activities[index].version += 1
        }
        XCTAssertThrowsError(try proposals.accept(stale.id))
        let correctionHistory = repository.state.activityRevisions.filter { $0.activityID == originalNote.id }
        XCTAssertEqual(correctionHistory.count, 2)
        XCTAssertTrue(correctionHistory.contains { $0.body == originalNote.body })
        XCTAssertTrue(correctionHistory.contains { $0.body.contains("revised question") })
        XCTAssertThrowsError(try retrieval.search(ContextQuery(classIDs: [differentTerm.id], text: "Private"), grantID: grant.id))

        let oldMaterialText = try retrieval.resolve(materialCitation).text
        let revisedInput = temporary.appendingPathComponent("revised-reading.md")
        try Data("Revised fictional reading: a potential function bounds amortized cost.".utf8).write(to: revisedInput)
        let materialB = try imports.reviseMaterial(materialID: materialCitation.sourceID, from: revisedInput)
        XCTAssertNotEqual(materialB.id, materialCitation.revisionID)
        XCTAssertEqual(try retrieval.resolve(materialCitation).text, oldMaterialText)

        let feed = temporary.appendingPathComponent("feed")
        let importer = FeedImporter(repository: repository, now: { self.instant.addingTimeInterval(10_000) })
        try writeGeneration(at: feed, generation: "fixture-A", exportedAt: instant, cueText: "Original lecture: rotations preserve ordering.")
        _ = try importer.importGeneration(from: feed)
        let recording = try XCTUnwrap(repository.state.recordings.first)
        XCTAssertNil(recording.classID, "A filename does not prove academic enrollment identity.")
        try repository.update { state in
            state.recordings[state.recordings.firstIndex { $0.id == recording.id }!].classID = selected.id
        }
        let revisionA = try XCTUnwrap(repository.state.transcriptRevisions.first)
        let lectureCitation = SourceCitation(classID: selected.id, sourceKind: "transcript", sourceID: recording.id,
            revisionID: revisionA.id, payloadSHA256: revisionA.content.sha256, locator: .cues(start: 0, end: 0), label: "Original lecture cue")
        XCTAssertEqual(try CitationLink.decode(CitationLink.url(for: lectureCitation)), lectureCitation)
        let originalPassage = try retrieval.resolve(lectureCitation)
        XCTAssertTrue(originalPassage.text.contains("Original lecture"))
        _ = try retrieval.pin(lectureCitation)
        let lectureAnswer = try proposals.propose(classID: selected.id, agentIdentity: connection.name,
            title: "Lecture review", body: "Rotations preserve ordering.", idempotencyKey: "lecture-answer",
            citations: [lectureCitation], grantID: grant.id)
        _ = try proposals.accept(lectureAnswer.id)

        try writeGeneration(at: feed, generation: "fixture-B", exportedAt: instant.addingTimeInterval(60),
                            cueText: "Repaired lecture: rotations also preserve the sorted traversal.")
        _ = try importer.importGeneration(from: feed)
        XCTAssertEqual(repository.state.transcriptRevisions.count, 2)
        let revisionB = try XCTUnwrap(repository.state.transcriptRevisions.first { $0.id != revisionA.id })
        XCTAssertEqual(revisionA.acceptedJobID, revisionB.acceptedJobID)
        XCTAssertNotEqual(revisionA.content.sha256, revisionB.content.sha256)
        XCTAssertEqual(try retrieval.resolve(lectureCitation).text, originalPassage.text)
        XCTAssertEqual(repository.state.recordings.first?.classID, selected.id)

        try writeGeneration(at: feed, generation: "fixture-retired", exportedAt: instant.addingTimeInterval(120), cueText: nil)
        _ = try importer.importGeneration(from: feed)
        XCTAssertTrue(try XCTUnwrap(repository.state.recordings.first).retired)
        XCTAssertEqual(try retrieval.resolve(lectureCitation).text, originalPassage.text)
        try repository.update { state in
            state.grants[state.grants.firstIndex { $0.id == grant.id }!].revokedAt = instant.addingTimeInterval(180)
        }
        XCTAssertThrowsError(try retrieval.search(ContextQuery(classIDs: [selected.id], text: "height"), grantID: grant.id))
        XCTAssertThrowsError(try proposals.propose(classID: selected.id, agentIdentity: connection.name,
            title: "Revoked", body: "Must not become a proposal.", idempotencyKey: "revoked", grantID: grant.id))

        let cleanup = try repository.purgeUnpinnedTranscriptCaches()
        XCTAssertEqual(cleanup.revisionsRemoved, 1)
        XCTAssertTrue(repository.state.transcriptRevisions.contains { $0.id == revisionA.id })
        XCTAssertFalse(repository.state.transcriptRevisions.contains { $0.id == revisionB.id })
        XCTAssertThrowsError(try repository.payloadData(revisionB.content))
        XCTAssertEqual(try retrieval.resolve(lectureCitation).text, originalPassage.text)

        let backup = temporary.appendingPathComponent("portable-backup")
        try repository.exportBackup(to: backup)
        let expectedMaterialText = try retrieval.resolve(materialCitation).text
        // The restore must be self-contained even after the fixture server feed
        // and the source profile's entire payload cache become unavailable.
        try FileManager.default.removeItem(at: feed)
        try FileManager.default.removeItem(at: repository.rootURL.appendingPathComponent("payloads"))
        let restored = try ContextRepository(rootURL: temporary.appendingPathComponent("restored-offline"))
        try restored.restoreBackup(from: backup)
        let restoredRetrieval = RetrievalService(repository: restored)
        XCTAssertEqual(try restoredRetrieval.resolve(lectureCitation).text, originalPassage.text)
        XCTAssertEqual(try restoredRetrieval.resolve(materialCitation).text, expectedMaterialText)
        XCTAssertEqual(restored.state.classes.map(\.id), repository.state.classes.map(\.id))
        XCTAssertEqual(restored.state.coursework.first { $0.id == dateOnly.id }?.due, dateOnly.due)
        XCTAssertEqual(restored.state.coursework.first { $0.id == timed.id }?.due, timed.due)
        XCTAssertEqual(restored.state.activities.first { $0.id == accepted.id }?.agentIdentity, connection.name)
        XCTAssertEqual(restored.state.activities.first { $0.id == originalNote.id }?.eventAt, originalNote.eventAt)
        XCTAssertTrue(restored.state.pinnedCitations.contains { $0.revisionID == revisionA.id })
        XCTAssertTrue(restored.state.grants.isEmpty, "Portable restore must not resurrect access grants.")
        let relaunched = try ContextRepository(rootURL: restored.rootURL)
        XCTAssertEqual(relaunched.state.classes.count, 4)
        XCTAssertEqual(try RetrievalService(repository: relaunched).resolve(lectureCitation).text, originalPassage.text)
    }

    func testDamagedAndFutureBackupsPreserveCurrentLibrary() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = try ContextRepository(rootURL: temporary.appendingPathComponent("profile"))
        let selected = try academicFixture(repository)[0]
        let source = temporary.appendingPathComponent("source.txt")
        try Data("Fictional source for a persistent pinned citation.".utf8).write(to: source)
        _ = try MaterialService(repository: repository).importMaterial(from: source, classID: selected.id)
        let retrieval = RetrievalService(repository: repository)
        let citation = try XCTUnwrap(try retrieval.search(ContextQuery(classIDs: [selected.id], text: "persistent")).results.first?.citation)
        _ = try retrieval.pin(citation)
        let before = repository.state
        let missing = temporary.appendingPathComponent("missing-pinned-payload-backup")
        try repository.exportBackup(to: missing)
        let payload = missing.appendingPathComponent("payloads/\(citation.payloadSHA256).blob")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        try FileManager.default.removeItem(at: payload)
        XCTAssertThrowsError(try repository.restoreBackup(from: missing))
        XCTAssertEqual(repository.state, before)
        XCTAssertTrue(try retrieval.resolve(citation).text.contains("persistent"))

        let future = temporary.appendingPathComponent("future-backup")
        try repository.exportBackup(to: future)
        let manifestURL = future.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["version"] = 999
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try repository.restoreBackup(from: future))
        XCTAssertEqual(repository.state, before)

        let malformed = temporary.appendingPathComponent("malformed-backup")
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{ invalid".utf8).write(to: malformed.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try repository.restoreBackup(from: malformed))
        XCTAssertEqual(repository.state, before)
        XCTAssertEqual(try ContextRepository(rootURL: repository.rootURL).state, before)
    }

    func testThousandLectureScopedSearchMeasurement() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = try ContextRepository(rootURL: temporary.appendingPathComponent("profile"))
        let selected = try academicFixture(repository)[0]
        var recordings: [LectureRecording] = []
        var revisions: [TranscriptRevision] = []
        for index in 0..<1_000 {
            let name = "Fictional Algorithms_2026-11-19_\(index).m4a"
            let cues = [TranscriptCue(start: 0, end: 10, text: "Fictional lecture \(index) explains amortized analysis and potential functions.", speaker: "speaker_0")]
            let bytes = try transcriptPayload(filename: name, cueText: cues[0].text)
            let content = try repository.storePayload(bytes, mediaType: "application/vnd.lcp.transcript+json")
            var recording = LectureRecording(classID: selected.id, filename: name, sizeBytes: 1_024, sha256: audioDigest,
                acceptedJobID: "opaque-fixture-job", status: LectureStatusFacts(transcriptAvailable: "available"))
            let revision = TranscriptRevision(recordingID: recording.id, acceptedJobID: "opaque-fixture-job", content: content,
                                              cues: cues, createdAt: instant, duration: 10)
            recording.currentTranscriptRevisionID = revision.id
            recordings.append(recording)
            revisions.append(revision)
        }
        try repository.update { state in state.recordings.append(contentsOf: recordings); state.transcriptRevisions.append(contentsOf: revisions) }
        let retrieval = RetrievalService(repository: repository)
        let start = Date()
        let result = try retrieval.search(ContextQuery(classIDs: [selected.id], text: "amortized", limit: 20))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.results.count, 20)
        XCTAssertEqual(result.total, 1_000)
        print("LCP_ACCEPTANCE_SEARCH_1000_SECONDS=\(String(format: "%.6f", elapsed))")
        XCTAssertTrue(result.results.allSatisfy { $0.citation.classID == selected.id })
    }

    private func academicFixture(_ repository: ContextRepository) throws -> [ClassEnrollment] {
        let fall = AcademicTerm(name: "Fictional Fall 2026", startDate: LocalDate(year: 2026, month: 9, day: 24),
                                endDate: LocalDate(year: 2026, month: 12, day: 11))
        let winter = AcademicTerm(name: "Fictional Winter 2027", startDate: LocalDate(year: 2027, month: 1, day: 4), archived: true)
        let classes = [
            ClassEnrollment(termID: fall.id, courseCode: "ICS 46", title: "Fictional Algorithms"),
            ClassEnrollment(termID: fall.id, courseCode: "PHIL 4", title: "Fictional Ethics"),
            ClassEnrollment(termID: fall.id, courseCode: "COMLIT 9", title: "Fictional Literature"),
            ClassEnrollment(termID: winter.id, courseCode: "ICS 46", title: "Fictional Repeated Algorithms", archived: true),
        ]
        try repository.update { state in state.terms.append(contentsOf: [fall, winter]); state.classes.append(contentsOf: classes) }
        return classes
    }

    private func writeGeneration(at root: URL, generation: String, exportedAt: Date, cueText: String?) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payloads"), withIntermediateDirectories: true)
        var recordings: [[String: Any]] = []
        var retirements: [[String: Any]] = []
        if let cueText {
            let bytes = try transcriptPayload(filename: filename, cueText: cueText)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try bytes.write(to: root.appendingPathComponent("payloads/\(digest).json"))
            recordings = [["filename": filename, "size_bytes": 1_024, "sha256": audioDigest,
                "accepted_job_id": "opaque-fixture-job", "status": ["server_received": true, "processing": "complete",
                    "quality": "accepted", "drive_publication": "unknown", "external_ingestion": "unknown"],
                "transcript": ["path": "payloads/\(digest).json", "sha256": digest, "size_bytes": bytes.count,
                               "accepted_job_id": "opaque-fixture-job"]]]
        } else {
            retirements = [["filename": filename, "size_bytes": 1_024, "sha256": audioDigest, "reason": "synthetic retirement"]]
        }
        let index: [String: Any] = ["schema_version": 1, "generation_id": generation,
            "exported_at": ISO8601DateFormatter().string(from: exportedAt),
            "producer": ["id": "fictional-exporter", "environment": "acceptance-fixture"], "complete": true,
            "recordings": recordings, "retirements": retirements]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    private func transcriptPayload(filename: String, cueText: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "filename": filename, "size_bytes": 1_024,
            "sha256": audioDigest, "accepted_job_id": "opaque-fixture-job",
            "cues": [["start": 0, "end": 10, "text": cueText, "speaker": "speaker_0"]],
            "audio_events": [], "generated_at": "2026-11-19T18:00:00Z"], options: [.sortedKeys])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-integrated-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

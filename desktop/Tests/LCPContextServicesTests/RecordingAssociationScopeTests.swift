import XCTest
import Foundation
import CryptoKit
import LCPContextCore
@testable import LCPContextServices

/// Authored class corrections retain saved source truth without turning an old
/// class grant into access to future revisions or previously uncited passages.
@MainActor
final class RecordingAssociationScopeTests: XCTestCase {
    func testOldExactCitationSurvivesCorrectionWithoutExpandingClassGrant() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.saveOldCitation()
        try fixture.associate(fixture.classB.id)
        let retained = try XCTUnwrap(fixture.repository.state.recordings.first?.associationHistory?.last?.retainedCitations)
        XCTAssertEqual(retained, [old])
        XCTAssertEqual(try fixture.retrieval.resolve(old, grantID: fixture.grantA.id).text,
                       "[00:00–00:02] speaker_0: Retained original explanation.")
        XCTAssertThrowsError(try fixture.retrieval.resolve(old, grantID: fixture.grantB.id))

        var alteredCue = old; alteredCue.locator = .cues(start: 1, end: 1)
        XCTAssertThrowsError(try fixture.retrieval.resolve(alteredCue, grantID: fixture.grantA.id))
        var alteredID = old; alteredID.id = UUID()
        XCTAssertThrowsError(try fixture.retrieval.resolve(alteredID, grantID: fixture.grantA.id))
        var alteredLabel = old; alteredLabel.label = "A different label"
        XCTAssertThrowsError(try fixture.retrieval.resolve(alteredLabel, grantID: fixture.grantA.id))
        var wholeRevision = old; wholeRevision.locator = .whole
        XCTAssertThrowsError(try fixture.retrieval.resolve(wholeRevision, grantID: fixture.grantA.id))

        XCTAssertTrue(try fixture.retrieval.search(ContextQuery(classIDs: [fixture.classA.id], text: "Retained original"), grantID: fixture.grantA.id).results.isEmpty)
        let currentB = try fixture.retrieval.search(ContextQuery(classIDs: [fixture.classB.id], text: "Retained original"), grantID: fixture.grantB.id)
        XCTAssertEqual(currentB.results.first?.citation.classID, fixture.classB.id)
        XCTAssertEqual(try fixture.retrieval.listClasses(grantID: fixture.grantA.id).map(\.id), [fixture.classA.id])

        try fixture.writeFeed(generation: "g2", at: "2026-11-19T11:00:00Z", text: "FUTURE_B_REVISION explanation.")
        _ = try fixture.importer.importGeneration(from: fixture.feed)
        let repaired = try XCTUnwrap(fixture.repository.state.transcriptRevisions.first(where: {
            $0.id == fixture.repository.state.recordings.first?.currentTranscriptRevisionID
        }))
        var forgedRevision = old; forgedRevision.revisionID = repaired.id; forgedRevision.payloadSHA256 = repaired.content.sha256
        XCTAssertThrowsError(try fixture.retrieval.resolve(forgedRevision, grantID: fixture.grantA.id))
        XCTAssertTrue(try fixture.retrieval.resolve(old, grantID: fixture.grantA.id).text.contains("Retained original"))
        XCTAssertTrue(try fixture.retrieval.search(ContextQuery(classIDs: [fixture.classA.id], text: "FUTURE_B_REVISION"), grantID: fixture.grantA.id).results.isEmpty)
        XCTAssertEqual(try fixture.retrieval.search(ContextQuery(classIDs: [fixture.classB.id], text: "FUTURE_B_REVISION"), grantID: fixture.grantB.id).results.count, 1)
    }

    func testHistoricalBundleExportsExactPassageAndHonorsMaterialTimeAndProposalScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.saveOldCitation()
        try fixture.associate(fixture.classB.id)
        try fixture.writeFeed(generation: "g2", at: "2026-11-19T11:00:00Z", text: "FUTURE_B_REVISION explanation.")
        _ = try fixture.importer.importGeneration(from: fixture.feed)
        let destination = fixture.root.appendingPathComponent("class-a-bundle")
        let bundle = try fixture.retrieval.buildContextBundle(classIDs: [fixture.classA.id], to: destination, grantID: fixture.grantA.id)
        let historical = try XCTUnwrap(bundle.sources.first(where: { $0.citation == old }))
        XCTAssertEqual(historical.passages.count, 1)
        XCTAssertTrue(historical.passages[0].text.contains("Retained original"))
        XCTAssertTrue(historical.payloads.isEmpty)
        XCTAssertTrue(bundle.omissions.contains(where: { $0.contains("historical class scope") }))
        let manifestText = try String(contentsOf: destination.appendingPathComponent("manifest.json"), encoding: .utf8)
        let markdown = try String(contentsOf: destination.appendingPathComponent("context.md"), encoding: .utf8)
        XCTAssertFalse((manifestText + markdown).contains("SECRET_UNRETAINED_CUE"))
        XCTAssertFalse((manifestText + markdown).contains("FUTURE_B_REVISION"))
        XCTAssertFalse((manifestText + markdown).contains(fixture.classB.title))
        let blobs = try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("payloads"), includingPropertiesForKeys: nil)
        for blob in blobs {
            let text = String(data: try Data(contentsOf: blob), encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("SECRET_UNRETAINED_CUE"))
            XCTAssertFalse(text.contains("FUTURE_B_REVISION"))
        }

        let materialOnly = AgentGrant(connectionID: fixture.connection.id, allowedClassIDs: [fixture.classA.id], allowedMaterialIDs: [])
        let timeBound = AgentGrant(connectionID: fixture.connection.id, allowedClassIDs: [fixture.classA.id],
                                   eventFrom: Date(timeIntervalSince1970: 2_000_000_000))
        try fixture.repository.update { state in state.grants.append(contentsOf: [materialOnly, timeBound]) }
        XCTAssertThrowsError(try fixture.retrieval.resolve(old, grantID: materialOnly.id))
        XCTAssertThrowsError(try fixture.retrieval.resolve(old, grantID: timeBound.id))
        let restricted = try fixture.retrieval.buildContextBundle(classIDs: [fixture.classA.id],
            to: fixture.root.appendingPathComponent("restricted-bundle"), grantID: materialOnly.id)
        XCTAssertTrue(restricted.sources.isEmpty)
        let future = try fixture.retrieval.buildContextBundle(classIDs: [fixture.classA.id],
            to: fixture.root.appendingPathComponent("future-bundle"), grantID: fixture.grantA.id,
            eventFrom: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertFalse(future.sources.contains(where: { $0.citation.sourceKind == "transcript" }))

        let proposalService = ProposalService(repository: fixture.repository)
        let proposal = try proposalService.propose(classID: fixture.classA.id, agentIdentity: "ignored transport identity",
            title: "Retained study outcome", body: "Reviewed the exact original passage.", idempotencyKey: "historical",
            citations: [old], grantID: fixture.grantA.id)
        let accepted = try proposalService.accept(proposal.id)
        XCTAssertEqual(accepted.citations, [old])
        XCTAssertThrowsError(try proposalService.propose(classID: fixture.classB.id, agentIdentity: "Agent", title: "Wrong class",
            body: "Cannot import an old A citation into B.", idempotencyKey: "wrong-class", citations: [old], grantID: fixture.grantB.id))
        XCTAssertThrowsError(try proposalService.propose(classID: fixture.classA.id, agentIdentity: "Agent", title: "Outside window",
            body: "Cannot read old evidence outside a time grant.", idempotencyKey: "window", citations: [old], grantID: timeBound.id))
    }

    func testTightBundleBudgetTruthfullyOmitsHistoricalExcerptInsteadOfEmptySource() throws {
        let fixture = try Fixture(retainedText: "Retained original explanation. " + String(repeating: "selected evidence ", count: 1_024))
        defer { fixture.remove() }
        let old = try fixture.saveOldCitation()
        try fixture.associate(fixture.classB.id)
        let destination = fixture.root.appendingPathComponent("bounded-bundle")
        let limit = 16_384
        let manifest = try fixture.retrieval.buildContextBundle(classIDs: [fixture.classA.id], to: destination,
                                                               grantID: fixture.grantA.id, maxBytes: limit)
        XCTAssertFalse(manifest.sources.contains(where: { $0.citation == old }))
        XCTAssertTrue(manifest.omissions.contains(where: { $0.contains("Historical citation") && $0.contains("exact passage omitted") }))
        XCTAssertFalse(manifest.omissions.contains(where: { $0.contains("exact saved passage included") }))
        let files = try FileManager.default.subpathsOfDirectory(atPath: destination.path)
        let bytes = try files.reduce(0) { total, name in
            let path = destination.appendingPathComponent(name)
            let info = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return total + (info.isRegularFile == true ? (info.fileSize ?? 0) : 0)
        }
        XCTAssertLessThanOrEqual(bytes, limit)
    }

    func testRepairsReplayAndExplicitUnassignmentPreserveLedgerAndOfflineRestore() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.saveOldCitation()
        try fixture.associate(fixture.classB.id)
        let correctedHistory = fixture.repository.state.recordings[0].associationHistory
        try fixture.writeFeed(generation: "g2", at: "2026-11-19T11:00:00Z", text: "FUTURE_B_REVISION explanation.")
        _ = try fixture.importer.importGeneration(from: fixture.feed)
        XCTAssertEqual(fixture.repository.state.recordings[0].classID, fixture.classB.id)
        XCTAssertEqual(fixture.repository.state.recordings[0].associationHistory, correctedHistory)
        try fixture.associate(nil)
        let unassignedHistory = fixture.repository.state.recordings[0].associationHistory
        XCTAssertNil(unassignedHistory?.last?.toClassID)
        XCTAssertFalse(unassignedHistory?.isEmpty ?? true)
        try fixture.writeFeed(generation: "g3", at: "2026-11-19T12:00:00Z", text: "Unassigned repaired source.")
        _ = try fixture.importer.importGeneration(from: fixture.feed)
        XCTAssertNil(fixture.repository.state.recordings[0].classID)
        XCTAssertEqual(fixture.repository.state.recordings[0].associationHistory, unassignedHistory)
        let before = fixture.repository.state
        XCTAssertTrue(try fixture.importer.importGeneration(from: fixture.feed).isDuplicate)
        XCTAssertEqual(fixture.repository.state, before)
        XCTAssertTrue(try fixture.retrieval.resolve(old, grantID: fixture.grantA.id).text.contains("Retained original"))
        XCTAssertTrue(try fixture.retrieval.search(ContextQuery(classIDs: [fixture.classA.id, fixture.classB.id], text: "Unassigned repaired")).results.isEmpty)

        _ = try fixture.repository.purgeUnpinnedTranscriptCaches()
        let backup = fixture.root.appendingPathComponent("backup")
        try fixture.repository.exportBackup(to: backup)
        let restored = try ContextRepository(rootURL: fixture.root.appendingPathComponent("restored"))
        try restored.restoreBackup(from: backup)
        XCTAssertNil(restored.state.recordings[0].classID)
        XCTAssertEqual(restored.state.recordings[0].associationHistory, unassignedHistory)
        XCTAssertTrue(try RetrievalService(repository: restored).resolve(old).text.contains("Retained original"))
        XCTAssertTrue(restored.state.grants.isEmpty)
    }

    func testReviewedCueReplacementPreservesOtherLinksAgentInputsAndOfflineHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.saveOldCitation()
        let other = try XCTUnwrap(fixture.retrieval.search(ContextQuery(classIDs: [fixture.classA.id], text: "SECRET_UNRETAINED_CUE")).results.first?.citation)
        let entry = ActivityEntry(classID: fixture.classA.id, kind: "agent_artifact", title: "Reviewed answer",
            body: "Saved with two citations.", citations: [old, other], agentIdentity: "Fixture agent", inputContextManifest: [old])
        try fixture.repository.update { $0.activities.append(entry) }
        try fixture.repair(generation: "g2", hour: 11)
        let review = try fixture.retrieval.reviewTranscriptCitation(in: entry, at: 0)
        XCTAssertTrue(review.original.text.contains("Retained original explanation."))
        XCTAssertThrowsError(try review.choose(cueIndex: -1))
        XCTAssertThrowsError(try review.choose(cueIndex: review.current.cues.count))
        let selected = try review.choose(cueIndex: 1)
        XCTAssertEqual(selected.citation.locator, .cues(start: 1, end: 1))
        let targetText = try fixture.retrieval.resolve(selected.citation).text
        XCTAssertTrue(targetText.contains("[00:03–00:05]"))
        try fixture.save(selected, to: entry.id)
        let backup = fixture.root.appendingPathComponent("replacement-backup")
        try fixture.repository.exportBackup(to: backup)
        let restored = try ContextRepository(rootURL: fixture.root.appendingPathComponent("offline"))
        try restored.restoreBackup(from: backup)
        let current = try XCTUnwrap(restored.state.activities.first { $0.id == entry.id })
        let historical = try XCTUnwrap(restored.state.activityRevisions.first { $0.id == entry.revisionID })
        XCTAssertEqual(current.citations, [selected.citation, other])
        XCTAssertEqual(historical.citations, [old, other])
        XCTAssertEqual(current.inputContextManifest, [old])
        XCTAssertEqual(historical.inputContextManifest, [old])
        XCTAssertEqual(current.agentIdentity, entry.agentIdentity)
        XCTAssertEqual(try RetrievalService(repository: restored).resolve(old).text, review.original.text)
        XCTAssertEqual(try RetrievalService(repository: restored).resolve(selected.citation).text, targetText)
        XCTAssertThrowsError(try fixture.save(selected, to: entry.id))
    }

    func testCueReplacementRejectsNewHeadClassMoveAndChangedEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.saveOldCitation()
        let entry = try XCTUnwrap(fixture.repository.state.activities.last)
        try fixture.repair(generation: "g2", hour: 11)
        let first = try fixture.retrieval.reviewTranscriptCitation(in: entry, at: 0).choose(cueIndex: 1)
        try fixture.repair(generation: "g3", hour: 12)
        XCTAssertThrowsError(try fixture.save(first, to: entry.id))
        let next = try fixture.retrieval.reviewTranscriptCitation(in: entry, at: 0).choose(cueIndex: 0)
        try fixture.associate(fixture.classB.id)
        XCTAssertThrowsError(try fixture.retrieval.reviewTranscriptCitation(in: entry, at: 0))
        try fixture.associate(fixture.classA.id)
        XCTAssertThrowsError(try fixture.save(next, to: entry.id))
        let reviewedAgain = try fixture.retrieval.reviewTranscriptCitation(in: entry, at: 0).choose(cueIndex: 1)
        try fixture.repository.update { state in
            state.activities[0].body += " Updated."
            state.activities[0].version += 1
            state.activities[0].revisionID = UUID()
            state.activities[0].content = nil
        }
        let expected = fixture.repository.state
        XCTAssertThrowsError(try fixture.save(reviewedAgain, to: entry.id))
        XCTAssertEqual(fixture.repository.state, expected)
        XCTAssertEqual(fixture.repository.state.activities[0].citations, [old])
    }

    func testCueReplacementRejectsAlreadyCitedCurrentPassageWithDifferentLabelAndID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.saveOldCitation()
        try fixture.repair(generation: "g2", hour: 11)
        var other = try XCTUnwrap(fixture.retrieval.search(ContextQuery(classIDs: [fixture.classA.id], text: "Repaired g2")).results.first?.citation)
        other.id = UUID()
        other.label = "Already attached"
        let entry = ActivityEntry(classID: fixture.classA.id, title: "Two versions", citations: [old, other])
        try fixture.repository.update { $0.activities.append(entry) }
        let selected = try fixture.retrieval.reviewTranscriptCitation(in: entry, at: 0).choose(cueIndex: 0)
        let expected = fixture.repository.state
        XCTAssertThrowsError(try fixture.save(selected, to: entry.id))
        XCTAssertEqual(fixture.repository.state, expected)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let feed: URL
        let repository: ContextRepository
        let classA: ClassEnrollment
        let classB: ClassEnrollment
        let connection: AgentConnection
        let grantA: AgentGrant
        let grantB: AgentGrant
        var importer: FeedImporter { FeedImporter(repository: repository) }
        var retrieval: RetrievalService { RetrievalService(repository: repository) }
        private static let filename = "Fictional Lecture_2026-11-19_0900.m4a"
        private static let digest = String(repeating: "a", count: 64)

        init(retainedText: String = "Retained original explanation.") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LCPAssociationScope-" + UUID().uuidString)
            feed = root.appendingPathComponent("feed")
            try FileManager.default.createDirectory(at: feed.appendingPathComponent("payloads"), withIntermediateDirectories: true)
            repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
            let term = AcademicTerm(name: "Fictional term")
            classA = ClassEnrollment(termID: term.id, courseCode: "A 101", title: "Original fictional class")
            classB = ClassEnrollment(termID: term.id, courseCode: "B 202", title: "CURRENT_B_CLASS_METADATA")
            connection = AgentConnection(name: "Scoped fictional agent", mode: "stdio", capabilities: ["read_context", "propose_study_log"])
            grantA = AgentGrant(connectionID: connection.id, allowedClassIDs: [classA.id])
            grantB = AgentGrant(connectionID: connection.id, allowedClassIDs: [classB.id])
            let a = classA, b = classB, c = connection, ga = grantA, gb = grantB
            try repository.update { state in state.terms.append(term); state.classes += [a,b]; state.connections.append(c); state.grants += [ga,gb] }
            try writeFeed(generation: "g1", at: "2026-11-19T10:00:00Z", text: retainedText)
            _ = try importer.importGeneration(from: feed)
            try repository.update { state in
                state.recordings[0].classID = a.id
                state.recordings[0].capturedAt = Date(timeIntervalSince1970: 1_763_549_200)
            }
        }
        func associate(_ classID: UUID?) throws { try repository.update { $0.recordings[0].classID = classID } }
        func repair(generation: String, hour: Int) throws {
            try writeFeed(generation: generation, at: "2026-11-19T\(hour):00:00Z", text: "Repaired \(generation)")
            _ = try importer.importGeneration(from: feed)
        }
        func save(_ replacement: TranscriptCitationReplacement, to entryID: UUID) throws {
            try repository.update { state in
                let index = try XCTUnwrap(state.activities.firstIndex { $0.id == entryID })
                var entry = state.activities[index]
                entry.version += 1
                entry.revisionID = UUID()
                entry.content = nil
                try replacement.apply(to: &entry, in: state)
                state.activities[index] = entry
            }
        }
        func saveOldCitation() throws -> SourceCitation {
            let citation = try XCTUnwrap(retrieval.search(ContextQuery(classIDs: [classA.id], text: "Retained original"), grantID: grantA.id).results.first?.citation)
            try repository.update { $0.activities.append(ActivityEntry(classID: classA.id, title: "Saved source", body: "Pinned outcome", citations: [citation])) }
            return citation
        }
        func writeFeed(generation: String, at: String, text: String) throws {
            let payload: [String: Any] = ["schema_version": 1, "filename": Self.filename, "size_bytes": 123, "sha256": Self.digest,
                "accepted_job_id": "opaque-associated-job", "generated_at": at, "audio_events": [],
                "cues": [["start": 0.0, "end": 2.0, "text": text, "speaker": "speaker_0"],
                         ["start": 3.0, "end": 5.0, "text": "SECRET_UNRETAINED_CUE", "speaker": "speaker_1"]]]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: feed.appendingPathComponent("payloads/\(digest).json"))
            let index: [String: Any] = ["schema_version": 1, "generation_id": generation, "exported_at": at,
                "producer": ["id": "association-fixture", "environment": "synthetic"], "complete": true, "retirements": [],
                "recordings": [["filename": Self.filename, "size_bytes": 123, "sha256": Self.digest, "accepted_job_id": "opaque-associated-job",
                                "status": ["server_received": true, "processing": "complete", "quality": "eligible", "drive_publication": "pending", "external_ingestion": "unknown"],
                                "transcript": ["path": "payloads/\(digest).json", "sha256": digest, "size_bytes": data.count, "accepted_job_id": "opaque-associated-job"]]]]
            try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: feed.appendingPathComponent("index.json"), options: .atomic)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

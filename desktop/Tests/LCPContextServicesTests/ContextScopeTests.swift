import Foundation
import XCTest
import LCPContextCore
@testable import LCPContextServices

@MainActor
final class ContextScopeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repository: ContextRepository
        let classID: UUID
        let connectionID: UUID
        let grantID: UUID
        let inside: SourceMaterial
        let outside: SourceMaterial
    }
    private func fixture(materialOnly: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LCP-scope-tests-\(UUID())")
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let term = AcademicTerm(name: "Fictional autumn")
        let enrollment = ClassEnrollment(termID: term.id, courseCode: "TEST", title: "Scope evidence")
        let connection = AgentConnection(name: "Fictional agent", mode: "stdio", capabilities: ["read_context", "propose_note", "propose_study_log"])
        try repository.update { $0.terms.append(term); $0.classes.append(enrollment); $0.connections.append(connection) }
        let materialService = MaterialService(repository: repository)
        let a = root.appendingPathComponent("inside.txt"), b = root.appendingPathComponent("outside.txt")
        try Data("inside material evidence".utf8).write(to: a)
        try Data("outside material evidence".utf8).write(to: b)
        var inside = try materialService.importMaterial(from: a, classID: enrollment.id)
        var outside = try materialService.importMaterial(from: b, classID: enrollment.id)
        inside.createdAt = Date(timeIntervalSince1970: 300)
        outside.createdAt = Date(timeIntervalSince1970: 100)
        let grant = AgentGrant(connectionID: connection.id, allowedClassIDs: [enrollment.id],
            allowedMaterialIDs: materialOnly ? [inside.id] : nil,
            eventFrom: Date(timeIntervalSince1970: 200), eventUntil: Date(timeIntervalSince1970: 400))
        let finalInside = inside, finalOutside = outside
        try repository.update { state in
            state.materials = [finalInside, finalOutside]
            state.grants.append(grant)
            state.activities.append(ActivityEntry(classID: enrollment.id, title: "inside note", body: "inside activity evidence", eventAt: Date(timeIntervalSince1970: 300)))
            state.activities.append(ActivityEntry(classID: enrollment.id, title: "outside note", body: "outside activity evidence", eventAt: Date(timeIntervalSince1970: 100)))
        }
        for (name, capture) in [("inside lecture", Date(timeIntervalSince1970: 300)), ("outside lecture", Date(timeIntervalSince1970: 100)), ("unknown lecture", nil)] {
            try addTranscript(repository, classID: enrollment.id, name: name, capturedAt: capture)
        }
        return Fixture(root: root, repository: repository, classID: enrollment.id, connectionID: connection.id,
            grantID: grant.id, inside: finalInside, outside: finalOutside)
    }
    private func addTranscript(_ repository: ContextRepository, classID: UUID, name: String, capturedAt: Date?) throws {
        var recording = LectureRecording(classID: classID, filename: name + ".m4a", sizeBytes: 123,
            sha256: String(repeating: "a", count: 64), capturedAt: capturedAt, acceptedJobID: name,
            status: LectureStatusFacts(transcriptAvailable: "available"))
        let cue = TranscriptCue(start: 0, end: 1, text: name + " evidence")
        let raw: [String: Any] = ["schema_version": 1, "filename": recording.filename, "size_bytes": 123,
            "sha256": recording.sha256, "accepted_job_id": name,
            "cues": [["start": 0, "end": 1, "text": cue.text]]]
        let payload = try repository.storePayload(JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), mediaType: "application/json")
        let revision = TranscriptRevision(recordingID: recording.id, acceptedJobID: name, content: payload, cues: [cue], duration: 1)
        recording.currentTranscriptRevisionID = revision.id
        let final = recording
        try repository.update { $0.recordings.append(final); $0.transcriptRevisions.append(revision) }
    }

    func testGrantTimeScopeEnforcedForListsSearchAndDirectHistoricalCitations() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retrieval = RetrievalService(repository: f.repository)
        XCTAssertEqual(try retrieval.listMaterials(classID: f.classID, grantID: f.grantID).map(\.id), [f.inside.id])
        let unrestricted = try retrieval.search(ContextQuery(classIDs: [f.classID], text: "evidence", limit: 100))
        XCTAssertEqual(unrestricted.results.count, 7)
        let scoped = try retrieval.search(ContextQuery(classIDs: [f.classID], text: "evidence", limit: 100), grantID: f.grantID)
        XCTAssertEqual(Set(scoped.results.map(\.sourceKind)), Set(["material", "activity", "transcript"]))
        XCTAssertEqual(scoped.results.count, 3)
        for result in unrestricted.results {
            if result.title.hasPrefix("inside") {
                XCTAssertNoThrow(try retrieval.resolve(result.citation, grantID: f.grantID))
            } else {
                XCTAssertThrowsError(try retrieval.resolve(result.citation, grantID: f.grantID))
            }
        }
        XCTAssertEqual(try retrieval.search(ContextQuery(classIDs: [f.classID], text: "evidence", eventFrom: Date(timeIntervalSince1970: 500)), grantID: f.grantID).total, 0)
        // Persisted narrowing applies to citations already returned to an active bridge.
        let old = try XCTUnwrap(scoped.results.first?.citation)
        try f.repository.update { $0.grants[0].eventFrom = Date(timeIntervalSince1970: 350) }
        XCTAssertThrowsError(try retrieval.resolve(old, grantID: f.grantID))
    }

    func testSnapshotIntersectsGrantAndExplicitFiltersWithoutBroadeningEmptySelection() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let retrieval = RetrievalService(repository: f.repository)
        let manifest = try retrieval.buildContextBundle(classIDs: [f.classID], to: f.root.appendingPathComponent("scoped"), grantID: f.grantID,
            eventFrom: Date(timeIntervalSince1970: 250), eventUntil: Date(timeIntervalSince1970: 350))
        XCTAssertEqual(manifest.sources.count, 3)
        XCTAssertTrue(manifest.sources.allSatisfy { $0.title.hasPrefix("inside") })
        XCTAssertEqual(manifest.eventFrom, Date(timeIntervalSince1970: 250))
        XCTAssertEqual(manifest.eventUntil, Date(timeIntervalSince1970: 350))
        let materials = try retrieval.buildContextBundle(classIDs: [f.classID], to: f.root.appendingPathComponent("material"), grantID: f.grantID, materialIDs: [f.inside.id])
        XCTAssertEqual(materials.sources.map(\.citation.sourceID), [f.inside.id])
        XCTAssertEqual(materials.materialIDs, [f.inside.id])
        let empty = try retrieval.buildContextBundle(classIDs: [f.classID], to: f.root.appendingPathComponent("empty"), materialIDs: [])
        XCTAssertTrue(empty.sources.isEmpty)
        let rejected = f.root.appendingPathComponent("rejected")
        XCTAssertThrowsError(try retrieval.buildContextBundle(classIDs: [f.classID], to: rejected, grantID: f.grantID, materialIDs: [f.outside.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertThrowsError(try retrieval.buildContextBundle(classIDs: [f.classID], to: rejected, grantID: f.grantID, eventFrom: Date(timeIntervalSince1970: 500)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertThrowsError(try retrieval.buildContextBundle(classIDs: [f.classID], to: rejected, eventFrom: Date(timeIntervalSince1970: .infinity)))
    }

    func testMaterialOnlyGrantExcludesOtherSourcesAndProposalRevocationRetainsReads() throws {
        let f = try fixture(materialOnly: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let retrieval = RetrievalService(repository: f.repository)
        let page = try retrieval.search(ContextQuery(classIDs: [f.classID], text: "evidence"), grantID: f.grantID)
        XCTAssertEqual(page.results.map(\.citation.sourceID), [f.inside.id])
        let citation = try XCTUnwrap(page.results.first?.citation)
        let proposals = ProposalService(repository: f.repository)
        let proposal = try proposals.propose(classID: f.classID, agentIdentity: "ignored", title: "Reviewed outcome", body: "Fictional reasoning", idempotencyKey: "first", citations: [citation], contextManifest: [citation], grantID: f.grantID)
        let accepted = try proposals.accept(proposal.id)
        XCTAssertEqual(accepted.inputContextManifest, [citation])
        XCTAssertEqual(f.repository.state.activityRevisions.first { $0.activityID == accepted.id }?.inputContextManifest, [citation])
        try f.repository.update { $0.connections[0].capabilities = ["read_context"] }
        XCTAssertThrowsError(try proposals.propose(classID: f.classID, agentIdentity: "ignored", title: "Another", body: "reasoning", idempotencyKey: "second", grantID: f.grantID))
        XCTAssertEqual(try retrieval.resolve(citation, grantID: f.grantID).text, "inside material evidence")
        XCTAssertEqual(try retrieval.listMaterials(classID: f.classID, grantID: f.grantID).count, 1)
    }

    func testTimeBoundedGrantCannotCorrectOutOfRangeActivity() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let outside = try XCTUnwrap(f.repository.state.activities.first { $0.title == "outside note" })
        XCTAssertThrowsError(try ProposalService(repository: f.repository).propose(classID: f.classID, agentIdentity: "ignored", title: "Correction", body: "outside activity", targetID: outside.id, expectedVersion: outside.version, idempotencyKey: "outside", grantID: f.grantID))
        XCTAssertTrue(f.repository.state.proposals.isEmpty)
    }
}

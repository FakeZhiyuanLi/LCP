import XCTest
import Foundation
import LCPContextCore
import LCPContextServices
@testable import LCPAgentBridge

final class BridgeAssociationTests: XCTestCase {
    @MainActor
    func testHistoricalCitationToolsDoNotExpandOldClassAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LCPBridgeAssociation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        let term = AcademicTerm(name: "Fictional term")
        let a = ClassEnrollment(termID: term.id, courseCode: "A", title: "Original class")
        let b = ClassEnrollment(termID: term.id, courseCode: "B", title: "PRIVATE_CURRENT_CLASS_NAME")
        let connection = AgentConnection(name: "Fictional scoped agent", mode: "stdio", capabilities: ["read_context", "propose_study_log"])
        let grantA = AgentGrant(connectionID: connection.id, allowedClassIDs: [a.id])
        let grantB = AgentGrant(connectionID: connection.id, allowedClassIDs: [b.id])
        var recording = LectureRecording(classID: a.id, filename: "Fictional_2026-11-19_0900.m4a", sizeBytes: 123,
            sha256: String(repeating: "a", count: 64), capturedAt: Date(timeIntervalSince1970: 1_763_549_200), acceptedJobID: "opaque-job",
            status: LectureStatusFacts(transcriptAvailable: "available"))
        func revision(_ text: String) throws -> TranscriptRevision {
            let cues = [TranscriptCue(start: 0, end: 2, text: text), TranscriptCue(start: 3, end: 5, text: "UNCITED_SECRET")]
            let payload: [String: Any] = ["schema_version": 1, "filename": recording.filename, "size_bytes": recording.sizeBytes,
                "sha256": recording.sha256, "accepted_job_id": "opaque-job", "cues": cues.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
                "audio_events": [], "generated_at": "2026-11-19T10:00:00Z"]
            let content = try repository.storePayload(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), mediaType: "application/vnd.lcp.transcript+json")
            return TranscriptRevision(recordingID: recording.id, acceptedJobID: "opaque-job", content: content, cues: cues, duration: 10)
        }
        let oldRevision = try revision("Saved original explanation.")
        recording.currentTranscriptRevisionID = oldRevision.id
        let initialRecording = recording
        try repository.update { state in
            state.terms.append(term); state.classes += [a,b]; state.connections.append(connection); state.grants += [grantA, grantB]
            state.recordings.append(initialRecording); state.transcriptRevisions.append(oldRevision)
        }
        let retrieval = RetrievalService(repository: repository)
        let old = try XCTUnwrap(retrieval.search(ContextQuery(classIDs: [a.id], text: "Saved original"), grantID: grantA.id).results.first?.citation)
        _ = try retrieval.pin(old)
        try repository.update { $0.recordings[0].classID = b.id }
        let future = try revision("FUTURE_B_REVISION")
        try repository.update { state in state.transcriptRevisions.append(future); state.recordings[0].currentTranscriptRevisionID = future.id }

        func server(_ grant: AgentGrant) -> BridgeServer {
            let value = BridgeServer(repository: repository, grantID: grant.id)
            _ = value.handle(.object(["jsonrpc": .string("2.0"), "id": .number(0), "method": .string("initialize")]))
            return value
        }
        let serverA = server(grantA), serverB = server(grantB)
        func call(_ server: BridgeServer, _ name: String, _ args: [String: JSONValue]) throws -> (Bool, JSONValue) {
            let response = try XCTUnwrap(server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object(["name": .string(name), "arguments": .object(args)])]))?.object?["result"]?.object)
            let error = response["isError"] == .bool(true)
            let text = try XCTUnwrap(response["content"]?.array?.first?.object?["text"]?.string)
            if error { return (true, .string(text)) }
            return (false, try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        }
        let citationArgs = ["citation_url": JSONValue.string(CitationLink.url(for: old).absoluteString)]
        let resolved = try call(serverA, "resolve_citation", citationArgs)
        XCTAssertFalse(resolved.0)
        XCTAssertTrue(resolved.1.object?["text"]?.string?.contains("Saved original") == true)
        XCTAssertTrue(try call(serverB, "resolve_citation", citationArgs).0)
        var forged = old; forged.locator = .cues(start: 1, end: 1)
        XCTAssertTrue(try call(serverA, "get_source_passage", ["citation_url": .string(CitationLink.url(for: forged).absoluteString)]).0)
        forged = old; forged.revisionID = future.id; forged.payloadSHA256 = future.content.sha256
        XCTAssertTrue(try call(serverA, "resolve_citation", ["citation_url": .string(CitationLink.url(for: forged).absoluteString)]).0)
        let aSearch = try call(serverA, "search_class_context", ["class_ids": .array([.string(a.id.uuidString)]), "query": .string("FUTURE_B_REVISION")])
        XCTAssertEqual(aSearch.1.object?["total"], .number(0))
        let bSearch = try call(serverB, "search_class_context", ["class_ids": .array([.string(b.id.uuidString)]), "query": .string("FUTURE_B_REVISION")])
        XCTAssertEqual(bSearch.1.object?["total"], .number(1))
        let bundle = try call(serverA, "build_context_bundle", ["class_ids": .array([.string(a.id.uuidString)])])
        XCTAssertFalse(bundle.0)
        let encodedBundle = try JSONEncoder().encode(bundle.1)
        let bundleText = String(decoding: encodedBundle, as: UTF8.self)
        XCTAssertTrue(bundleText.contains("Saved original"))
        XCTAssertFalse(bundleText.contains("UNCITED_SECRET"))
        XCTAssertFalse(bundleText.contains("FUTURE_B_REVISION"))
        XCTAssertFalse(bundleText.contains(b.title))
        let classes = try call(serverA, "list_classes", [:])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(classes.1), as: UTF8.self).contains(b.title))
        let proposal = try call(serverA, "propose_study_log", ["class_id": .string(a.id.uuidString), "title": .string("Reviewed exact source"),
            "body": .string("A selected outcome."), "idempotency_key": .string("old-exact"), "citations": .array([try JSONValue.encoded(old)])])
        XCTAssertFalse(proposal.0)
        let stored = try XCTUnwrap(repository.state.proposals.first)
        XCTAssertEqual(stored.citations, [old]); XCTAssertEqual(stored.contextManifest, [old])
        XCTAssertTrue(stored.contextManifest.allSatisfy { $0.classID == a.id && $0.revisionID == oldRevision.id })
        XCTAssertTrue(repository.state.activities.isEmpty)
    }
}

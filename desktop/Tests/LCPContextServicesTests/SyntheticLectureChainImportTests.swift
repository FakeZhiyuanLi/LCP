import XCTest
import Foundation
import CryptoKit
import LCPContextCore
@testable import LCPContextServices

/// Opt-in receiver for one traceable generated-audio cross-host fixture. The
/// server uses its real admission/head/export paths with an explicitly fake
/// transcript provider; this does not measure speech recognition or Drive.
final class SyntheticLectureChainImportTests: XCTestCase {
    @MainActor
    func testReviewActualChainAgentAnswerAndRestoreItsOriginalCueOffline() throws {
        guard let path = ProcessInfo.processInfo.environment["LCP_SYNTHETIC_CHAIN_ROOT"],
              let receiptPath = ProcessInfo.processInfo.environment["LCP_SYNTHETIC_CHAIN_AGENT_RECEIPT"] else {
            throw XCTSkip("Set the deliberate chain root and actual-agent receipt for reviewed outcome recovery.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("LCPSyntheticLectureChain-"),
              root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/") else { throw ChainError.invalidRoot }
        let source = try JSONDecoder().decode(NativeCaptureReceipt.self, from: Data(contentsOf: root.appendingPathComponent("native-capture-receipt.json")))
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: receiptPath))) as? [String: Any])
        XCTAssertEqual(receipt["passed"] as? Bool, true)
        XCTAssertEqual(receipt["fictional_only"] as? Bool, true)
        XCTAssertEqual(receipt["capture_filename"] as? String, source.filename)
        XCTAssertEqual(receipt["capture_audio_sha256"] as? String, source.sha256)
        let answer = try XCTUnwrap(receipt["answer"] as? String)
        let verified = try XCTUnwrap(receipt["verified_passages"] as? [[String: Any]])
        let citations = try verified.map { passage -> SourceCitation in
            let link = try XCTUnwrap(passage["citation_url"] as? String)
            let url = try XCTUnwrap(URL(string: link))
            let citation = try CitationLink.decode(url)
            XCTAssertEqual(citation.sourceKind, "transcript")
            XCTAssertEqual(citation.payloadSHA256, receipt["transcript_sha256"] as? String)
            return citation
        }
        let classID = try XCTUnwrap(UUID(uuidString: source.academicClassID))
        XCTAssertFalse(citations.isEmpty)
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("desktop-profile"))
        let retrieval = RetrievalService(repository: repository)
        let originalText = try citations.map { try retrieval.resolve($0).text }
        let service = ProposalService(repository: repository)
        let proposal = try service.propose(classID: classID, agentIdentity: "Codex CLI synthetic-chain actual answer",
            title: "Reviewed purple comet outcome", body: answer, idempotencyKey: "synthetic-chain-actual-answer-v1",
            citations: citations, contextManifest: citations)
        let accepted = try service.accept(proposal.id)
        XCTAssertEqual(try service.accept(proposal.id).id, accepted.id)
        XCTAssertEqual(accepted.body, answer)
        XCTAssertEqual(accepted.inputContextManifest, citations)
        let backup = root.appendingPathComponent("reviewed-outcome-backup")
        let restoredPath = root.appendingPathComponent("reviewed-outcome-offline-restored")
        guard !FileManager.default.fileExists(atPath: backup.path), !FileManager.default.fileExists(atPath: restoredPath.path) else {
            throw ChainError.existingProfile
        }
        try repository.exportBackup(to: backup)
        let restored = try ContextRepository(rootURL: restoredPath)
        try restored.restoreBackup(from: backup)
        let restoredAnswer = try XCTUnwrap(restored.state.activities.first { $0.id == accepted.id })
        XCTAssertEqual(restoredAnswer.body, answer)
        XCTAssertEqual(restoredAnswer.agentIdentity, accepted.agentIdentity)
        XCTAssertEqual(restoredAnswer.inputContextManifest, citations)
        XCTAssertTrue(restored.state.grants.isEmpty)
        XCTAssertEqual(try citations.map { try RetrievalService(repository: restored).resolve($0).text }, originalText)
        let result: [String: Any] = ["schema_version": 1, "passed": true, "fictional": true,
            "filename": source.filename, "audio_sha256": source.sha256, "capture_session_id": source.captureSessionID,
            "actual_agent_receipt": receiptPath, "accepted_activity_id": accepted.id.uuidString,
            "agent_identity": accepted.agentIdentity ?? "", "answer_body_sha256": SHA256.hash(data: Data(answer.utf8)).map { String(format: "%02x", $0) }.joined(),
            "exact_citations": citations.map { CitationLink.url(for: $0).absoluteString },
            "backup_path": backup.path, "fresh_offline_restore_path": restoredPath.path,
            "grants_resurrected": false, "microphone_used": false, "real_stt_verified": false,
            "one_academic_week_verified": false, "observed_at": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("native-reviewed-answer-restore-receipt.json"), options: .atomic)
    }

    @MainActor
    func testImportReturnedStrictSyntheticFeedAndVerifyExactLocalAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["LCP_SYNTHETIC_CHAIN_ROOT"],
              let feedPath = ProcessInfo.processInfo.environment["LCP_SYNTHETIC_CHAIN_FEED"] else {
            throw XCTSkip("Set LCP_SYNTHETIC_CHAIN_ROOT and LCP_SYNTHETIC_CHAIN_FEED for the deliberate synthetic chain.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("LCPSyntheticLectureChain-"),
              root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/") else { throw ChainError.invalidRoot }
        let source = try JSONDecoder().decode(NativeCaptureReceipt.self, from: Data(contentsOf: root.appendingPathComponent("native-capture-receipt.json")))
        XCTAssertTrue(source.fictional); XCTAssertFalse(source.microphoneUsed)
        guard let classID = UUID(uuidString: source.academicClassID) else { throw ChainError.invalidRoot }
        let profile = root.appendingPathComponent("desktop-profile", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: profile.path) else { throw ChainError.existingProfile }
        let repository = try ContextRepository(rootURL: profile)
        let term = AcademicTerm(name: "Fictional synthetic-chain term")
        let enrollment = ClassEnrollment(id: classID, termID: term.id, courseCode: "SYNTHETIC CHAIN", title: "Fictional generated-audio chain")
        try repository.update { state in state.terms.append(term); state.classes.append(enrollment) }
        let imported = try FeedImporter(repository: repository).importGeneration(from: URL(fileURLWithPath: feedPath, isDirectory: true))
        XCTAssertEqual(imported.importedRecordings, 1); XCTAssertEqual(imported.importedTranscripts, 1)
        let original = try XCTUnwrap(repository.state.recordings.first)
        XCTAssertEqual(original.filename, source.filename); XCTAssertEqual(original.sizeBytes, source.sizeBytes); XCTAssertEqual(original.sha256, source.sha256)
        XCTAssertNil(original.classID, "A source filename must not infer an academic association.")
        XCTAssertNotNil(original.acceptedJobID)
        let recordingID = original.id
        try repository.update { state in
            let offset = state.recordings.firstIndex { $0.id == recordingID }!
            state.recordings[offset].classID = classID
            state.recordings[offset].capturedAt = ISO8601DateFormatter().date(from: source.generatedAt)
            state.recordings[offset].timeZoneID = "America/Los_Angeles"
            state.recordings[offset].localAudioPath = source.audioPath
            state.recordings[offset].status.finalizedLocally = "finalized"
        }
        let recording = try XCTUnwrap(repository.state.recordings.first)
        let revisionID = try XCTUnwrap(recording.currentTranscriptRevisionID)
        let transcript = try XCTUnwrap(repository.state.transcriptRevisions.first { $0.id == revisionID })
        XCTAssertEqual(transcript.acceptedJobID, recording.acceptedJobID)
        XCTAssertFalse(transcript.cues.isEmpty)
        XCTAssertTrue(transcript.cues.contains { $0.text.lowercased().contains("purple comet invariant") })
        let audioURL = URL(fileURLWithPath: source.audioPath)
        let bytes = try await AudioPlaybackService.verifyAudio(url: audioURL, recording: recording)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), source.sha256)
        let playback = AudioPlaybackService()
        try await playback.load(url: audioURL, recording: recording)
        XCTAssertEqual(playback.recordingID, recording.id)
        XCTAssertEqual(playback.duration, source.durationSeconds, accuracy: 0.1)
        let cue = try XCTUnwrap(transcript.cues.first { $0.text.lowercased().contains("purple comet invariant") })
        try playback.seek(to: cue.start)
        XCTAssertEqual(playback.currentTime, cue.start, accuracy: 0.001)
        XCTAssertFalse(playback.isPlaying)
        let connection = AgentConnection(name: "Codex synthetic identity-chain acceptance", mode: "stdio", capabilities: ["read_context", "propose_study_log"])
        let grant = AgentGrant(connectionID: connection.id, allowedClassIDs: [classID])
        try repository.update { state in state.connections.append(connection); state.grants.append(grant) }
        let retrieval = RetrievalService(repository: repository)
        let matches = try retrieval.search(ContextQuery(classIDs: [classID], text: "purple comet"), grantID: grant.id)
        let citation = try XCTUnwrap(matches.results.first { $0.sourceKind == "transcript" }?.citation)
        let passage = try retrieval.resolve(citation, grantID: grant.id)
        XCTAssertTrue(passage.text.lowercased().contains("forty two"))
        XCTAssertEqual(citation.revisionID, transcript.id)
        XCTAssertEqual(citation.payloadSHA256, transcript.content.sha256)
        _ = try retrieval.pin(citation)
        XCTAssertEqual(try CitationLink.decode(CitationLink.url(for: citation)), citation)
        playback.stop()
        let interop: [String: Any] = ["schema_version": 1, "fictional": true, "root": profile.path,
            "class_id": classID.uuidString, "grant_id": grant.id.uuidString,
            "question": "What does this fictional lecture say the purple comet invariant equals? Cite its exact lecture cue.",
            "required_source_kind": "transcript", "expected_phrase": "forty two",
            "capture_audio_sha256": source.sha256, "filename": source.filename,
            "accepted_job_id": transcript.acceptedJobID, "transcript_sha256": transcript.content.sha256]
        try JSONSerialization.data(withJSONObject: interop, options: [.prettyPrinted, .sortedKeys]).write(to: profile.appendingPathComponent("interop-manifest.json"), options: .atomic)
        let receipt: [String: Any] = ["schema_version": 1, "passed": true, "fictional": true,
            "native_capture_session_id": source.captureSessionID, "filename": recording.filename,
            "audio_size_bytes": recording.sizeBytes, "audio_sha256": recording.sha256,
            "feed_generation_id": imported.generationID, "accepted_job_id": transcript.acceptedJobID,
            "transcript_sha256": transcript.content.sha256, "recording_id": recording.id.uuidString,
            "academic_class_id": classID.uuidString, "grant_id": grant.id.uuidString,
            "citation_url": CitationLink.url(for: citation).absoluteString,
            "cue_start": cue.start, "cue_end": cue.end,
            "audio_verified": true, "native_decoder_loaded": true, "exact_seek_verified_without_playback": true,
            "audibility_verified": false, "microphone_used": false, "real_stt_verified": false,
            "desktop_profile": profile.path, "feed_path": feedPath,
            "observed_at": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("native-import-audio-receipt.json"), options: .atomic)
        print("LCP_SYNTHETIC_CHAIN_DESKTOP_PROFILE=" + profile.path)
    }
}

private enum ChainError: Error { case invalidRoot, existingProfile }
private struct NativeCaptureReceipt: Decodable {
    var fictional: Bool
    var microphoneUsed: Bool
    var academicClassID: String
    var captureSessionID: String
    var filename: String
    var sizeBytes: UInt64
    var sha256: String
    var audioPath: String
    var durationSeconds: Double
    var generatedAt: String
    enum CodingKeys: String, CodingKey {
        case fictional, filename, sha256
        case microphoneUsed = "microphone_used", academicClassID = "academic_class_id", captureSessionID = "capture_session_id"
        case sizeBytes = "size_bytes", audioPath = "audio_path", durationSeconds = "duration_seconds", generatedAt = "generated_at"
    }
}

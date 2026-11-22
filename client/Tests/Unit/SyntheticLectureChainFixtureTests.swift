import AVFoundation
import CryptoKit
import XCTest
@testable import LCPClient

/// Deliberate generated-audio identity-chain fixture. This never captures a
/// microphone. The server must label its transcript provider as a fake fixture.
final class SyntheticLectureChainFixtureTests: XCTestCase {
    @MainActor
    func testGenerateOneFinalizedSyntheticLectureForIsolatedChain() async throws {
        guard let path = ProcessInfo.processInfo.environment["LCP_SYNTHETIC_CHAIN_ROOT"] else {
            throw XCTSkip("Set LCP_SYNTHETIC_CHAIN_ROOT to a new /tmp/LCPSyntheticLectureChain-* directory for the deliberate cross-host fixture.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard ["/tmp/", "/private/tmp/"].contains(where: { root.path.hasPrefix($0) }),
              root.lastPathComponent.hasPrefix("LCPSyntheticLectureChain-"),
              !FileManager.default.fileExists(atPath: root.path) else {
            throw FixtureError.invalidDestination
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let incoming = root.appendingPathComponent("native-finalized", isDirectory: true)
        let catalog = root.appendingPathComponent("classes.json")
        let now = Date()
        let course = "LCPCHAIN" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        let academicID = UUID()
        let manifest = try LectureClassManifest(generatedAt: now, rootFolderID: "synthetic_chain_no_drive_root",
            classes: [try LectureClass(name: course, driveFolderID: "synthetic_chain_no_drive_folder")])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: catalog, options: .atomic)
        let engine = try AudioRecorder(ingestManager: IngestManager(stagingDirectory: incoming), dependencies: .init(
            hasMicrophoneUsageDescription: { true }, authorizationStatus: { .authorized }, requestAccess: { true },
            makeRecorder: { url, settings in try GeneratedAACSource(outputURL: url, settings: settings) }))
        let configuration = CaptureConfiguration(stagingDirectory: incoming, catalogURL: catalog,
            leaseURL: root.appendingPathComponent("synthetic-capture.lock"), legacyBundleURLs: [])
        let capture = CaptureCoordinator(engine: engine, configuration: configuration, compatibilityCheck: {}, now: { now })
        try await capture.start(destinationID: String(course), academicClassID: academicID, expectedDriveFolderID: "synthetic_chain_no_drive_folder")
        XCTAssertEqual(capture.state, .recording)
        let session = try XCTUnwrap(capture.activeSession)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: incoming.path).contains { $0.hasSuffix(".ready.json") },
                       "The generated input cannot publish a ready marker before the normal stop/finalization boundary.")
        capture.stop()
        XCTAssertEqual(capture.state, .idle)
        let finalized = try XCTUnwrap(capture.lastFinalized)
        XCTAssertEqual(finalized.session.id, session.id)
        XCTAssertEqual(finalized.session.academicClassID, academicID)
        let marker = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: finalized.readyURL))
        let bytes = try Data(contentsOf: finalized.audioURL)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(marker.sizeBytes, UInt64(bytes.count)); XCTAssertEqual(marker.sha256, sha)
        XCTAssertEqual(marker.filename, finalized.filename)
        let reader = try AVAudioFile(forReading: finalized.audioURL)
        XCTAssertEqual(reader.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(reader.fileFormat.sampleRate, 16_000); XCTAssertEqual(reader.fileFormat.channelCount, 1)
        let duration = Double(reader.length) / reader.processingFormat.sampleRate
        XCTAssertEqual(duration, 8, accuracy: 0.1)
        try encoder.encode(finalized).write(to: root.appendingPathComponent("finalized-capture.json"), options: .atomic)
        let expectedWords = "This fictional chain lecture states that the purple comet invariant equals forty two and rotations preserve sorted order."
        let receipt: [String: Any] = ["schema_version": 1, "fictional": true, "microphone_used": false,
            "audio_source": "programmatically generated 440 Hz and 660 Hz AAC tone; no speech",
            "capture_path": "actual CaptureCoordinator -> AudioRecorder with injected AudioRecording source -> real RecordingManifest",
            "transcript_provider_required": "fake synthetic fixture; never claim STT accuracy or provider health",
            "generated_at": ISO8601DateFormatter().string(from: now), "fixture_root": root.path,
            "filename": finalized.filename, "size_bytes": bytes.count, "sha256": sha,
            "academic_class_id": academicID.uuidString, "capture_session_id": session.id.uuidString,
            "audio_path": finalized.audioURL.path, "ready_path": finalized.readyURL.path,
            "codec": "AAC", "sample_rate": 16_000, "channels": 1, "bitrate_setting": 32_000,
            "duration_seconds": duration, "fictional_transcript_text": expectedWords,
            "expected_cues": [["start": 0.5, "end": 3.5, "text": expectedWords, "speaker": "speaker_0"]],
            "question": "What does this fictional lecture say the purple comet invariant equals? Cite its exact lecture cue."]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("native-capture-receipt.json"), options: .atomic)
        print("LCP_SYNTHETIC_CHAIN_READY=" + root.path)
    }
}

private enum FixtureError: Error { case invalidDestination, allocation }

/// The normal recording engine owns lifecycle and manifest publication. This
/// injected source supplies known generated PCM instead of a microphone device.
private final class GeneratedAACSource: AudioRecording {
    var delegate: (any AVAudioRecorderDelegate)?
    var currentTime: TimeInterval { 8 }
    private let outputURL: URL
    init(outputURL: URL, settings: [String: Any]) throws {
        self.outputURL = outputURL
        let writer = try AVAudioFile(forWriting: outputURL, settings: settings)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 128_000),
              let channel = pcm.floatChannelData?[0] else { throw FixtureError.allocation }
        pcm.frameLength = 128_000
        for index in 0..<128_000 {
            let t = Double(index) / 16_000
            let envelope = min(1, t * 10) * min(1, (8 - t) * 10)
            channel[index] = Float((sin(2 * .pi * 440 * t) + sin(2 * .pi * 660 * t)) * 0.05 * envelope)
        }
        try writer.write(from: pcm)
        // The native AAC writer closes before init returns; engine stop still
        // owns the only ready-marker publication boundary.
    }
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { true }
    func stop() {}
    func deleteRecording() -> Bool { (try? FileManager.default.removeItem(at: outputURL)) != nil }
}

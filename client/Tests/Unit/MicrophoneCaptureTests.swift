import AVFoundation
import AudioToolbox
import XCTest
@testable import LCPClient

final class MicrophoneCaptureTests: XCTestCase {
    func testSessionNegotiationResetIsReplacedWithExactEncodingBeforeRecording() throws {
        let output = NegotiatedAudioOutput()
        output.audioSettings = AudioConfig().recorderSettings
        let prepared = CaptureFileEncoding.prepare(AudioConfig().recorderSettings, output: output, startSession: {
            // Reproduce the native-device default observed in every failed
            // manual file. Session negotiation happens after initial setup.
            output.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
            return true
        }, stopSession: { XCTFail("Accepted encoding must leave the session running") })
        XCTAssertTrue(prepared)
        let actual = try XCTUnwrap(output.audioSettings)
        XCTAssertEqual(actual[AVSampleRateKey] as? Double, 16_000)
        XCTAssertEqual(actual[AVEncoderBitRateKey] as? Int, 32_000)
        let url = try temporaryRoot().appendingPathComponent("post-negotiation.m4a")
        try writeSyntheticAAC(to: url, settings: actual)
        XCTAssertNil(CaptureFileFinalization.problem(at: url, stopRequested: true, error: nil))
        try assertEncodedBitRate(url, expected: 32_000)
    }

    func testUnattachedNativeOutputDiscardsSettingsAndCannotBeCertified() throws {
        // No input/device/session start: this exercises the actual output's
        // settings API without opening hardware or requesting microphone access.
        let output = AVCaptureAudioFileOutput()
        XCTAssertFalse(CaptureFileEncoding.apply(AudioConfig().recorderSettings, to: output))
        XCTAssertNil(output.audioSettings, "The original pre-attachment assignment silently discarded encoding settings")
    }

    func testRejectedOrIncompleteEncodingSettingsFailClosed() {
        for mode in [NegotiatedAudioOutput.Mode.discard, .replaceWithDeviceDefaults, .dropBitRate] {
            let output = NegotiatedAudioOutput()
            output.mode = mode
            var stopped = false
            XCTAssertFalse(CaptureFileEncoding.prepare(AudioConfig().recorderSettings, output: output,
                                                      startSession: { true }, stopSession: { stopped = true }))
            XCTAssertTrue(stopped, "Rejected settings must finish session cleanup before returning false")
        }
    }

    func testFailedSessionDoesNotPretendEncodingIsPrepared() {
        let output = NegotiatedAudioOutput()
        var stopped = false
        XCTAssertFalse(CaptureFileEncoding.prepare(AudioConfig().recorderSettings, output: output,
                                                  startSession: { false }, stopSession: { stopped = true }))
        XCTAssertTrue(stopped)
        XCTAssertNil(output.audioSettings)
    }

    @MainActor
    func testRejectedEncodingClosesSessionBeforeCoordinatorReleasesLease() async throws {
        for failure in [StartupRejectingRecording.Stage.prepare, .record] {
            let root = try temporaryRoot()
            let catalogURL = root.appendingPathComponent("classes.json")
            let manifest = try LectureClassManifest(generatedAt: Date(), rootFolderID: "synthetic",
                                                   classes: [LectureClass(name: "SYNTHETIC")])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: catalogURL)
            let leaseURL = root.appendingPathComponent("capture.lock")
            let recording = StartupRejectingRecording(failure: failure)
            recording.onSynchronousCleanup = {
                // This closure models the blocking stopRunning call. It must
                // run before the start error escapes and the process lease is
                // released, for both prepare and pre-open record rejection.
                do {
                    let competing = try CaptureLease.acquire(at: leaseURL, sessionID: UUID())
                    competing.release()
                    XCTFail("The coordinator released the lease before hardware cleanup")
                } catch {
                    XCTAssertEqual(error as? CaptureError, .captureInUse)
                }
                XCTAssertTrue(recording.sessionRunning)
            }
            let engine = try AudioRecorder(ingestManager: IngestManager(stagingDirectory: root), dependencies: .init(
                hasMicrophoneUsageDescription: { true }, authorizationStatus: { .authorized }, requestAccess: { true },
                makeRecorder: { _, _ in recording }
            ))
            let coordinator = CaptureCoordinator(engine: engine, configuration: CaptureConfiguration(
                stagingDirectory: root, catalogURL: catalogURL, leaseURL: leaseURL, legacyBundleURLs: []
            ), compatibilityCheck: {})
            do {
                try await coordinator.start(destinationID: "SYNTHETIC")
                XCTFail("Rejected encoding was admitted")
            } catch {
                XCTAssertFalse(recording.sessionRunning, "Failure escaped while the hardware session was still live")
                XCTAssertEqual(recording.synchronousCleanupCount, 1)
                XCTAssertEqual(recording.fileStarts, 0)
                XCTAssertNil(coordinator.activeSession)
                XCTAssertNil(coordinator.lastFinalized)
                let lease = try CaptureLease.acquire(at: leaseURL, sessionID: UUID())
                lease.release()
            }
            recording.onSynchronousCleanup = nil
        }
    }

    @MainActor
    func testRequestedStopAcceptsClosedCorrectlyEncodedFileAndWritesMarker() async throws {
        let fixture = try captureFixture(sampleRate: 16_000)
        fixture.engine.stopRecording()
        XCTAssertTrue(fixture.engine.isFinishing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ready.path))
        let problem = CaptureFileFinalization.problem(at: fixture.audio, stopRequested: true, error: nil)
        XCTAssertNil(problem)
        finish(fixture, problem: problem)
        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertNil(fixture.engine.errorMessage)
        let marker = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: fixture.ready))
        XCTAssertEqual(marker.filename, fixture.audio.lastPathComponent)
        XCTAssertEqual(marker.sizeBytes, UInt64(try Data(contentsOf: fixture.audio).count))
    }

    @MainActor
    func testUnexpectedDelegateCompletionPreservesValidAudioWithoutMarker() async throws {
        let fixture = try captureFixture(sampleRate: 16_000)
        let original = try Data(contentsOf: fixture.audio)
        let problem = CaptureFileFinalization.problem(at: fixture.audio, stopRequested: false, error: nil)
        XCTAssertTrue(problem?.contains("without a Stop or Quit") == true)
        finish(fixture, problem: problem)
        XCTAssertFalse(fixture.engine.isRecording)
        XCTAssertEqual(fixture.engine.errorMessage, problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ready.path))
        XCTAssertEqual(try Data(contentsOf: fixture.audio), original)
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ready.path))
    }

    @MainActor
    func testObserved48kHzAACMismatchIsPreservedAndExplainedWithoutMarker() async throws {
        let fixture = try captureFixture(sampleRate: 48_000, bitRate: 128_000)
        let original = try Data(contentsOf: fixture.audio)
        fixture.engine.stopRecording()
        let problem = CaptureFileFinalization.problem(at: fixture.audio, stopRequested: true, error: nil)
        XCTAssertTrue(problem?.contains("unexpected format") == true)
        XCTAssertTrue(problem?.contains("48,000") == true || problem?.contains("48000") == true)
        finish(fixture, problem: problem)
        XCTAssertEqual(fixture.engine.errorMessage, problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ready.path))
        XCTAssertEqual(try Data(contentsOf: fixture.audio), original)
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ready.path))
    }

    @MainActor
    func testRequestedStopDoesNotSuppressDelegateErrorEvenForPlayableFile() async throws {
        let fixture = try captureFixture(sampleRate: 16_000)
        fixture.engine.stopRecording()
        let error = NSError(domain: AVFoundationErrorDomain, code: -11818,
                            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true])
        let problem = CaptureFileFinalization.problem(at: fixture.audio, stopRequested: true, error: error)
        XCTAssertTrue(problem?.contains("code \(error.code)") == true)
        finish(fixture, problem: problem)
        XCTAssertEqual(fixture.engine.errorMessage, problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ready.path))
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ready.path))
    }

    func testUnreadableAndEmptyFilesDoNotPassFinalization() throws {
        let root = try temporaryRoot()
        let missing = root.appendingPathComponent("missing.m4a")
        XCTAssertNotNil(CaptureFileFinalization.problem(at: missing, stopRequested: true, error: nil))
        let empty = root.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        XCTAssertNotNil(CaptureFileFinalization.problem(at: empty, stopRequested: true, error: nil))
        XCTAssertEqual(try Data(contentsOf: empty).count, 0)
    }

    @MainActor
    private func captureFixture(sampleRate: Double, bitRate: Int = 32_000) throws -> CaptureFixture {
        let root = try temporaryRoot()
        let recording = FinalizingRecording()
        let engine = try AudioRecorder(ingestManager: IngestManager(stagingDirectory: root), dependencies: .init(
            hasMicrophoneUsageDescription: { true }, authorizationStatus: { .authorized }, requestAccess: { true },
            makeRecorder: { url, settings in
                recording.audio = url
                var actual = settings
                actual[AVSampleRateKey] = sampleRate
                actual[AVEncoderBitRateKey] = bitRate
                try self.writeSyntheticAAC(to: url, settings: actual)
                return recording
            }
        ))
        engine.courseCode = "SYNTHETIC"
        try engine.startRecording()
        let audio = try XCTUnwrap(recording.audio)
        return CaptureFixture(engine: engine, recording: recording, audio: audio, ready: RecordingManifest.readyURL(for: audio))
    }

    @MainActor
    private func finish(_ fixture: CaptureFixture, problem: String?) {
        let identity = ObjectIdentifier(fixture.recording)
        if let problem { fixture.engine.recordingEncodingFailed(identity: identity, message: problem) }
        fixture.engine.finishRecording(identity: identity, successfully: problem == nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeSyntheticAAC(to url: URL, settings: [String: Any]) throws {
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let count = AVAudioFrameCount(writer.processingFormat.sampleRate * 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: count))
        buffer.frameLength = count
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            audio.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(audio.mDataByteSize))
        }
        try writer.write(from: buffer)
    }

    private func assertEncodedBitRate(_ url: URL, expected: UInt32) throws {
        var file: AudioFileID?
        XCTAssertEqual(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file), noErr)
        let opened = try XCTUnwrap(file)
        defer { AudioFileClose(opened) }
        var bitRate: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        XCTAssertEqual(AudioFileGetProperty(opened, kAudioFilePropertyBitRate, &size, &bitRate), noErr)
        // AAC silence compresses far below its configured target. The exact
        // 32 kbps request is checked above; this also rejects the observed
        // native default (~125 kbps) without inventing a fixed silent bitrate.
        XCTAssertGreaterThan(bitRate, 0)
        XCTAssertLessThanOrEqual(bitRate, expected * 2)
    }
}

private final class NegotiatedAudioOutput: CaptureFileAudioSettings {
    enum Mode { case accept, discard, replaceWithDeviceDefaults, dropBitRate }
    var mode = Mode.accept
    private var stored: [String: Any]?
    var audioSettings: [String: Any]? {
        get { stored }
        set {
            switch mode {
            case .accept: stored = newValue
            case .discard: stored = nil
            case .replaceWithDeviceDefaults:
                stored = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
            case .dropBitRate:
                stored = newValue
                stored?.removeValue(forKey: AVEncoderBitRateKey)
            }
        }
    }
}

private struct CaptureFixture {
    let engine: AudioRecorder
    let recording: FinalizingRecording
    let audio: URL
    let ready: URL
}

private final class FinalizingRecording: AudioRecording {
    weak var delegate: (any AVAudioRecorderDelegate)?
    var currentTime: TimeInterval = 2
    let finalizesAsynchronously = true
    var audio: URL?
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { true }
    func stop() {}
    func deleteRecording() -> Bool { false }
}

private final class StartupRejectingRecording: AudioRecording {
    enum Stage { case prepare, record }
    let failure: Stage
    let finalizesAsynchronously = true
    weak var delegate: (any AVAudioRecorderDelegate)?
    var currentTime: TimeInterval = 0
    var sessionRunning = false
    var synchronousCleanupCount = 0
    var fileStarts = 0
    var onSynchronousCleanup: (() -> Void)?
    private let output = NegotiatedAudioOutput()

    init(failure: Stage) { self.failure = failure }

    func prepareToRecord() -> Bool {
        if failure == .prepare { output.mode = .replaceWithDeviceDefaults }
        return CaptureFileEncoding.prepare(AudioConfig().recorderSettings, output: output,
                                           startSession: { self.sessionRunning = true; return true },
                                           stopSession: stopSession)
    }

    func record() -> Bool {
        output.mode = .dropBitRate
        guard CaptureFileEncoding.readyToRecord(AudioConfig().recorderSettings, output: output,
                                                sessionReady: sessionRunning, stopSession: stopSession) else { return false }
        fileStarts += 1
        return true
    }

    private func stopSession() {
        onSynchronousCleanup?()
        synchronousCleanupCount += 1
        sessionRunning = false
    }

    // Deliberately do not rescue a missing helper cleanup here. This verifies
    // the startup checks themselves stop hardware before failed-start teardown.
    func stop() {}
    func deleteRecording() -> Bool { true }
}

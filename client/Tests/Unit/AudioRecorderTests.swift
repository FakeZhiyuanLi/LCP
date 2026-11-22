import AppKit
import AVFoundation
import XCTest
@testable import LCPClient

final class AudioRecorderTests: XCTestCase {
    @MainActor
    func testMissingUsageDescriptionFailsWithoutRequestingMicrophone() async throws {
        let fixture = try fixture()
        fixture.hasUsageDescription = false
        let engine = try fixture.makeEngine()
        let permitted = await engine.requestPermission()
        XCTAssertFalse(permitted)
        XCTAssertEqual(fixture.accessRequests, 0)
        XCTAssertEqual(engine.errorMessage, AudioRecorder.RecordingError.missingMicrophoneUsageDescription.localizedDescription)
        XCTAssertThrowsError(try engine.startRecording())
        XCTAssertEqual(fixture.factoryCalls, 0)
        XCTAssertFalse(engine.isRecording)
    }

    @MainActor
    func testAuthorizedPermissionDoesNotRequestAgain() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        let permitted = await engine.requestPermission()
        XCTAssertTrue(permitted)
        XCTAssertEqual(fixture.accessRequests, 0)
        XCTAssertNil(engine.errorMessage)
    }

    @MainActor
    func testDeniedAndRestrictedPermissionNeverCreateRecorder() async throws {
        for status in [AVAuthorizationStatus.denied, .restricted, .notDetermined] {
            let fixture = try fixture()
            fixture.authorization = status
            let engine = try fixture.makeEngine()
            if status != .notDetermined {
                let permitted = await engine.requestPermission()
                XCTAssertFalse(permitted)
                XCTAssertEqual(fixture.accessRequests, 0)
            }
            XCTAssertThrowsError(try engine.startRecording())
            XCTAssertEqual(engine.errorMessage, AudioRecorder.RecordingError.microphonePermissionRequired.localizedDescription)
            XCTAssertEqual(fixture.factoryCalls, 0)
            XCTAssertFalse(engine.isRecording)
        }
    }

    @MainActor
    func testUndeterminedPermissionUsesRequestResultAndClearsPriorErrorOnGrant() async throws {
        let fixture = try fixture()
        fixture.authorization = .notDetermined
        fixture.accessResult = false
        let engine = try fixture.makeEngine()
        let denied = await engine.requestPermission()
        XCTAssertFalse(denied)
        XCTAssertNotNil(engine.errorMessage)
        fixture.accessResult = true
        let granted = await engine.requestPermission()
        XCTAssertTrue(granted)
        XCTAssertNil(engine.errorMessage)
        XCTAssertEqual(fixture.accessRequests, 2)
    }

    @MainActor
    func testInvalidCourseCodesFailBeforeCreatingRecorder() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        for course in ["", " \n", "../CS182", "CS/182", "CS\n182"] {
            engine.courseCode = course
            XCTAssertThrowsError(try engine.startRecording())
            XCTAssertEqual(engine.errorMessage, AudioRecorder.RecordingError.invalidCourseCode.localizedDescription)
            XCTAssertFalse(engine.isRecording)
        }
        XCTAssertEqual(fixture.factoryCalls, 0)
    }

    @MainActor
    func testExistingMinuteFilenameIsNeverOverwritten() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        // Seed the previous/current/next minute so this remains safe at a clock boundary.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let original = Data("saved lecture must survive".utf8)
        var files: [URL] = []
        for offset: TimeInterval in [-60, 0, 60] {
            let name = "CS182_\(formatter.string(from: Date().addingTimeInterval(offset))).m4a"
            let output = fixture.manager.stagingDirectory.appendingPathComponent(name)
            try original.write(to: output)
            files.append(output)
        }
        XCTAssertThrowsError(try engine.startRecording())
        XCTAssertTrue(engine.errorMessage?.contains("already exists") == true)
        XCTAssertEqual(fixture.factoryCalls, 0)
        for file in files { XCTAssertEqual(try Data(contentsOf: file), original) }
    }

    @MainActor
    func testFactoryErrorLeavesIdleStateAndCanBeRetried() async throws {
        let fixture = try fixture()
        fixture.factoryError = CocoaError(.fileWriteNoPermission)
        let engine = try fixture.makeEngine()
        XCTAssertThrowsError(try engine.startRecording())
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.duration, 0)
        XCTAssertNotNil(engine.errorMessage)
        fixture.factoryError = nil
        try engine.startRecording()
        XCTAssertTrue(engine.isRecording)
        XCTAssertNil(engine.errorMessage)
        engine.stopRecording()
    }

    @MainActor
    func testPrepareFailureStopsAndDeletesPartialOutput() async throws {
        let fixture = try fixture()
        fixture.nextRecorder.preparesSuccessfully = false
        let engine = try fixture.makeEngine()
        XCTAssertThrowsError(try engine.startRecording())
        XCTAssertEqual(fixture.nextRecorder.events, ["prepare", "stop", "delete"])
        XCTAssertNil(fixture.nextRecorder.delegate)
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.errorMessage, AudioRecorder.RecordingError.failedToPrepare.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.nextRecorder.outputURL).path))
        XCTAssertFalse(try manifestExists(fixture))
    }

    @MainActor
    func testRecordFailureStopsAndDeletesPartialOutput() async throws {
        let fixture = try fixture()
        fixture.nextRecorder.startsSuccessfully = false
        let engine = try fixture.makeEngine()
        XCTAssertThrowsError(try engine.startRecording())
        XCTAssertEqual(fixture.nextRecorder.events, ["prepare", "record", "stop", "delete"])
        XCTAssertNil(fixture.nextRecorder.delegate)
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.errorMessage, AudioRecorder.RecordingError.failedToStart.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.nextRecorder.outputURL).path))
        XCTAssertFalse(try manifestExists(fixture))
    }

    @MainActor
    func testStartAndStopAreIdempotentAndCaptureTimeBeforeStop() async throws {
        let fixture = try fixture()
        let fake = fixture.nextRecorder
        let engine = try fixture.makeEngine()
        engine.courseCode = "  CS182\n"
        try engine.startRecording()
        try engine.startRecording()
        XCTAssertTrue(engine.isRecording)
        XCTAssertEqual(fixture.factoryCalls, 1)
        XCTAssertTrue(try XCTUnwrap(fake.outputURL).lastPathComponent.hasPrefix("CS182_"))
        XCTAssertTrue(fake.delegate === engine)
        XCTAssertEqual(fixture.lastSettings?[AVSampleRateKey] as? Double, 16_000)
        fake.time = 12.75
        engine.stopRecording()
        engine.stopRecording()
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.duration, 12.75)
        XCTAssertEqual(fake.time, 0, "The fake resets time during stop, like the native recorder can.")
        XCTAssertEqual(fake.events.filter { $0 == "stop" }.count, 1)
        XCTAssertNil(fake.delegate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fake.outputURL).path))
        XCTAssertTrue(try manifestExists(fixture))
    }

    @MainActor
    func testDurationTimerUpdatesAndStopsWithRecording() async throws {
        let fixture = try fixture()
        let fake = fixture.nextRecorder
        let engine = try fixture.makeEngine()
        try engine.startRecording()
        fake.time = 3.25
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(engine.duration, 3.25)
        fake.time = 4.5
        engine.stopRecording()
        fake.time = 99
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(engine.duration, 4.5)
        XCTAssertFalse(engine.isRecording)
    }

    @MainActor
    func testSuccessfulAndUnsuccessfulCompletionStopActiveSession() async throws {
        for success in [true, false] {
            let fixture = try fixture()
            let engine = try fixture.makeEngine()
            try engine.startRecording()
            engine.finishRecording(identity: ObjectIdentifier(fixture.nextRecorder), successfully: success)
            XCTAssertFalse(engine.isRecording)
            XCTAssertEqual(fixture.nextRecorder.events.filter { $0 == "stop" }.count, 1)
            XCTAssertEqual(engine.errorMessage, success ? nil : AudioRecorder.RecordingError.recordingFailed.localizedDescription)
            XCTAssertEqual(try manifestExists(fixture), success)
        }
    }

    @MainActor
    func testEncodingFailureClosesActiveSessionAndPreservesMessage() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        try engine.startRecording()
        engine.failEncoding(identity: ObjectIdentifier(fixture.nextRecorder), message: "Simulated encoder failure")
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.errorMessage, "Simulated encoder failure")
        XCTAssertNil(fixture.nextRecorder.delegate)
        XCTAssertFalse(try manifestExists(fixture))
    }

    @MainActor
    func testStaleCallbacksDoNotStopANewerRecording() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        let oldRecorder = fixture.nextRecorder
        try engine.startRecording()
        engine.stopRecording()
        fixture.nextRecorder = FakeRecording()
        engine.courseCode = "CS183"
        try engine.startRecording()
        engine.finishRecording(identity: ObjectIdentifier(oldRecorder), successfully: false)
        engine.failEncoding(identity: ObjectIdentifier(oldRecorder), message: "stale failure")
        XCTAssertTrue(engine.isRecording)
        XCTAssertNil(engine.errorMessage)
        XCTAssertEqual(engine.duration, 0)
        engine.stopRecording()
    }

    @MainActor
    func testTerminationNotificationSynchronouslyStopsRecorder() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        try engine.startRecording()
        fixture.nextRecorder.time = 8.5
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(engine.duration, 8.5)
        XCTAssertNil(fixture.nextRecorder.delegate)
        XCTAssertEqual(fixture.nextRecorder.events.filter { $0 == "stop" }.count, 1)
        XCTAssertTrue(try manifestExists(fixture), "Termination must publish synchronously before the notification returns.")
    }

    @MainActor
    func testReleasingEngineStopsRecorderAndTimerDoesNotRetainIt() async throws {
        let fixture = try fixture()
        var engine: AudioRecorder? = try fixture.makeEngine()
        let weakEngine = WeakReference(engine)
        try engine?.startRecording()
        engine = nil
        XCTAssertNil(weakEngine.value)
        XCTAssertNil(fixture.nextRecorder.delegate)
        XCTAssertEqual(fixture.nextRecorder.events.filter { $0 == "stop" }.count, 1)
        XCTAssertTrue(try manifestExists(fixture))
    }

    @MainActor
    func testRepeatedRecorderLifecyclesReleaseEngineAndTimer() throws {
        let fixture = try fixture()

        // Exercise the same lifecycle used by the menu-bar app repeatedly. A
        // timer, notification registration, delegate, or recorder retained by
        // a previous instance would make one of these weak references survive
        // its scope and would also leave duplicate stop calls behind.
        for index in 0..<25 {
            fixture.nextRecorder = FakeRecording()
            var engine: AudioRecorder? = try fixture.makeEngine()
            engine?.courseCode = "LCPSTRESS\(index)"
            let weakEngine = WeakReference(engine)
            try engine?.startRecording()
            engine?.stopRecording()
            engine = nil

            XCTAssertNil(weakEngine.value, "Recorder instance \(index) was retained")
            XCTAssertEqual(
                fixture.nextRecorder.events.filter { $0 == "stop" }.count,
                1,
                "Recorder instance \(index) was stopped more than once"
            )
            XCTAssertNil(fixture.nextRecorder.delegate)
        }
    }

    @MainActor
    func testManifestAppearsOnlyAfterStopAndHashesFlushedBytes() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        try engine.startRecording()
        let audio = try XCTUnwrap(fixture.nextRecorder.outputURL)
        XCTAssertFalse(try manifestExists(fixture))
        let flushedBytes = Data("final bytes flushed".utf8)
        fixture.nextRecorder.onStop = {
            do { try flushedBytes.write(to: audio) }
            catch { XCTFail("Fake recorder could not flush: \(error)") }
        }

        engine.stopRecording()

        let ready = RecordingManifest.readyURL(for: audio)
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: ready))
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.filename, audio.lastPathComponent)
        XCTAssertEqual(manifest.sizeBytes, UInt64(flushedBytes.count))
        XCTAssertEqual(manifest.sha256, "7c27f68c6d3f26d3efdf64624cd5d14aa6b98b9e9d05343c42f1ad3e7bb90739")
        XCTAssertNil(engine.errorMessage)
    }

    @MainActor
    func testDeferredFinalizationWaitsForClosedAudioAndBlocksSecondStart() throws {
        let fixture = try fixture()
        fixture.nextRecorder.finalizesAsynchronously = true
        let engine = try fixture.makeEngine()
        try engine.startRecording()
        engine.stopRecording()
        engine.stopRecording()
        try engine.startRecording()
        XCTAssertTrue(engine.isFinishing)
        XCTAssertEqual(fixture.factoryCalls, 1)
        XCTAssertEqual(fixture.nextRecorder.events.filter { $0 == "stop" }.count, 1)
        XCTAssertFalse(try manifestExists(fixture))

        let audio = try XCTUnwrap(fixture.nextRecorder.outputURL)
        let finalized = Data("closed recording".utf8)
        try finalized.write(to: audio)
        engine.finishRecording(identity: ObjectIdentifier(fixture.nextRecorder), successfully: true)
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(engine.isFinishing)
        let marker = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: RecordingManifest.readyURL(for: audio)))
        XCTAssertEqual(marker.sizeBytes, UInt64(finalized.count))
    }

    @MainActor
    func testDisconnectedInputDoesNotPublishEvenIfEncoderClosesSuccessfully() throws {
        let fixture = try fixture()
        fixture.nextRecorder.finalizesAsynchronously = true
        let engine = try fixture.makeEngine()
        try engine.startRecording()
        let identity = ObjectIdentifier(fixture.nextRecorder)
        engine.recordingEncodingFailed(identity: identity, message: "Input disconnected")
        engine.stopRecording()
        engine.finishRecording(identity: identity, successfully: true)
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(try manifestExists(fixture))
        XCTAssertEqual(engine.errorMessage, "Input disconnected")
    }

    @MainActor
    func testDelegateFailuresBlockManifestEvenBeforeMainActorCallbackRuns() async throws {
        for encodingError in [false, true] {
            let fixture = try fixture()
            let engine = try fixture.makeEngine()
            try engine.startRecording()
            let identity = ObjectIdentifier(fixture.nextRecorder)
            // These are the exact nonisolated handoffs used by native delegates.
            if encodingError {
                engine.recordingEncodingFailed(identity: identity, message: "encoder failed before stop")
            } else {
                engine.recordingDidFinish(identity: identity, successfully: false)
            }
            // No suspension: the queued main-actor callback has not yet run.
            engine.stopRecording()
            XCTAssertFalse(try manifestExists(fixture))
            XCTAssertNotNil(engine.errorMessage)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.nextRecorder.outputURL).path))
            await Task.yield()
            XCTAssertFalse(try manifestExists(fixture))
        }
    }

    @MainActor
    func testMarkerWriteFailureSurfacesErrorAndPreservesAudio() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        try engine.startRecording()
        let audio = try XCTUnwrap(fixture.nextRecorder.outputURL)
        let original = try Data(contentsOf: audio)
        let ready = RecordingManifest.readyURL(for: audio)
        try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: false)

        engine.stopRecording()

        XCTAssertFalse(engine.isRecording)
        XCTAssertTrue(engine.errorMessage?.contains("Audio was saved, but its completion marker") == true)
        XCTAssertEqual(try Data(contentsOf: audio), original)
        XCTAssertEqual(fixture.nextRecorder.events.filter { $0 == "stop" }.count, 1)
        XCTAssertNil(fixture.nextRecorder.delegate)
    }

    @MainActor
    func testReleaseBeforeFailureUIUpdateDoesNotPublishManifest() async throws {
        let fixture = try fixture()
        var engine: AudioRecorder? = try fixture.makeEngine()
        try engine?.startRecording()
        let weakEngine = WeakReference(engine)
        engine?.recordingEncodingFailed(
            identity: ObjectIdentifier(fixture.nextRecorder),
            message: "encoder failed before release"
        )
        engine = nil
        XCTAssertNil(weakEngine.value)
        XCTAssertFalse(try manifestExists(fixture))
        XCTAssertEqual(fixture.nextRecorder.events.filter { $0 == "stop" }.count, 1)
        await Task.yield()
        XCTAssertFalse(try manifestExists(fixture))
    }

    @MainActor
    func testOrphanedManifestPreventsStartingSameFilename() async throws {
        let fixture = try fixture()
        let engine = try fixture.makeEngine()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        for offset: TimeInterval in [-60, 0, 60] {
            let audio = fixture.manager.stagingDirectory.appendingPathComponent(
                "CS182_\(formatter.string(from: Date().addingTimeInterval(offset))).m4a"
            )
            try Data("stale marker".utf8).write(to: RecordingManifest.readyURL(for: audio))
        }
        XCTAssertThrowsError(try engine.startRecording())
        XCTAssertEqual(fixture.factoryCalls, 0)
        XCTAssertFalse(engine.isRecording)
    }

    @MainActor
    private func manifestExists(_ fixture: RecorderFixture) throws -> Bool {
        let audio = try XCTUnwrap(fixture.nextRecorder.outputURL)
        return FileManager.default.fileExists(atPath: RecordingManifest.readyURL(for: audio).path)
    }

    @MainActor
    private func fixture() throws -> RecorderFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = try IngestManager(stagingDirectory: directory)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return RecorderFixture(manager: manager)
    }
}

@MainActor
private final class RecorderFixture {
    let manager: IngestManager
    var hasUsageDescription = true
    var authorization = AVAuthorizationStatus.authorized
    var accessResult = true
    var accessRequests = 0
    var factoryCalls = 0
    var factoryError: Error?
    var nextRecorder = FakeRecording()
    var lastSettings: [String: Any]?

    init(manager: IngestManager) { self.manager = manager }

    func makeEngine() throws -> AudioRecorder {
        let engine = try AudioRecorder(
            ingestManager: manager,
            dependencies: .init(
                hasMicrophoneUsageDescription: { self.hasUsageDescription },
                authorizationStatus: { self.authorization },
                requestAccess: {
                    self.accessRequests += 1
                    return self.accessResult
                },
                makeRecorder: { url, settings in
                    self.factoryCalls += 1
                    self.lastSettings = settings
                    if let error = self.factoryError { throw error }
                    self.nextRecorder.outputURL = url
                    try Data("test fixture, not audio".utf8).write(to: url)
                    return self.nextRecorder
                }
            )
        )
        engine.courseCode = "CS182"
        return engine
    }
}

private final class FakeRecording: AudioRecording {
    weak var delegate: (any AVAudioRecorderDelegate)?
    var outputURL: URL?
    var preparesSuccessfully = true
    var startsSuccessfully = true
    var finalizesAsynchronously = false
    var time: TimeInterval = 0
    var events: [String] = []
    var onStop: (() -> Void)?
    var currentTime: TimeInterval { time }

    func prepareToRecord() -> Bool {
        events.append("prepare")
        return preparesSuccessfully
    }

    func record() -> Bool {
        events.append("record")
        return startsSuccessfully
    }

    func stop() {
        events.append("stop")
        onStop?()
        time = 0
    }

    func deleteRecording() -> Bool {
        events.append("delete")
        guard let outputURL else { return false }
        do {
            try FileManager.default.removeItem(at: outputURL)
            return true
        } catch {
            return false
        }
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

import AVFoundation
import CryptoKit
import Darwin
import XCTest
@testable import LCPClient

final class CaptureCoordinatorTests: XCTestCase {
    @MainActor
    func testBothHostLaunchOrdersExcludeCompetingRecordings() async throws {
        for firstHost in ["desktop", "legacy"] {
            let root = try temporaryRoot()
            let first = try fixture(root: root, folder: firstHost)
            let second = try fixture(root: root, folder: firstHost == "desktop" ? "legacy" : "desktop")
            try await first.coordinator.start(destinationID: "ICS 46")
            await assertThrows(.captureInUse) { try await second.coordinator.start(destinationID: "ICS 46") }
            XCTAssertEqual(second.recording.starts, 0)
            first.coordinator.stop()
            try await second.coordinator.start(destinationID: "ICS 46")
            second.coordinator.stop()
            XCTAssertNotNil(first.coordinator.lastFinalized)
            XCTAssertNotNil(second.coordinator.lastFinalized)
        }
    }

    @MainActor
    func testSimultaneousHostStartsHaveExactlyOneWinner() async throws {
        let root = try temporaryRoot()
        let first = try fixture(root: root, folder: "desktop")
        let second = try fixture(root: root, folder: "legacy")
        let a = Task { @MainActor in try? await first.coordinator.start(destinationID: "ICS 46") }
        let b = Task { @MainActor in try? await second.coordinator.start(destinationID: "ICS 46") }
        await a.value
        await b.value
        XCTAssertEqual(first.recording.starts + second.recording.starts, 1)
        first.coordinator.stop()
        second.coordinator.stop()
    }

    @MainActor
    func testLeaseHeldThroughEncoderFinalizationAndMarkerCreation() async throws {
        let root = try temporaryRoot()
        let first = try fixture(root: root, folder: "first", asynchronous: true)
        let second = try fixture(root: root, folder: "second")
        var lockWasHeldDuringMarker = false
        first.writeManifest = { url in
            XCTAssertThrowsError(try CaptureLease.acquire(at: first.configuration.leaseURL, sessionID: UUID()))
            lockWasHeldDuringMarker = true
            try RecordingManifest.write(for: url)
        }
        let academicID = UUID()
        try await first.coordinator.start(destinationID: "ICS 46", academicClassID: academicID)
        let session = try XCTUnwrap(first.coordinator.activeSession)
        first.coordinator.stop()
        XCTAssertEqual(first.coordinator.state, .finalizing)
        XCTAssertNotNil(first.coordinator.activeSession)
        XCTAssertNil(first.coordinator.lastFinalized)
        await assertThrows(.captureInUse) { try await second.coordinator.start(destinationID: "ICS 46") }
        first.engine.finishRecording(identity: ObjectIdentifier(first.recording), successfully: true)
        XCTAssertTrue(lockWasHeldDuringMarker)
        let result = try XCTUnwrap(first.coordinator.lastFinalized)
        XCTAssertEqual(result.id, session.id)
        XCTAssertEqual(result.session.academicClassID, academicID)
        XCTAssertEqual(result.session.destination.courseCode, "ICS 46")
        XCTAssertEqual(result.sizeBytes, UInt64(Data("synthetic closed audio".utf8).count))
        XCTAssertEqual(result.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.readyURL.path))
        try await second.coordinator.start(destinationID: "ICS 46")
        second.coordinator.stop()
    }

    @MainActor
    func testMicCheckUsesRealMeterPathAndHandsItsLeaseToRecording() async throws {
        let root = try temporaryRoot()
        let fixture = try fixture(root: root)
        let capture = fixture.coordinator
        let check = UUID()
        try await capture.beginMicrophoneCheck(id: check)
        XCTAssertTrue(capture.isMonitoring)
        XCTAssertNil(capture.activeSession)
        XCTAssertNil(fixture.recording.output)
        XCTAssertEqual(capture.activeMicrophoneName, "Fictional input")
        capture.endMicrophoneCheck(id: UUID())
        XCTAssertTrue(capture.isMonitoring)
        let peer = try self.fixture(root: root, folder: "peer")
        await assertThrows(.captureInUse) { try await peer.coordinator.start(destinationID: "ICS 46") }
        fixture.monitor.sample = CaptureLevels(averageDBFS: -32, peakDBFS: -9)
        for _ in 0..<50 where capture.levels != fixture.monitor.sample { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(capture.levels, fixture.monitor.sample)

        let classID = UUID()
        try await capture.startLocal(academicClassID: classID, className: "Seminar", recordingsDirectory: root.appendingPathComponent("Recordings"))
        XCTAssertFalse(capture.isMonitoring)
        capture.endMicrophoneCheck(id: check)
        XCTAssertEqual(capture.state, .recording)
        fixture.recording.sample = CaptureLevels(averageDBFS: -18, peakDBFS: -2)
        for _ in 0..<50 where capture.levels != fixture.recording.sample { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(capture.levels, fixture.recording.sample)
        capture.stop()
        XCTAssertEqual(capture.lastFinalized?.session.academicClassID, classID)
        XCTAssertNil(capture.levels)
        try await capture.beginMicrophoneCheck(id: check)
        capture.endMicrophoneCheck(id: check)
        XCTAssertFalse(capture.isMonitoring)
        try await peer.coordinator.start(destinationID: "ICS 46")
        peer.coordinator.stop()
    }

    @MainActor
    func testDismissedOrDeniedMicCheckCannotOpenTheInputAfterPermission() async throws {
        let fixture = try fixture()
        let capture = fixture.coordinator
        let id = UUID()
        fixture.authorization = .denied
        await assertThrows(.permissionDenied) { try await capture.beginMicrophoneCheck(id: id) }
        fixture.authorization = .notDetermined
        fixture.onPermission = { capture.endMicrophoneCheck(id: id) }
        do {
            try await capture.beginMicrophoneCheck(id: id)
            XCTFail("A dismissed check started after the microphone prompt.")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.monitorCreations, 0)
        XCTAssertFalse(capture.isMonitoring)
        XCTAssertNil(capture.levels)
    }

    @MainActor
    func testCatalogDestinationFrozenDuringRecordingAndFinalization() async throws {
        let fixture = try fixture(asynchronous: true)
        try await fixture.coordinator.start(destinationID: "ICS 46")
        let session = try XCTUnwrap(fixture.coordinator.activeSession)
        try writeCatalog(at: fixture.configuration.catalogURL, codes: ["Other Class"], now: fixture.now)
        fixture.coordinator.reloadDestinations()
        XCTAssertEqual(fixture.coordinator.activeSession, session)
        XCTAssertEqual(fixture.engine.courseCode, "ICS 46")
        fixture.coordinator.stop()
        await assertThrows(.captureInUse) { try await fixture.coordinator.start(destinationID: "Other Class") }
        fixture.engine.finishRecording(identity: ObjectIdentifier(fixture.recording), successfully: true)
        XCTAssertEqual(fixture.coordinator.lastFinalized?.session.destination.courseCode, "ICS 46")
        XCTAssertTrue(fixture.coordinator.lastFinalized?.filename.hasPrefix("ICS 46_") == true)
    }

    @MainActor
    func testLocalClassWritesVerifiedRecordingWithoutCatalog() async throws {
        let root = try temporaryRoot()
        let fixture = try CoordinatorFixture(root: root, folder: "incoming", asynchronous: false)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let classID = UUID()
        try await fixture.coordinator.startLocal(academicClassID: classID, className: "test", recordingsDirectory: recordings)
        let session = try XCTUnwrap(fixture.coordinator.activeSession)
        XCTAssertEqual(session.academicClassID, classID)
        XCTAssertNil(session.destination.driveFolderID)
        fixture.coordinator.stop()

        let result = try XCTUnwrap(fixture.coordinator.lastFinalized)
        let directory = result.audioURL.deletingLastPathComponent()
        XCTAssertEqual(UUID(uuidString: directory.lastPathComponent), classID)
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path, recordings.standardizedFileURL.path)
        XCTAssertEqual(result.session, session)
        let bytes = try Data(contentsOf: result.audioURL)
        XCTAssertEqual(bytes, Data("synthetic closed audio".utf8))
        let marker = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: result.readyURL))
        XCTAssertEqual(result.readyURL, RecordingManifest.readyURL(for: result.audioURL))
        XCTAssertEqual(marker.filename, result.audioURL.lastPathComponent)
        XCTAssertEqual(result.sha256, marker.sha256)
        XCTAssertEqual(marker.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(marker.sizeBytes, UInt64("synthetic closed audio".utf8.count))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.configuration.stagingDirectory.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.catalogURL.path))

        try writeCatalog(at: fixture.configuration.catalogURL, codes: ["ICS 46"], now: fixture.now, folderID: "mapped")
        try await fixture.coordinator.start(destinationID: "ICS 46", expectedDriveFolderID: "mapped")
        fixture.coordinator.stop()
        let synced = try XCTUnwrap(fixture.coordinator.lastFinalized)
        XCTAssertEqual(synced.session.destination.driveFolderID, "mapped")
        XCTAssertEqual(synced.audioURL.deletingLastPathComponent().standardizedFileURL.path,
                       fixture.configuration.stagingDirectory.standardizedFileURL.path)
    }

    @MainActor
    func testLocalClassUsesSharedLeaseDuringRecordingAndFinalization() async throws {
        let root = try temporaryRoot()
        let desktop = try fixture(root: root, folder: "desktop", asynchronous: true)
        let synced = try fixture(root: root, folder: "legacy")
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        try await desktop.coordinator.startLocal(academicClassID: UUID(), className: "Seminar", recordingsDirectory: recordings)
        await assertThrows(.captureInUse) { try await synced.coordinator.start(destinationID: "ICS 46") }
        desktop.coordinator.stop()
        XCTAssertEqual(desktop.coordinator.state, .finalizing)
        await assertThrows(.captureInUse) { try await synced.coordinator.start(destinationID: "ICS 46") }
        desktop.engine.finishRecording(identity: ObjectIdentifier(desktop.recording), successfully: true)
        XCTAssertNotNil(desktop.coordinator.lastFinalized)
        try await synced.coordinator.start(destinationID: "ICS 46")
        await assertThrows(.captureInUse) {
            try await desktop.coordinator.startLocal(academicClassID: UUID(), className: "Seminar", recordingsDirectory: recordings)
        }
        synced.coordinator.stop()
        let saved = try XCTUnwrap(synced.coordinator.lastFinalized)
        XCTAssertEqual(saved.audioURL.deletingLastPathComponent().standardizedFileURL.path,
                       synced.configuration.stagingDirectory.standardizedFileURL.path)
    }

    @MainActor
    func testLocalClassNamesAndRapidRestartsStayInsideClassDirectory() async throws {
        let root = try temporaryRoot()
        let fixture = try fixture(root: root)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let classID = UUID()
        var urls = Set<URL>()
        for name in ["../哲学: Topics / 物理", "../哲学: Topics / 物理", String(repeating: "🎓", count: 250)] {
            try await fixture.coordinator.startLocal(academicClassID: classID, className: name, recordingsDirectory: recordings)
            fixture.coordinator.stop()
            let saved = try XCTUnwrap(fixture.coordinator.lastFinalized)
            let directory = saved.audioURL.deletingLastPathComponent()
            XCTAssertEqual(UUID(uuidString: directory.lastPathComponent), classID)
            XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path, recordings.standardizedFileURL.path)
            XCTAssertTrue(urls.insert(saved.audioURL).inserted)
            XCTAssertEqual(saved.audioURL.pathExtension, "m4a")
        }
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingManifest.readyURL(for: url).path))
        }
    }

    @MainActor
    func testLocalClassCannotUseSyncedInboxForStorage() async throws {
        let fixture = try fixture()
        let inbox = fixture.configuration.stagingDirectory
        for location in [inbox, inbox.appendingPathComponent("Recordings")] {
            do {
                try await fixture.coordinator.startLocal(academicClassID: UUID(), className: "test", recordingsDirectory: location)
                fixture.coordinator.stop()
                XCTFail("A local recording was admitted into the synced inbox")
            } catch {
                XCTAssertNil(fixture.coordinator.activeSession)
            }
        }
        XCTAssertEqual(fixture.recording.starts, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    @MainActor
    func testLocalStartStillChecksPermissionAndRecorderCompatibility() async throws {
        let root = try temporaryRoot()
        let fixture = try fixture(root: root)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let classID = UUID()
        fixture.authorization = .denied
        await assertThrows(.permissionDenied) {
            try await fixture.coordinator.startLocal(academicClassID: classID, className: "Studio", recordingsDirectory: recordings)
        }
        fixture.authorization = .notDetermined
        fixture.onPermission = { fixture.incompatible = true }
        await assertThrows(.incompatibleRecorder("synthetic incompatible recorder")) {
            try await fixture.coordinator.startLocal(academicClassID: classID, className: "Studio", recordingsDirectory: recordings)
        }
        XCTAssertEqual(fixture.recording.starts, 0)
        XCTAssertNil(fixture.coordinator.lastFinalized)
        let lease = try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID())
        lease.release()
    }

    @MainActor
    func testSyncedStartRequiresFreshCatalogAndKnownDestination() async throws {
        let fixture = try fixture()
        await assertThrows(.invalidDestination) { try await fixture.coordinator.start(destinationID: "My organizer class") }
        try writeCatalog(at: fixture.configuration.catalogURL, codes: ["ICS 46"], now: fixture.now.addingTimeInterval(-86_401))
        do {
            try await fixture.coordinator.start(destinationID: "ICS 46")
            XCTFail("Expired catalog admitted capture")
        } catch { XCTAssertEqual(error as? ClassManifestError, .staleManifest) }
        XCTAssertEqual(fixture.recording.starts, 0)
        XCTAssertFalse(fixture.coordinator.catalogIsUsable)
    }

    @MainActor
    func testReservedTestFolderIsNeverAProductionDestination() async throws {
        let fixture = try fixture()
        try writeCatalog(at: fixture.configuration.catalogURL, codes: ["ICS 46", "LCP Test"], now: fixture.now)
        fixture.coordinator.reloadDestinations()
        XCTAssertEqual(fixture.coordinator.destinations.map(\.id), ["ICS 46"])
        await assertThrows(.invalidDestination) { try await fixture.coordinator.start(destinationID: "LCP Test") }
    }

    @MainActor
    func testCatalogReloadedAfterPermissionPrompt() async throws {
        let fixture = try fixture()
        fixture.authorization = .notDetermined
        fixture.onPermission = {
            try self.writeCatalog(at: fixture.configuration.catalogURL, codes: ["Other Class"], now: fixture.now)
        }
        await assertThrows(.invalidDestination) { try await fixture.coordinator.start(destinationID: "ICS 46") }
        XCTAssertEqual(fixture.recording.starts, 0)
        let lease = try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID())
        lease.release()
    }

    @MainActor
    func testCompatibilityRecheckedAfterPermissionPrompt() async throws {
        let fixture = try fixture()
        fixture.authorization = .notDetermined
        fixture.onPermission = { fixture.incompatible = true }
        do {
            try await fixture.coordinator.start(destinationID: "ICS 46")
            XCTFail("New incompatible process admitted capture")
        } catch { XCTAssertTrue(error is CaptureError) }
        XCTAssertEqual(fixture.recording.starts, 0)
        let lease = try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID())
        lease.release()
    }

    @MainActor
    func testRecreatedSameNameFolderRequiresExplicitRemapping() async throws {
        let fixture = try fixture()
        try writeCatalog(at: fixture.configuration.catalogURL, codes: ["ICS 46"], now: fixture.now, folderID: "replacement")
        await assertThrows(.destinationChanged) {
            try await fixture.coordinator.start(destinationID: "ICS 46", academicClassID: UUID(), expectedDriveFolderID: "original")
        }
        XCTAssertEqual(fixture.recording.starts, 0)
        try await fixture.coordinator.start(destinationID: "ICS 46", academicClassID: UUID(), expectedDriveFolderID: "replacement")
        XCTAssertEqual(fixture.coordinator.activeSession?.destination.driveFolderID, "replacement")
        fixture.coordinator.stop()
    }

    @MainActor
    func testFolderMappingRecheckedAfterPermissionPrompt() async throws {
        let fixture = try fixture()
        try writeCatalog(at: fixture.configuration.catalogURL, codes: ["ICS 46"], now: fixture.now, folderID: "original")
        fixture.authorization = .notDetermined
        fixture.onPermission = {
            try self.writeCatalog(at: fixture.configuration.catalogURL, codes: ["ICS 46"], now: fixture.now, folderID: "replacement")
        }
        await assertThrows(.destinationChanged) {
            try await fixture.coordinator.start(destinationID: "ICS 46", academicClassID: UUID(), expectedDriveFolderID: "original")
        }
        XCTAssertEqual(fixture.recording.starts, 0)
        let lease = try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID())
        lease.release()
    }

    @MainActor
    func testDeniedPermissionAndStartFailureReleaseLease() async throws {
        let fixture = try fixture()
        fixture.authorization = .denied
        await assertThrows(.permissionDenied) { try await fixture.coordinator.start(destinationID: "ICS 46") }
        XCTAssertNil(fixture.coordinator.activeSession)
        fixture.authorization = .authorized
        fixture.recording.preparesSuccessfully = false
        do { try await fixture.coordinator.start(destinationID: "ICS 46"); XCTFail("Unexpected successful start") } catch {}
        let lease = try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID())
        lease.release()
        XCTAssertNil(fixture.coordinator.lastFinalized)
    }

    @MainActor
    func testMarkerFailureAndEncodingFailureReleaseLeaseWithoutIdentity() async throws {
        for markerFailure in [true, false] {
            let fixture = try fixture(asynchronous: true)
            if markerFailure { fixture.writeManifest = { _ in throw CocoaError(.fileWriteNoPermission) } }
            try await fixture.coordinator.start(destinationID: "ICS 46")
            fixture.coordinator.stop()
            fixture.engine.finishRecording(identity: ObjectIdentifier(fixture.recording), successfully: markerFailure)
            XCTAssertEqual(fixture.coordinator.state, .blocked)
            XCTAssertNil(fixture.coordinator.lastFinalized)
            XCTAssertNil(fixture.coordinator.activeSession)
            let lease = try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID())
            lease.release()
        }
    }

    @MainActor
    func testWindowOwnerReleaseDoesNotReleaseActiveLeaseBeforeFinalization() async throws {
        let fixture = try fixture(asynchronous: true)
        var coordinator: CaptureCoordinator? = fixture.makeCoordinator()
        let retained = CoordinatorWeakReference(coordinator)
        try await coordinator?.start(destinationID: "ICS 46")
        coordinator = nil
        XCTAssertNotNil(retained.value)
        XCTAssertThrowsError(try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID()))
        fixture.engine.finishRecording(identity: ObjectIdentifier(fixture.recording), successfully: true)
        XCTAssertNil(retained.value)
        let lease = try CaptureLease.acquire(at: fixture.configuration.leaseURL, sessionID: UUID())
        lease.release()
    }

    func testStaleOwnerTextAndRepeatedReleaseDoNotBlockNewLease() throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("capture.lock")
        try Data("obsolete dead owner".utf8).write(to: url)
        let first = try CaptureLease.acquire(at: url, sessionID: UUID())
        XCTAssertThrowsError(try CaptureLease.acquire(at: url, sessionID: UUID()))
        first.release()
        first.release()
        let second = try CaptureLease.acquire(at: url, sessionID: UUID())
        second.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Do not unlink the shared lock inode")
    }

    func testKernelReclaimsLeaseAfterChildProcessDies() throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("capture.lock")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "open my $fh, '>>', $ARGV[0] or die; flock($fh, 2) or die; $|=1; print qq(locked\\n); <STDIN>;", url.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let ready = try output.fileHandleForReading.read(upToCount: 7)
        XCTAssertEqual(ready, Data("locked\n".utf8))
        XCTAssertThrowsError(try CaptureLease.acquire(at: url, sessionID: UUID()))
        process.terminate()
        process.waitUntilExit()
        let recovered = try CaptureLease.acquire(at: url, sessionID: UUID())
        recovered.release()
    }

    func testKnownIncompatibleInstallAndRunningVersionBlockPreflight() throws {
        let root = try temporaryRoot()
        let app = root.appendingPathComponent("LCP Recorder.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.lcp.Recorder"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try CaptureCompatibility.check(installedBundles: [app], processes: []))
        XCTAssertThrowsError(try CaptureCompatibility.check(installedBundles: [], processes: [.init(processID: 42, protocolMetadata: nil)]))
        let compatible: [String: Any] = ["LCPCaptureProtocolVersion": 1, "LCPCaptureLeaseIdentifier": "org.lcp.capture.v1"]
        XCTAssertNoThrow(try CaptureCompatibility.check(installedBundles: [], processes: [.init(processID: 43, protocolMetadata: compatible)]))
        try PropertyListSerialization.data(fromPropertyList: compatible, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try CaptureCompatibility.check(installedBundles: [app], processes: []), "Unsigned compatibility metadata cannot certify an installed app")
    }

    func testLeaseRejectsSymlinkWithoutModifyingTarget() throws {
        let root = try temporaryRoot()
        let target = root.appendingPathComponent("unrelated")
        let original = Data("keep".utf8)
        try original.write(to: target)
        let link = root.appendingPathComponent("capture.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CaptureLease.acquire(at: link, sessionID: UUID()))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testCompatibleSignedFixtureAndRunningCodeMetadataValidate() throws {
        let root = try temporaryRoot()
        let app = root.appendingPathComponent("Synthetic.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/SyntheticCaptureFixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let metadata: [String: Any] = [
            "CFBundleIdentifier": "org.lcp.SyntheticCaptureFixture", "CFBundleExecutable": executable.lastPathComponent,
            "CFBundlePackageType": "APPL", "LCPCaptureProtocolVersion": 1,
            "LCPCaptureLeaseIdentifier": "org.lcp.capture.v1"
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", app.path]
        signer.standardError = Pipe()
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        XCTAssertNoThrow(try CaptureCompatibility.check(installedBundles: [app], processes: []))

        // This disposable signed command only waits. It never initializes LCP,
        // AppKit, the microphone, a live bundle, or any production directory.
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["30"]
        try helper.run()
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        let runningMetadata = try XCTUnwrap(CaptureCompatibility.signedMetadata(processID: helper.processIdentifier))
        XCTAssertNoThrow(try CaptureCompatibility.check(installedBundles: [], processes: [
            .init(processID: helper.processIdentifier, protocolMetadata: runningMetadata)
        ]))
        XCTAssertEqual(runningMetadata["CFBundleIdentifier"] as? String, "org.lcp.SyntheticCaptureFixture")
        try Data("invalidated installed signature".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try CaptureCompatibility.check(installedBundles: [app], processes: []))
        XCTAssertNil(CaptureCompatibility.signedMetadata(processID: helper.processIdentifier),
                     "Modified on-disk metadata must not certify a still-running process")
    }

    @MainActor
    private func fixture(root: URL? = nil, folder: String = "capture", asynchronous: Bool = false) throws -> CoordinatorFixture {
        let root = try root ?? temporaryRoot()
        let fixture = try CoordinatorFixture(root: root, folder: folder, asynchronous: asynchronous)
        try writeCatalog(at: fixture.configuration.catalogURL, codes: ["ICS 46"], now: fixture.now)
        return fixture
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeCatalog(at url: URL, codes: [String], now: Date, folderID: String? = nil) throws {
        let entries = try codes.map { try LectureClass(name: $0, driveFolderID: folderID) }
        let manifest = try LectureClassManifest(generatedAt: now, rootFolderID: "synthetic", classes: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    @MainActor
    private func assertThrows(_ expected: CaptureError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? CaptureError, expected) }
    }
}

@MainActor
private final class CoordinatorFixture {
    let configuration: CaptureConfiguration
    let now = Date(timeIntervalSince1970: 1_795_132_800)
    var authorization = AVAuthorizationStatus.authorized
    var onPermission: (() throws -> Void)?
    var incompatible = false
    var writeManifest: (URL) throws -> Void = { try RecordingManifest.write(for: $0) }
    let recording = CoordinatorFakeRecording()
    let monitor = CoordinatorFakeRecording()
    var monitorCreations = 0
    lazy var engine: AudioRecorder = {
        try! AudioRecorder(ingestManager: IngestManager(stagingDirectory: configuration.stagingDirectory), dependencies: .init(
            hasMicrophoneUsageDescription: { true }, authorizationStatus: { self.authorization },
            requestAccess: {
                await MainActor.run {
                    try? self.onPermission?()
                    self.authorization = .authorized
                    return true
                }
            },
            makeRecorder: { url, _ in
                self.recording.output = url
                try Data("synthetic closed audio".utf8).write(to: url)
                return self.recording
            }, writeManifest: { try self.writeManifest($0) },
            makeMicrophone: { _, url, _, _, _ in
                XCTAssertNil(url)
                self.monitorCreations += 1
                return (self.monitor, "Fictional input")
            }
        ))
    }()
    lazy var coordinator = makeCoordinator()

    init(root: URL, folder: String, asynchronous: Bool) throws {
        configuration = CaptureConfiguration(stagingDirectory: root.appendingPathComponent(folder),
            catalogURL: root.appendingPathComponent("classes.json"), leaseURL: root.appendingPathComponent("capture.lock"), legacyBundleURLs: [])
        recording.finalizesAsynchronously = asynchronous
    }

    func makeCoordinator() -> CaptureCoordinator {
        CaptureCoordinator(engine: engine, configuration: configuration,
                           compatibilityCheck: { if self.incompatible { throw CaptureError.incompatibleRecorder("synthetic incompatible recorder") } },
                           now: { self.now })
    }
}

private final class CoordinatorFakeRecording: MeteredAudioRecording {
    weak var delegate: (any AVAudioRecorderDelegate)?
    var currentTime: TimeInterval = 4
    var finalizesAsynchronously = false
    var preparesSuccessfully = true
    var output: URL?
    var starts = 0
    var sample: CaptureLevels?
    func sampleAudioLevels() -> CaptureLevels? { sample }
    func prepareToRecord() -> Bool { preparesSuccessfully }
    func record() -> Bool { starts += 1; return true }
    func stop() {}
    func deleteRecording() -> Bool { if let output { try? FileManager.default.removeItem(at: output) }; return true }
}

private final class CoordinatorWeakReference {
    weak var value: CaptureCoordinator?
    init(_ value: CaptureCoordinator?) { self.value = value }
}

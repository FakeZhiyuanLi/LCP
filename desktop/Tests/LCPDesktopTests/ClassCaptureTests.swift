import AVFoundation
import XCTest
@testable import LCPClient
import LCPContextCore
@testable import LCPDesktop

@MainActor
final class ClassCaptureTests: XCTestCase {
    func testClassCaptureKeepsItsOwnerAndUsesOnlyItsVerifiedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(arguments: ["--profile-root", root.appendingPathComponent("Library").path])
        let config = CaptureConfiguration(stagingDirectory: root.appendingPathComponent("Incoming"),
            catalogURL: root.appendingPathComponent("classes.json"), leaseURL: root.appendingPathComponent("capture.lock"), legacyBundleURLs: [])
        let recorder = try AudioRecorder(ingestManager: IngestManager(stagingDirectory: config.stagingDirectory),
            dependencies: .init(hasMicrophoneUsageDescription: { true }, authorizationStatus: { .authorized },
                requestAccess: { false }, makeRecorder: { url, _ in
                    try Data("Fictional lecture".utf8).write(to: url)
                    return SyntheticClassRecorder()
                }))
        let coordinator = CaptureCoordinator(engine: recorder, configuration: config, compatibilityCheck: {})
        model.initializeCapture { coordinator }

        let mapping = RecordingDestination(driveFolderID: "saved-folder", exactCourseCode: "Seminar")
        let localClass = ClassEnrollment(title: "Seminar")
        let syncedClass = ClassEnrollment(title: "Seminar", recordingDestination: mapping)
        model.mutate { $0.classes = [localClass, syncedClass] }
        func writeCatalog(folderID: String) throws {
            let manifest = try LectureClassManifest(generatedAt: .now, rootFolderID: "fictional-root",
                classes: [try LectureClass(name: "Seminar", driveFolderID: folderID)])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: config.catalogURL, options: .atomic)
        }
        try writeCatalog(folderID: mapping.driveFolderID)
        model.selection = .classDetail(localClass.id)
        try await model.startLectureCapture(for: localClass.id, route: .classDefault)
        XCTAssertNil(coordinator.activeSession?.destination.driveFolderID)
        model.selection = .classDetail(syncedClass.id)
        do {
            try await model.startLectureCapture(for: syncedClass.id, route: .classDefault)
            XCTFail("Another class took over an active recording")
        } catch { XCTAssertEqual(error as? CaptureError, .captureInUse) }
        model.selection = .capture
        XCTAssertEqual(model.captureClassID, localClass.id)
        coordinator.stop()
        XCTAssertEqual(model.state.recordings.map(\.classID), [localClass.id])
        let first = try XCTUnwrap(coordinator.lastFinalized)
        XCTAssertTrue(first.audioURL.path.hasPrefix(model.rootURL.appendingPathComponent("Recordings").path + "/"))

        try await model.startLectureCapture(for: syncedClass.id, route: .classDefault)
        XCTAssertEqual(coordinator.activeSession?.destination.driveFolderID, mapping.driveFolderID)
        coordinator.stop()
        XCTAssertEqual(coordinator.lastFinalized?.audioURL.deletingLastPathComponent().path, config.stagingDirectory.path)
        XCTAssertEqual(coordinator.lastFinalized?.session.academicClassID, syncedClass.id)

        // Same course name, different Drive identity. The class tab can still record locally.
        try writeCatalog(folderID: "replacement-folder")
        try await model.startLectureCapture(for: syncedClass.id, route: .classDefault)
        XCTAssertNil(coordinator.activeSession?.destination.driveFolderID)
        coordinator.stop()
        XCTAssertEqual(coordinator.lastFinalized?.session.academicClassID, syncedClass.id)
        XCTAssertEqual(model.state.recordings.filter { $0.classID == syncedClass.id }.count, 2)
        XCTAssertEqual(model.state.classes.first { $0.id == syncedClass.id }?.recordingDestination, mapping)
    }
}

private final class SyntheticClassRecorder: AudioRecording {
    weak var delegate: (any AVAudioRecorderDelegate)?
    var currentTime: TimeInterval { 1 }
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { true }
    func stop() {}
    func deleteRecording() -> Bool { true }
}

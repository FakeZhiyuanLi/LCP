import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LCPContextCore

final class BackgroundBackupTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, ContextRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LCPBackgroundBackup-\(UUID())")
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // A sparse fictional input keeps setup inexpensive while exercising real streaming.
        let source = root.appendingPathComponent("fictional.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data()))
        let file = try FileHandle(forWritingTo: source)
        let size: UInt64 = 64 * 1_024 * 1_024
        try file.truncate(atOffset: size)
        try file.close()
        var hash = SHA256()
        let block = Data(repeating: 0, count: 1_024 * 1_024)
        for _ in 0..<64 { hash.update(data: block) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let row = LectureRecording(filename: "fictional.m4a", sizeBytes: size, sha256: digest, localAudioPath: source.path)
        try repository.update { $0.recordings.append(row) }
        return (root, repository)
    }

    @MainActor private func waitForAudioStaging(under root: URL, prefix: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            if contents.contains(where: {
                $0.lastPathComponent.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("audio").path)
            }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("The main actor could not observe in-progress audio staging.")
        throw CocoaError(.fileReadUnknown)
    }

    private func assertLiveLockAvailable(_ root: URL) throws {
        let fd = open(root.appendingPathComponent("transaction.lock").path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "Audio streaming held the live transaction lock.")
    }

    @MainActor func testExportSnapshotsBeforeConcurrentEditAndRestorePreservesNewerEdit() async throws {
        let (root, library) = try fixture()
        let backup = root.appendingPathComponent("backup")
        let originalRevision = library.state.revision
        let export = Task { try await library.exportBackupInBackground(to: backup, includingLinkedAudio: true) }
        try await waitForAudioStaging(under: root, prefix: ".lcp-backup-")
        try assertLiveLockAvailable(library.rootURL)
        let peer = try ContextRepository(rootURL: library.rootURL)
        try peer.update { $0.terms.append(AcademicTerm(name: "After the snapshot")) }
        try await export.value
        let snapshot = try JSONDecoder().decode(ContextState.self, from: Data(contentsOf: backup.appendingPathComponent("context.json")))
        XCTAssertEqual(snapshot.revision, originalRevision)
        XCTAssertTrue(snapshot.terms.isEmpty)
        try library.refresh()
        XCTAssertEqual(library.state.terms.count, 1)

        let expectedRevision = library.state.revision
        let restore = Task { try await library.restoreBackupInBackground(from: backup, expectedRevision: expectedRevision) }
        try await waitForAudioStaging(under: library.rootURL, prefix: ".restore-")
        try assertLiveLockAvailable(library.rootURL)
        try peer.update { $0.terms.append(AcademicTerm(name: "After restore confirmation")) }
        do { try await restore.value; XCTFail("Restore overwrote a concurrent edit.") }
        catch { XCTAssertEqual(error as? ContextRepositoryError, .libraryChangedDuringRestore) }
        try library.refresh()
        XCTAssertEqual(library.state, peer.state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent("backups").path))
        try await library.restoreBackupInBackground(from: backup, expectedRevision: library.state.revision)
        XCTAssertTrue(library.state.terms.isEmpty)
        let path = try XCTUnwrap(library.state.recordings.first?.localAudioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    @MainActor func testCancelDuringAudioExportCleansPrivateStage() async throws {
        let (root, library) = try fixture()
        let before = library.state
        let backup = root.appendingPathComponent("cancelled")
        let task = Task { try await library.exportBackupInBackground(to: backup, includingLinkedAudio: true) }
        try await waitForAudioStaging(under: root, prefix: ".lcp-backup-")
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export was published.") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lcp-backup-") })
        try library.refresh()
        XCTAssertEqual(library.state, before)
    }

    @MainActor func testRestoreRechecksAdmissionAfterValidationAndBeforeAnyLiveReplacement() async throws {
        enum DraftOpened: Error { case duringValidation }
        let (root, library) = try fixture()
        let backup = root.appendingPathComponent("backup")
        try await library.exportBackupInBackground(to: backup, includingLinkedAudio: true)
        try library.update { $0.terms.append(AcademicTerm(name: "Keep this term")) }
        let before = library.state
        do {
            try await library.restoreBackupInBackground(from: backup, expectedRevision: before.revision) {
                throw DraftOpened.duringValidation
            }
            XCTFail("A rejected final admission committed a restore.")
        } catch DraftOpened.duringValidation {}
        try library.refresh()
        XCTAssertEqual(library.state, before)
        let files = try FileManager.default.contentsOfDirectory(atPath: library.rootURL.path)
        XCTAssertFalse(files.contains("backups"))
        XCTAssertFalse(files.contains("recording-audio"))
        XCTAssertFalse(files.contains { $0.hasPrefix(".restore-") })
    }
}

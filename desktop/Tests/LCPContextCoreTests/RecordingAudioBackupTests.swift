import CryptoKit
import XCTest
import LCPContextCore

@MainActor
final class RecordingAudioBackupTests: XCTestCase {
    private let bytes = Data("Fictional recorded content".utf8)
    private let manager = FileManager.default

    private func fixture() throws -> (URL, URL, ContextRepository, LectureRecording) {
        let root = manager.temporaryDirectory.appendingPathComponent("lcp-audio-backup-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("fictional-local-path.m4a")
        try bytes.write(to: original)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let linked = LectureRecording(filename: "Fictional A.m4a", sizeBytes: UInt64(bytes.count),
                                      sha256: digest, localAudioPath: original.path)
        let unlinked = LectureRecording(filename: "Fictional B.m4a", sizeBytes: UInt64(bytes.count), sha256: digest)
        let repo = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        try repo.update { $0.recordings.append(contentsOf: [linked, unlinked]) }
        return (root, original, repo, linked)
    }

    private func manifest(at backup: URL) throws -> ContextBackupManifest {
        try JSONDecoder().decode(ContextBackupManifest.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
    }

    func testOptInRestoresManagedBytesAfterRemovingOriginalAndBackup() async throws {
        let (root, original, repo, linked) = try fixture()
        var duplicate = linked
        duplicate.id = UUID()
        duplicate.filename = "Fictional second capture.m4a"
        try repo.update { $0.recordings.append(duplicate) }
        let backup = root.appendingPathComponent("portable")
        try repo.exportBackup(to: backup, includingLinkedAudio: true)
        let manifest = try manifest(at: backup)
        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.includedAudioRecordingIDs, [linked.id, duplicate.id])
        XCTAssertEqual(manifest.omittedAudio, ["Fictional B.m4a"])
        XCTAssertFalse(manifest.exclusions.contains("raw audio"))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: backup.appendingPathComponent("audio").path), [linked.sha256 + ".m4a"])
        let context = try JSONDecoder().decode(ContextState.self, from: Data(contentsOf: backup.appendingPathComponent("context.json")))
        XCTAssertTrue(context.recordings.allSatisfy { $0.localAudioPath == nil })
        XCTAssertEqual(repo.state.recordings.first?.localAudioPath, original.path)
        try manager.removeItem(at: original)
        let restored = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        try restored.restoreBackup(from: backup)
        let managedPath = try XCTUnwrap(restored.state.recordings[0].localAudioPath)
        XCTAssertTrue(managedPath.hasPrefix(restored.rootURL.path + "/"))
        XCTAssertEqual(restored.state.recordings[2].localAudioPath, managedPath)
        XCTAssertNil(restored.state.recordings[1].localAudioPath)
        // Reusing or repairing a managed copy must not change its stable path.
        try Data([1]).write(to: URL(fileURLWithPath: managedPath))
        try restored.restoreBackup(from: backup)
        try manager.removeItem(at: backup)
        let reopened = try ContextRepository(rootURL: restored.rootURL)
        var expected = linked
        expected.localAudioPath = managedPath
        XCTAssertEqual(reopened.state.recordings.first, expected)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: managedPath)), bytes)
    }

    func testPrivatePreRestoreRecoveryRetainsHealthyManagedAudioAndListsOmissions() async throws {
        let (root, original, repo, linked) = try fixture()
        let backup = root.appendingPathComponent("with-audio")
        let plain = root.appendingPathComponent("plain")
        let missingBytes = Data("Fictional lost audio".utf8)
        let lostSource = root.appendingPathComponent("lost-original.m4a")
        try missingBytes.write(to: lostSource)
        let missingDigest = SHA256.hash(data: missingBytes).map { String(format: "%02x", $0) }.joined()
        let lost = LectureRecording(filename: "Fictional lost.m4a", sizeBytes: UInt64(missingBytes.count),
                                    sha256: missingDigest, localAudioPath: lostSource.path)
        try repo.update { $0.recordings.append(lost) }
        try repo.exportBackup(to: backup, includingLinkedAudio: true)
        try repo.exportBackup(to: plain)
        let store = try ContextRepository(rootURL: root.appendingPathComponent("working"))
        try store.restoreBackup(from: backup)
        let lostLocal = try XCTUnwrap(store.state.recordings.first { $0.id == lost.id }?.localAudioPath)
        try manager.removeItem(atPath: lostLocal)
        // The second row links to outside storage and has the same content as
        // the managed first row. Recovery must preserve the scope per row.
        try store.update { $0.recordings[1].localAudioPath = original.path }
        let recoveryFolder = store.rootURL.appendingPathComponent("backups")
        let oldNames = Set(try manager.contentsOfDirectory(atPath: recoveryFolder.path))
        try store.restoreBackup(from: plain)
        let newNames = Set(try manager.contentsOfDirectory(atPath: recoveryFolder.path)).subtracting(oldNames)
        XCTAssertEqual(newNames.count, 1)
        let backupURL = recoveryFolder.appendingPathComponent(try XCTUnwrap(newNames.first))
        let recovery = try manifest(at: backupURL)
        XCTAssertEqual(recovery.includedAudioRecordingIDs, [linked.id])
        XCTAssertEqual(recovery.omittedAudio, ["Fictional B.m4a", lost.filename])
        try manager.removeItem(at: backup)
        try manager.removeItem(at: original)
        let recovered = try ContextRepository(rootURL: root.appendingPathComponent("recovered"))
        try recovered.restoreBackup(from: backupURL)
        let restoredPath = try XCTUnwrap(recovered.state.recordings[0].localAudioPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restoredPath)), bytes)
        XCTAssertNil(recovered.state.recordings[1].localAudioPath)
        XCTAssertNil(recovered.state.recordings[2].localAudioPath)
    }

    func testDefaultOmissionWorksEvenWithMissingLinkAndLegacyManifest() async throws {
        let (root, original, repo, linked) = try fixture()
        try manager.removeItem(at: original)
        let backup = root.appendingPathComponent("default")
        try repo.exportBackup(to: backup)
        let manifest = try manifest(at: backup)
        XCTAssertEqual(manifest.version, 1)
        XCTAssertTrue(manifest.exclusions.contains("raw audio"))
        XCTAssertEqual(manifest.omittedAudio, [linked.filename, "Fictional B.m4a"])
        XCTAssertNil(manifest.includedAudioRecordingIDs)
        XCTAssertFalse(manager.fileExists(atPath: backup.appendingPathComponent("audio").path))
        // Actual pre-v7 manifests named only recordings with local links.
        let manifestURL = backup.appendingPathComponent("manifest.json")
        var legacy = manifest
        legacy.omittedAudio = [linked.filename]
        legacy.omittedTranscriptCaches = nil
        try JSONEncoder().encode(legacy).write(to: manifestURL)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        try offline.restoreBackup(from: backup)
        XCTAssertNil(offline.state.recordings[0].localAudioPath)
        XCTAssertEqual(offline.state.recordings[0].id, linked.id)
    }

    func testChangedMissingAndSymlinkedLinksFailOptInWithoutPublishingBackup() async throws {
        let (root, original, repo, linked) = try fixture()
        let backup = root.appendingPathComponent("portable")
        func check() throws {
            XCTAssertThrowsError(try repo.exportBackup(to: backup, includingLinkedAudio: true)) {
                XCTAssertEqual($0 as? ContextRepositoryError, .unavailableBackupAudio(linked.filename))
            }
            XCTAssertFalse(manager.fileExists(atPath: backup.path))
            XCTAssertFalse(try manager.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lcp-backup-") })
        }
        try Data(repeating: 0, count: bytes.count).write(to: original)
        try check()
        try manager.removeItem(at: original)
        try check()
        let other = root.appendingPathComponent("correct-bytes")
        try bytes.write(to: other)
        try manager.createSymbolicLink(at: original, withDestinationURL: other)
        try check()
    }

    func testOversizedRecordingDoesNotProduceAnAudioBackup() async throws {
        let (root, original, repo, _) = try fixture()
        let oversized = LectureRecording(filename: "Oversized.m4a", sizeBytes: 512 * 1_024 * 1_024 + 1,
                                        sha256: String(repeating: "c", count: 64), localAudioPath: original.path)
        try repo.update { $0.recordings.append(oversized) }
        let backup = root.appendingPathComponent("oversized")
        XCTAssertThrowsError(try repo.exportBackup(to: backup, includingLinkedAudio: true)) {
            XCTAssertEqual($0 as? ContextRepositoryError, .unavailableBackupAudio(oversized.filename))
        }
        XCTAssertFalse(manager.fileExists(atPath: backup.path))
    }

    func testManagedAudioDirectorySymlinkCannotRedirectARestore() async throws {
        let (root, _, repo, linked) = try fixture()
        let backup = root.appendingPathComponent("portable")
        try repo.exportBackup(to: backup, includingLinkedAudio: true)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        let before = offline.state
        let unrelated = root.appendingPathComponent("unrelated")
        try manager.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let sentinel = unrelated.appendingPathComponent(linked.sha256 + ".m4a")
        let preserved = Data("Fictional unrelated file".utf8)
        try preserved.write(to: sentinel)
        try manager.createSymbolicLink(at: offline.rootURL.appendingPathComponent("recording-audio"), withDestinationURL: unrelated)
        XCTAssertThrowsError(try offline.restoreBackup(from: backup))
        XCTAssertEqual(try Data(contentsOf: sentinel), preserved)
        try offline.refresh()
        XCTAssertEqual(offline.state, before)
    }

    func testIncompleteMalformedAndFutureAudioBackupsLeaveDestinationAlone() async throws {
        let (root, original, repo, linked) = try fixture()
        let backup = root.appendingPathComponent("portable")
        try repo.exportBackup(to: backup, includingLinkedAudio: true)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("offline"))
        let before = offline.state
        let blob = backup.appendingPathComponent("audio").appendingPathComponent(linked.sha256 + ".m4a")
        let manifestURL = backup.appendingPathComponent("manifest.json")
        let validManifest = try manifest(at: backup)
        func check() throws {
            XCTAssertThrowsError(try offline.restoreBackup(from: backup))
            try offline.refresh()
            XCTAssertEqual(offline.state, before)
            XCTAssertFalse(manager.fileExists(atPath: offline.rootURL.appendingPathComponent("recording-audio").path))
            XCTAssertFalse(manager.fileExists(atPath: offline.rootURL.appendingPathComponent("backups").path))
        }
        try manager.removeItem(at: blob)
        try check()
        try manager.createSymbolicLink(at: blob, withDestinationURL: original)
        try check()
        try manager.removeItem(at: blob)
        try Data(repeating: 0, count: bytes.count).write(to: blob)
        try check()
        try bytes.write(to: blob)
        for selection: [UUID]? in [nil, [], [UUID()], [linked.id, linked.id]] {
            var altered = validManifest
            altered.includedAudioRecordingIDs = selection
            try JSONEncoder().encode(altered).write(to: manifestURL)
            try check()
        }
        var altered = validManifest
        altered.version = 1
        try JSONEncoder().encode(altered).write(to: manifestURL)
        try check()
        altered.version = 3
        try JSONEncoder().encode(altered).write(to: manifestURL)
        try check()
    }
}

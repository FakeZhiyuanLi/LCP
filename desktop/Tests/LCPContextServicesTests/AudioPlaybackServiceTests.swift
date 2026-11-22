import XCTest
import CryptoKit
import AVFoundation
import LCPContextCore
@testable import LCPContextServices

final class AudioPlaybackServiceTests: XCTestCase {
    func testExplicitIdentityVerificationDoesNotStartPlayback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-audio-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("Fictional bytes; this test never decodes or plays audio.".utf8); try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let recording = LectureRecording(filename: "fictional.m4a", sizeBytes: UInt64(bytes.count), sha256: digest)
        let verified = try await AudioPlaybackService.verifyAudio(url: url, recording: recording); XCTAssertEqual(verified, bytes)
        var wrongSize = recording; wrongSize.sizeBytes += 1
        do { _ = try await AudioPlaybackService.verifyAudio(url: url, recording: wrongSize); XCTFail("wrong size accepted") }
        catch { XCTAssertEqual(error as? AudioPlaybackError, .sizeMismatch) }
        var wrongHash = recording; wrongHash.sha256 = String(repeating: "0", count: 64)
        do { _ = try await AudioPlaybackService.verifyAudio(url: url, recording: wrongHash); XCTFail("wrong digest accepted") }
        catch { XCTAssertEqual(error as? AudioPlaybackError, .digestMismatch) }
    }
    func testMissingAndSymlinkAudioAreRejected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-audio-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = LectureRecording(filename: "fictional.m4a", sizeBytes: 10, sha256: String(repeating: "0", count: 64))
        do { _ = try await AudioPlaybackService.verifyAudio(url: url, recording: recording); XCTFail("missing accepted") }
        catch { XCTAssertEqual(error as? AudioPlaybackError, .missingAudio) }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        do { _ = try await AudioPlaybackService.verifyAudio(url: url, recording: recording); XCTFail("symlink accepted") }
        catch { XCTAssertEqual(error as? AudioPlaybackError, .missingAudio) }
    }
    @MainActor
    func testVerifiedSyntheticAACLoadsAndSeeksExactCueWithoutPlaying() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcp-silent-audio-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilentAAC(to: url)
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let recording = LectureRecording(filename: url.lastPathComponent, sizeBytes: UInt64(data.count), sha256: digest)
        let playback = AudioPlaybackService()
        try await playback.load(url: url, recording: recording)
        XCTAssertEqual(playback.recordingID, recording.id)
        XCTAssertGreaterThan(playback.duration, 0.9)
        try playback.seek(to: 0.375)
        XCTAssertEqual(playback.currentTime, 0.375, accuracy: 0.001)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertThrowsError(try playback.seek(to: -1))
        XCTAssertThrowsError(try playback.seek(to: .nan))
        XCTAssertThrowsError(try playback.seek(to: playback.duration + 1))
        playback.stop()
        XCTAssertEqual(playback.currentTime, 0)
    }
    @MainActor
    func testAudioIncludedBackupLoadsAndSeeksAfterSourcesAreRemoved() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("lcp-offline-audio-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let original = root.appendingPathComponent("fictional.m4a")
        try writeSilentAAC(to: original)
        let data = try Data(contentsOf: original)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let recording = LectureRecording(filename: original.lastPathComponent, sizeBytes: UInt64(data.count),
                                         sha256: digest, localAudioPath: original.path)
        let repository = try ContextRepository(rootURL: root.appendingPathComponent("library"))
        try repository.update { $0.recordings.append(recording) }
        let backup = root.appendingPathComponent("portable")
        try repository.exportBackup(to: backup, includingLinkedAudio: true)
        try manager.removeItem(at: original)
        let offline = try ContextRepository(rootURL: root.appendingPathComponent("restored"))
        try offline.restoreBackup(from: backup)
        try manager.removeItem(at: backup)
        let restored = try XCTUnwrap(offline.state.recordings.first)
        let managed = try XCTUnwrap(restored.localAudioPath)
        let playback = AudioPlaybackService()
        try await playback.load(url: URL(fileURLWithPath: managed), recording: restored)
        XCTAssertEqual(playback.recordingID, recording.id)
        XCTAssertGreaterThan(playback.duration, 0.9)
        try playback.seek(to: 0.375)
        XCTAssertEqual(playback.currentTime, 0.375, accuracy: 0.001)
        XCTAssertFalse(playback.isPlaying)
    }

    private func writeSilentAAC(to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 16_000))
        pcm.frameLength = 16_000
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            buffer.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
        }
        try writer.write(from: pcm)
    }

}

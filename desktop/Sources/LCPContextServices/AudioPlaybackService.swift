import Foundation
import AVFoundation
import Combine
import CryptoKit
import Darwin
import LCPContextCore

public enum AudioPlaybackError: Error, LocalizedError, Equatable {
    case missingAudio
    case unsafeFile
    case sizeMismatch
    case digestMismatch
    case unsupportedAudio
    case invalidTime
    case notLoaded
    case superseded
    public var errorDescription: String? {
        switch self {
        case .missingAudio: return "Audio is unavailable locally. You can continue reading the transcript."
        case .unsafeFile: return "Select a regular local audio file of at most 512 MiB."
        case .sizeMismatch: return "The selected audio file has a different byte count from this recording."
        case .digestMismatch: return "The selected audio file does not match this recording's SHA-256."
        case .unsupportedAudio: return "The verified file could not be decoded for playback."
        case .invalidTime: return "This cue time is outside the available local audio."
        case .notLoaded: return "Select and verify local audio before playback."
        case .superseded: return "A newer audio selection replaced this one."
        }
    }
}

/// Playback never opens a microphone or invents a remote URL. AVAudioPlayer is
/// initialized with the exact bytes whose identity was verified, so replacing
/// the selected path after hashing cannot change what is played.
@MainActor
public final class AudioPlaybackService: ObservableObject {
    @Published public private(set) var status = "Audio not selected"
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var recordingID: UUID?
    private var player: AVAudioPlayer?
    private var playbackMonitor: Task<Void, Never>?
    private var loadID = UUID()

    public init() {}
    deinit { playbackMonitor?.cancel() }

    public func load(url: URL, recording: LectureRecording) async throws {
        stop()
        player = nil; duration = 0; recordingID = nil
        let selection = UUID(); loadID = selection
        status = "Verifying local audio…"
        do {
            let data = try await Self.verifyAudio(url: url, recording: recording)
            guard selection == loadID else { throw AudioPlaybackError.superseded }
            let candidate: AVAudioPlayer
            do { candidate = try AVAudioPlayer(data: data) }
            catch { throw AudioPlaybackError.unsupportedAudio }
            guard candidate.duration.isFinite, candidate.duration > 0, candidate.prepareToPlay() else {
                throw AudioPlaybackError.unsupportedAudio
            }
            player = candidate; duration = candidate.duration; recordingID = recording.id
            status = "Local audio verified"
        } catch {
            if selection == loadID { status = error.localizedDescription }
            throw error
        }
    }

    public func play(from time: TimeInterval? = nil) throws {
        guard let player else { throw AudioPlaybackError.notLoaded }
        if let time { try seek(to: time) }
        guard player.play() else { throw AudioPlaybackError.unsupportedAudio }
        isPlaying = true; status = "Playing verified local audio"
        playbackMonitor?.cancel()
        playbackMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                // Acquire self only after sleeping. Nothing retains the service
                // across the suspension; deinit cancels the Sendable task handle.
                guard let self else { return }
                self.refreshPlayback()
                if !self.isPlaying { return }
            }
        }
    }

    public func pause() {
        player?.pause(); playbackMonitor?.cancel(); playbackMonitor = nil
        currentTime = player?.currentTime ?? 0; isPlaying = false
        if player != nil { status = "Paused" }
    }

    public func stop() {
        loadID = UUID()
        player?.stop(); player?.currentTime = 0
        playbackMonitor?.cancel(); playbackMonitor = nil; currentTime = 0; isPlaying = false
        if player != nil { status = "Stopped" }
    }

    public func seek(to time: TimeInterval) throws {
        guard let player else { throw AudioPlaybackError.notLoaded }
        guard time.isFinite, time >= 0, time <= player.duration else { throw AudioPlaybackError.invalidTime }
        player.currentTime = time; currentTime = time
    }

    private func refreshPlayback() {
        guard let player else { return }
        currentTime = player.currentTime; isPlaying = player.isPlaying
        if !isPlaying { playbackMonitor?.cancel(); playbackMonitor = nil; status = "Playback finished" }
    }

    /// Shared identity verification, useful for relinking without starting audio.
    /// This reads only the explicitly selected file on a background task.
    public nonisolated static func verifyAudio(url: URL, recording: LectureRecording) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try readVerifiedAudio(url: url, size: recording.sizeBytes, digest: recording.sha256)
        }.value
    }

    private nonisolated static func readVerifiedAudio(url: URL, size: UInt64, digest: String) throws -> Data {
        guard url.isFileURL else { throw AudioPlaybackError.unsafeFile }
        guard size > 0, size <= 512 * 1_024 * 1_024 else { throw AudioPlaybackError.unsafeFile }
        let file = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw AudioPlaybackError.missingAudio }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw AudioPlaybackError.unsafeFile }
        guard before.st_size >= 0, UInt64(before.st_size) == size else { throw AudioPlaybackError.sizeMismatch }
        var data = Data(); data.reserveCapacity(Int(size))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw AudioPlaybackError.missingAudio }
            if count == 0 { break }
            guard data.count <= Int(size) - count else { throw AudioPlaybackError.sizeMismatch }
            let chunk = Data(buffer.prefix(count)); data.append(chunk); hasher.update(data: chunk)
        }
        var after = stat()
        guard fstat(file, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(size) else { throw AudioPlaybackError.sizeMismatch }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw AudioPlaybackError.digestMismatch }
        return data
    }
}

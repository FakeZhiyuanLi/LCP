import CryptoKit
import Darwin
import Foundation

/// Audio blobs are named only by a validated recording digest. The portable
/// state never contains the original path or a path chosen by a backup writer.
enum RecordingAudioBackup {
    // Same individual limit as AudioPlaybackService. Cap total stream work as
    // well, including recordings that happen to link to identical content.
    private static let maximumFileBytes: UInt64 = 512 * 1_024 * 1_024
    private static let maximumTotalBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024
    private static let directoryName = "audio"

    enum Scope {
        case omit
        case linked
        case managedRecovery(URL)
    }

    static func export(_ recordings: [LectureRecording], to staging: URL, scope: Scope) throws -> [LectureRecording] {
        let candidates: [LectureRecording]
        let managed: Int32
        switch scope {
        case .omit: return []
        case .linked:
            candidates = recordings.filter { $0.localAudioPath != nil }
            managed = -1
        case .managedRecovery(let root):
            // A private rollback keeps verified app-managed media without ever
            // importing external files merely because the user chose Restore.
            let directory = root.appendingPathComponent("recording-audio", isDirectory: true)
            candidates = recordings.filter { $0.localAudioPath == file(for: $0, in: directory).path }
            managed = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard managed >= 0 else { return [] }
        }
        defer { if managed >= 0 { close(managed) } }
        try checkBounds(candidates)
        guard !candidates.isEmpty else { return [] }
        let directory = staging.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var included: [LectureRecording] = []
        var written: Set<String> = []
        for recording in candidates {
            guard let path = recording.localAudioPath, path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw ContextRepositoryError.unavailableBackupAudio(recording.filename)
            }
            let output = written.contains(recording.sha256) ? nil : file(for: recording, in: directory)
            // Verify every linked source before accepting it as an inclusion,
            // including two distinct recordings with the same content digest.
            let inputName = managed >= 0 ? file(for: recording, in: directory).lastPathComponent : path
            let fd = openat(managed >= 0 ? managed : AT_FDCWD, inputName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            do {
                guard fd >= 0 else { throw ContextRepositoryError.unavailableBackupAudio(recording.filename) }
                try copyVerified(fd, recording: recording, to: output?.path)
                written.insert(recording.sha256)
                included.append(recording)
            } catch ContextRepositoryError.unavailableBackupAudio where managed >= 0 {
                // The original can already be missing or damaged. Keep the
                // other managed recordings and list this omission explicitly.
                if let output, FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
            }
        }
        return included
    }

    static func selections(in manifest: ContextBackupManifest, recordings: [LectureRecording]) throws -> [LectureRecording] {
        guard recordings.allSatisfy({ $0.localAudioPath == nil }) else { throw ContextRepositoryError.invalidBackup }
        if manifest.version == 1 {
            guard manifest.includedAudioRecordingIDs == nil else { throw ContextRepositoryError.invalidBackup }
            return []
        }
        guard let ids = manifest.includedAudioRecordingIDs, ids.count <= recordings.count else {
            throw ContextRepositoryError.invalidBackup
        }
        let selected = Set(ids)
        let included = recordings.filter { selected.contains($0.id) }
        let omitted = recordings.filter { !selected.contains($0.id) }.map(\.filename)
        guard included.count == ids.count, selected.count == ids.count, omitted.sorted() == manifest.omittedAudio.sorted() else {
            throw ContextRepositoryError.invalidBackup
        }
        try checkBounds(included)
        return included
    }

    /// Copy verified bytes out of the user-selected backup before acquiring the
    /// live write lock. The backup may be on removable storage or change later.
    static func stage(_ recordings: [LectureRecording], from backup: URL, in staging: URL) throws {
        guard !recordings.isEmpty else { return }
        let sourceRoot = open(backup.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceRoot >= 0 else { throw ContextRepositoryError.invalidBackup }
        defer { close(sourceRoot) }
        let source = openat(sourceRoot, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw ContextRepositoryError.invalidBackup }
        defer { close(source) }
        let directory = staging.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var staged: Set<String> = []
        for recording in recordings where staged.insert(recording.sha256).inserted {
            let target = file(for: recording, in: directory)
            let fd = openat(source, target.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ContextRepositoryError.invalidBackup }
            try copyVerified(fd, recording: recording, to: target.path)
        }
    }

    /// Publish each immutable blob before the single SwiftData commit. Repeated
    /// restores reuse its address; an interrupted commit cannot expose partial
    /// media through existing paths. A verified backup can repair damaged blobs.
    static func install(_ recordings: [LectureRecording], stagedIn staging: URL, under root: URL) throws -> [UUID: String] {
        guard !recordings.isEmpty else { return [:] }
        let directory = root.appendingPathComponent("recording-audio", isDirectory: true)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let managed = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard managed >= 0 else { throw ContextRepositoryError.unsafePath }
        defer { close(managed) }
        let staged = staging.appendingPathComponent(directoryName, isDirectory: true)
        let verified = open(staged.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard verified >= 0 else { throw ContextRepositoryError.invalidBackup }
        defer { close(verified) }
        var installed: Set<String> = []
        var paths: [UUID: String] = [:]
        for recording in recordings {
            let destination = file(for: recording, in: directory)
            if installed.insert(recording.sha256).inserted {
                // The private staging directory is on the profile volume.
                // Moving verified content permits a short atomic commit even
                // for large backups imported from removable media.
                let name = destination.lastPathComponent
                guard renameat(verified, name, managed, name) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            paths[recording.id] = destination.path
        }
        return paths
    }

    private static func file(for recording: LectureRecording, in directory: URL) -> URL {
        directory.appendingPathComponent(recording.sha256 + ".m4a")
    }

    private static func checkBounds(_ recordings: [LectureRecording]) throws {
        var total: UInt64 = 0
        var sizes: [String: UInt64] = [:]
        for recording in recordings {
            let digest = recording.sha256.utf8
            guard digest.count == 64, digest.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  recording.sizeBytes > 0, recording.sizeBytes <= maximumFileBytes,
                  recording.sizeBytes <= maximumTotalBytes - total,
                  sizes[recording.sha256].map({ $0 == recording.sizeBytes }) ?? true else {
                throw ContextRepositoryError.unavailableBackupAudio(recording.filename)
            }
            sizes[recording.sha256] = recording.sizeBytes
            total += recording.sizeBytes
        }
    }

    private static func copyVerified(_ fd: Int32, recording: LectureRecording, to output: String?) throws {
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, UInt64(before.st_size) == recording.sizeBytes else {
            throw ContextRepositoryError.unavailableBackupAudio(recording.filename)
        }
        var destination: FileHandle?
        if let output {
            let target = open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            destination = FileHandle(fileDescriptor: target, closeOnDealloc: true)
        }
        defer { try? destination?.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while let chunk = try input.read(upToCount: 512 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard UInt64(chunk.count) <= recording.sizeBytes - size else {
                throw ContextRepositoryError.unavailableBackupAudio(recording.filename)
            }
            size += UInt64(chunk.count)
            hasher.update(data: chunk)
            try destination?.write(contentsOf: chunk)
        }
        var after = stat()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == recording.sizeBytes, digest == recording.sha256, fstat(fd, &after) == 0,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw ContextRepositoryError.unavailableBackupAudio(recording.filename)
        }
        try destination?.close()
        destination = nil
    }
}

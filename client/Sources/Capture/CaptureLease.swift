import Darwin
import Foundation

/// Never unlink this file: every supported host must lock the same inode.
/// The kernel releases flock on process exit, so stale owner text is harmless.
final class CaptureLease {
    private let descriptor: Int32
    private let mutex = NSLock()
    private var released = false

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(at url: URL, sessionID: UUID) throws -> CaptureLease {
        guard url.isFileURL else { throw CaptureError.invalidConfiguration }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CaptureError.leaseUnavailable }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw CaptureError.leaseUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw CaptureError.captureInUse }
            throw CaptureError.leaseUnavailable
        }
        let lease = CaptureLease(descriptor: descriptor)
        do {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw CaptureError.leaseUnavailable }
            let owner = Owner(protocolVersion: 1, processID: getpid(), sessionID: sessionID, acquiredAt: Date())
            let data = try JSONEncoder().encode(owner)
            guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw CaptureError.leaseUnavailable
            }
            try data.withUnsafeBytes { bytes in
                var count = 0
                while count < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw CaptureError.leaseUnavailable }
                    count += written
                }
            }
            guard fsync(descriptor) == 0 else { throw CaptureError.leaseUnavailable }
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    deinit { release() }

    private struct Owner: Codable {
        let protocolVersion: Int
        let processID: Int32
        let sessionID: UUID
        let acquiredAt: Date
    }
}

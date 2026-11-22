import CryptoKit
import Foundation

/// Syncthing may copy an open recording. Only this verified sidecar marks it complete.
struct RecordingManifest: Codable, Equatable {
    let version: Int
    let filename: String
    let sizeBytes: UInt64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case version, filename, sha256
        case sizeBytes = "size_bytes"
    }

    static func readyURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("ready.json")
    }

    /// Call only after the recorder has flushed and closed the AAC container.
    /// Hash in bounded chunks so a long lecture never needs to fit in memory.
    @discardableResult
    static func write(for audioURL: URL) throws -> URL {
        let initial = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        guard initial[.type] as? FileAttributeType == .typeRegular else {
            throw ManifestError.invalidRecording
        }

        let handle = try FileHandle(forReadingFrom: audioURL)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
            size += UInt64(chunk.count)
        }

        let final = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        guard size > 0,
              (final[.size] as? NSNumber)?.uint64Value == size,
              (initial[.size] as? NSNumber)?.uint64Value == size,
              initial[.modificationDate] as? Date == final[.modificationDate] as? Date,
              initial[.systemFileNumber] as? NSNumber == final[.systemFileNumber] as? NSNumber else {
            throw ManifestError.invalidRecording
        }

        let manifest = Self(
            version: 1,
            filename: audioURL.lastPathComponent,
            sizeBytes: size,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()
        )
        let readyURL = readyURL(for: audioURL)
        // A final pathname is visible only once the complete JSON has been written.
        try JSONEncoder().encode(manifest).write(to: readyURL, options: .atomic)
        return readyURL
    }

    private enum ManifestError: LocalizedError {
        case invalidRecording

        var errorDescription: String? {
            "The recording is empty or changed while its completion marker was being prepared."
        }
    }
}

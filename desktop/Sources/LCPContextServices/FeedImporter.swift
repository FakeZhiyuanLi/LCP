import Foundation
import CryptoKit
import Darwin
import LCPContextCore

public struct FeedImportResult: Equatable, Sendable {
    public let generationID: String
    public let importedRecordings: Int
    public let importedTranscripts: Int
    public let isDuplicate: Bool
    public let exportedAt: Date
    public let isStale: Bool
}

public enum FeedImportError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unsupportedSchema(Int)
    case incomplete(String)
    case changedDuringImport
    case staleGeneration
    case differentProducer
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "The lecture feed is invalid: \(reason)"
        case .unsupportedSchema(let version): return "Lecture feed schema \(version) is not supported. The previous feed is retained."
        case .incomplete(let path): return "The lecture feed is still arriving or is unreadable: \(path). The previous feed is retained."
        case .changedDuringImport: return "The lecture feed changed during validation. Try importing it again."
        case .staleGeneration: return "An older lecture feed cannot replace the current generation."
        case .differentProducer: return "This feed belongs to another producer. Select the configured lecture feed."
        }
    }
}

/// The feed is a read-only input. Every index entry and payload is validated before
/// one repository transaction; missing files never remove the last good generation.
@MainActor
public final class FeedImporter {
    public static var defaultFeedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCP Desktop/Feed", isDirectory: true)
    }
    public static let staleInterval: TimeInterval = 24 * 60 * 60
    private let repository: ContextRepository
    private let now: () -> Date
    public init(repository: ContextRepository, now: @escaping () -> Date = Date.init) {
        self.repository = repository; self.now = now
    }

    @discardableResult
    public func importGeneration(from root: URL) throws -> FeedImportResult {
        // Feed imports run from the main-actor polling timer. Foundation's file
        // and JSON APIs bridge temporary buffers through Objective-C, and the
        // main run loop can otherwise keep those autoreleased `Data` buffers
        // alive across many timer callbacks. Keep each complete import inside a
        // bounded pool so a frequently regenerated feed cannot grow the app's
        // memory footprint with one generation after another.
        try autoreleasepool {
            try importGenerationWithoutAutoreleasePool(from: root)
        }
    }

    @discardableResult
    private func importGenerationWithoutAutoreleasePool(from root: URL) throws -> FeedImportResult {
        try repository.refresh()
        let directory = try FeedDirectory(root)
        let indexData = try directory.readIndex()
        let decoder = JSONDecoder()
        let index: FeedIndex
        do { index = try decoder.decode(FeedIndex.self, from: indexData) }
        catch { throw FeedImportError.invalid("index.json does not match the feed contract") }
        guard index.schemaVersion == 1 else { throw FeedImportError.unsupportedSchema(index.schemaVersion) }
        guard index.complete else { throw FeedImportError.incomplete("index.json") }
        try Self.validateIdentifier(index.generationID, label: "generation ID")
        try Self.validateIdentifier(index.producer.id, label: "producer ID")
        try Self.validateIdentifier(index.producer.environment, label: "producer environment")
        guard let exportedAt = Self.date(index.exportedAt) else { throw FeedImportError.invalid("export time") }
        guard index.recordings.count <= 10_000, index.retirements.count <= 10_000 else {
            throw FeedImportError.invalid("too many recordings")
        }
        let indexDigest = Self.digest(indexData)
        if let current = repository.state.feedGeneration {
            guard current.producer == index.producer.id, current.environment == index.producer.environment else {
                throw FeedImportError.differentProducer
            }
            guard exportedAt >= current.exportedAt else { throw FeedImportError.staleGeneration }
        }
        if let previous = repository.state.feedGenerations.first(where: {
            $0.id == index.generationID && $0.producer == index.producer.id && $0.environment == index.producer.environment
        }), previous.indexSHA256 != indexDigest {
            throw FeedImportError.invalid("a generation ID was reused with different content")
        }

        var identities = Set<SourceIdentity>()
        var prepared: [(FeedRecording, FeedPayload?, Data?)] = []
        var totalBytes = 0
        for recording in index.recordings {
            let identity = try Self.validatedIdentity(recording.filename, recording.sizeBytes, recording.sha256)
            guard identities.insert(identity).inserted else { throw FeedImportError.invalid("duplicate source identity") }
            if let job = recording.acceptedJobID { try Self.validateIdentifier(job, label: "accepted job ID") }
            try Self.validateStatus(recording.status)
            guard let reference = recording.transcript else { prepared.append((recording, nil, nil)); continue }
            guard recording.status.serverReceived,
                  ["eligible", "passed", "accepted"].contains(recording.status.quality) else {
                throw FeedImportError.invalid("transcript content requires a received, quality-eligible source")
            }
            guard let acceptedJobID = recording.acceptedJobID,
                  acceptedJobID == reference.acceptedJobID else {
                throw FeedImportError.invalid("transcript does not match the accepted job")
            }
            guard Self.validDigest(reference.sha256), reference.path == "payloads/\(reference.sha256).json",
                  reference.sizeBytes > 0, reference.sizeBytes <= FeedDirectory.maximumPayloadBytes else {
                throw FeedImportError.invalid("transcript payload reference")
            }
            totalBytes += reference.sizeBytes
            guard totalBytes <= 256 * 1_024 * 1_024 else { throw FeedImportError.invalid("generation exceeds 256 MiB") }
            let bytes = try directory.readPayload(digest: reference.sha256, expectedSize: reference.sizeBytes)
            guard Self.digest(bytes) == reference.sha256 else { throw FeedImportError.invalid("payload digest mismatch") }
            let payload: FeedPayload
            do { payload = try decoder.decode(FeedPayload.self, from: bytes) }
            catch { throw FeedImportError.invalid("transcript payload does not match the feed contract") }
            guard payload.schemaVersion == 1 else { throw FeedImportError.unsupportedSchema(payload.schemaVersion) }
            guard try Self.validatedIdentity(payload.filename, payload.sizeBytes, payload.sha256) == identity,
                  payload.acceptedJobID == acceptedJobID,
                  Self.date(payload.generatedAt) != nil else {
                throw FeedImportError.invalid("transcript identity or generated time mismatch")
            }
            try Self.validateCues(payload.cues, events: payload.audioEvents)
            prepared.append((recording, payload, bytes))
        }
        var retiredIdentities = Set<SourceIdentity>()
        for retirement in index.retirements {
            let identity = try Self.validatedIdentity(retirement.filename, retirement.sizeBytes, retirement.sha256)
            guard !identities.contains(identity), retiredIdentities.insert(identity).inserted,
                  !retirement.reason.isEmpty, retirement.reason.utf8.count <= 1_024 else {
                throw FeedImportError.invalid("invalid retirement or simultaneous live/retired source")
            }
        }
        // Syncthing may replace index.json while payloads are being read. A stable,
        // complete index is required even when this generation was imported before.
        guard try directory.readIndex() == indexData else { throw FeedImportError.changedDuringImport }
        func hasCurrentContent(_ state: ContextState) -> Bool {
            for (source, payload, _) in prepared {
                guard let recording = state.recordings.first(where: {
                    $0.filename == source.filename && $0.sizeBytes == source.sizeBytes && $0.sha256 == source.sha256
                }) else { return false }
                if payload != nil {
                    guard !recording.retired, recording.status.transcriptAvailable == "available",
                          let revisionID = recording.currentTranscriptRevisionID,
                          let revision = state.transcriptRevisions.first(where: {
                              $0.id == revisionID && $0.recordingID == recording.id &&
                              $0.content.sha256 == source.transcript?.sha256
                          }), (try? repository.payloadData(revision.content)) != nil else { return false }
                }
            }
            return true
        }
        if repository.state.feedGenerations.contains(where: {
            $0.id == index.generationID && $0.producer == index.producer.id && $0.indexSHA256 == indexDigest
        }), hasCurrentContent(repository.state) {
            return FeedImportResult(generationID: index.generationID, importedRecordings: 0,
                                    importedTranscripts: 0, isDuplicate: true, exportedAt: exportedAt,
                                    isStale: now().timeIntervalSince(exportedAt) > Self.staleInterval)
        }
        // Payloads are content addressed. A failed transaction can leave harmless
        // unreferenced bytes, but never a partial academic/read-model generation.
        var payloadReferences: [String: PayloadReference] = [:]
        for (_, payload, data) in prepared {
            if let payload, let data {
                let reference = try repository.storePayload(data, mediaType: "application/vnd.lcp.transcript+json")
                payloadReferences[Self.identityKey(payload.filename, payload.sizeBytes, payload.sha256)] = reference
            }
        }
        guard try directory.readIndex() == indexData else { throw FeedImportError.changedDuringImport }
        var newRecordingCount = 0
        var newTranscriptCount = 0
        var concurrentDuplicate = false
        let importedAt = now()
        try repository.update { state in
            // update reloads the latest cross-process state under the repository
            // lock. Repeat admission checks there, not only against our snapshot.
            if let current = state.feedGeneration {
                guard current.producer == index.producer.id, current.environment == index.producer.environment else {
                    throw FeedImportError.differentProducer
                }
                guard exportedAt >= current.exportedAt else { throw FeedImportError.staleGeneration }
            }
            if let previous = state.feedGenerations.first(where: {
                $0.id == index.generationID && $0.producer == index.producer.id && $0.environment == index.producer.environment
            }) {
                guard previous.indexSHA256 == indexDigest else {
                    throw FeedImportError.invalid("a generation ID was reused with different content")
                }
                if hasCurrentContent(state) {
                    concurrentDuplicate = true
                    return
                }
            }
            for (source, payload, _) in prepared {
                let existingIndex = state.recordings.firstIndex(where: {
                    $0.filename == source.filename && $0.sizeBytes == source.sizeBytes && $0.sha256 == source.sha256
                })
                var recording = existingIndex.map { state.recordings[$0] } ?? LectureRecording(
                    filename: source.filename, sizeBytes: source.sizeBytes, sha256: source.sha256,
                    legacyLocalTimestamp: Self.legacyTimestamp(source.filename))
                recording.acceptedJobID = source.acceptedJobID
                recording.retired = false
                recording.status.serverReceived = source.status.serverReceived ? "received" : "not_received"
                recording.status.processing = source.status.processing
                recording.status.quality = source.status.quality
                recording.status.drivePublication = source.status.drivePublication
                recording.status.externalIngestion = source.status.externalIngestion
                recording.status.transcriptAvailable = payload == nil ? "unavailable" : "available"
                recording.status.observedAt = exportedAt
                // Copying the authoritative existing recording above preserves
                // all authored association facts, including immutable history
                // and an explicitly reviewed nil (unassigned) classID. Neither
                // a repair nor replay may infer a replacement from a filename,
                // historical ledger, or feed status. New sources start unmapped.
                // Local audio and capture instants are local facts as well.
                recording.currentTranscriptRevisionID = nil
                if let payload,
                   let content = payloadReferences[Self.identityKey(source.filename, source.sizeBytes, source.sha256)] {
                    if let existing = state.transcriptRevisions.first(where: {
                        $0.recordingID == recording.id && $0.content.sha256 == content.sha256
                    }) {
                        recording.currentTranscriptRevisionID = existing.id
                    } else {
                        let cues = payload.cues.map { TranscriptCue(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) }
                        let events = payload.audioEvents.map { TranscriptAudioEvent(start: $0.start, end: $0.end, text: $0.text) }
                        let duration = max(cues.map(\.end).max() ?? 0, events.map(\.end).max() ?? 0)
                        let revision = TranscriptRevision(recordingID: recording.id, acceptedJobID: payload.acceptedJobID,
                            content: content, cues: cues, audioEvents: events, createdAt: exportedAt, duration: duration)
                        state.transcriptRevisions.append(revision)
                        recording.currentTranscriptRevisionID = revision.id
                        newTranscriptCount += 1
                    }
                }
                if let existingIndex { state.recordings[existingIndex] = recording }
                else { state.recordings.append(recording); newRecordingCount += 1 }
            }
            for retirement in index.retirements {
                if let offset = state.recordings.firstIndex(where: {
                    $0.filename == retirement.filename && $0.sizeBytes == retirement.sizeBytes && $0.sha256 == retirement.sha256
                }) {
                    state.recordings[offset].retired = true
                    state.recordings[offset].currentTranscriptRevisionID = nil
                    state.recordings[offset].status.transcriptAvailable = "retired"
                    state.recordings[offset].status.observedAt = exportedAt
                }
            }
            let generation = FeedGeneration(id: index.generationID, producer: index.producer.id,
                environment: index.producer.environment, exportedAt: exportedAt, importedAt: importedAt,
                indexSHA256: indexDigest)
            state.feedGeneration = generation
            if !state.feedGenerations.contains(where: {
                $0.id == generation.id && $0.producer == generation.producer && $0.indexSHA256 == generation.indexSHA256
            }) { state.feedGenerations.append(generation) }
        }
        return FeedImportResult(generationID: index.generationID, importedRecordings: newRecordingCount,
                                importedTranscripts: newTranscriptCount, isDuplicate: concurrentDuplicate, exportedAt: exportedAt,
                                isStale: importedAt.timeIntervalSince(exportedAt) > Self.staleInterval)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func identityKey(_ filename: String, _ size: UInt64, _ digest: String) -> String { "\(filename)\u{0}\(size)\u{0}\(digest)" }
    private static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func validateIdentifier(_ value: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw FeedImportError.invalid(label)
        }
    }
    private static func validatedIdentity(_ filename: String, _ size: UInt64, _ digest: String) throws -> SourceIdentity {
        guard !filename.isEmpty, filename.utf8.count <= 512, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              filename.lowercased().hasSuffix(".m4a"), size > 0, size <= 100 * 1_024 * 1_024 * 1_024,
              validDigest(digest) else { throw FeedImportError.invalid("recording source identity") }
        return SourceIdentity(filename: filename, size: size, digest: digest)
    }
    private static func validateStatus(_ status: FeedStatus) throws {
        for value in [status.processing, status.quality, status.drivePublication, status.externalIngestion] {
            guard !value.isEmpty, value.utf8.count <= 256,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw FeedImportError.invalid("status fact")
            }
        }
    }
    private static func validateCues(_ cues: [FeedCue], events: [FeedAudioEvent]) throws {
        guard !cues.isEmpty, cues.count <= 100_000, events.count <= 100_000 else { throw FeedImportError.invalid("cue count") }
        var previous = -Double.infinity
        for cue in cues {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start,
                  cue.start >= previous, cue.end <= 7 * 24 * 60 * 60,
                  !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cue.text.utf8.count <= 1_024 * 1_024,
                  (cue.speaker?.utf8.count ?? 0) <= 256 else { throw FeedImportError.invalid("spoken cue interval/text") }
            previous = cue.start
        }
        var previousEvent = -Double.infinity
        for event in events {
            guard event.start.isFinite, event.end.isFinite, event.start >= 0, event.end >= event.start,
                  event.start >= previousEvent, event.end <= 7 * 24 * 60 * 60,
                  event.text.utf8.count <= 65_536 else { throw FeedImportError.invalid("audio event interval/text") }
            previousEvent = event.start
        }
    }
    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func legacyTimestamp(_ filename: String) -> String? {
        guard let range = filename.range(of: #"_\d{4}-\d{2}-\d{2}_\d{4}\.m4a$"#, options: .regularExpression) else { return nil }
        return String(filename[range].dropFirst().dropLast(4))
    }
}

private struct SourceIdentity: Hashable { let filename: String; let size: UInt64; let digest: String }

private struct FeedIndex: Decodable {
    let schemaVersion: Int; let generationID: String; let exportedAt: String
    let producer: FeedProducer; let complete: Bool; let recordings: [FeedRecording]; let retirements: [FeedRetirement]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", generationID = "generation_id", exportedAt = "exported_at"
        case producer, complete, recordings, retirements
    }
}
private struct FeedProducer: Decodable { let id: String; let environment: String }
private struct FeedRecording: Decodable {
    let filename: String; let sizeBytes: UInt64; let sha256: String; let acceptedJobID: String?
    let status: FeedStatus; let transcript: FeedTranscriptReference?
    enum CodingKeys: String, CodingKey { case filename, sizeBytes = "size_bytes", sha256, acceptedJobID = "accepted_job_id", status, transcript }
}
private struct FeedStatus: Decodable {
    let serverReceived: Bool; let processing: String; let quality: String; let drivePublication: String; let externalIngestion: String
    enum CodingKeys: String, CodingKey { case serverReceived = "server_received", processing, quality, drivePublication = "drive_publication", externalIngestion = "external_ingestion" }
}
private struct FeedTranscriptReference: Decodable {
    let path: String; let sha256: String; let sizeBytes: Int; let acceptedJobID: String
    enum CodingKeys: String, CodingKey { case path, sha256, sizeBytes = "size_bytes", acceptedJobID = "accepted_job_id" }
}
private struct FeedPayload: Decodable {
    let schemaVersion: Int; let filename: String; let sizeBytes: UInt64; let sha256: String; let acceptedJobID: String
    let cues: [FeedCue]; let audioEvents: [FeedAudioEvent]; let generatedAt: String
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", filename, sizeBytes = "size_bytes", sha256, acceptedJobID = "accepted_job_id", cues, audioEvents = "audio_events", generatedAt = "generated_at" }
}
private struct FeedCue: Decodable { let start: Double; let end: Double; let text: String; let speaker: String? }
private struct FeedAudioEvent: Decodable { let start: Double; let end: Double; let text: String }
private struct FeedRetirement: Decodable {
    let filename: String; let sizeBytes: UInt64; let sha256: String; let reason: String
    enum CodingKeys: String, CodingKey { case filename, sizeBytes = "size_bytes", sha256, reason }
}

/// Directory-relative O_NOFOLLOW reads also reject symlinks during a concurrent
/// replacement. Descriptor reads are bounded and rechecked for in-place writes.
private final class FeedDirectory {
    static let maximumPayloadBytes = 32 * 1_024 * 1_024
    private let descriptor: Int32
    init(_ url: URL) throws {
        guard url.isFileURL else { throw FeedImportError.invalid("feed must be a local directory") }
        descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FeedImportError.incomplete("feed directory") }
    }
    deinit { Darwin.close(descriptor) }
    func readIndex() throws -> Data { try read(parent: descriptor, name: "index.json", maximum: 8 * 1_024 * 1_024) }
    func readPayload(digest: String, expectedSize: Int) throws -> Data {
        let payloadDirectory = Darwin.openat(descriptor, "payloads", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard payloadDirectory >= 0 else { throw FeedImportError.incomplete("payloads") }
        defer { Darwin.close(payloadDirectory) }
        let data = try read(parent: payloadDirectory, name: "\(digest).json", maximum: Self.maximumPayloadBytes)
        guard data.count == expectedSize else { throw FeedImportError.invalid("payload size mismatch") }
        return data
    }
    private func read(parent: Int32, name: String, maximum: Int) throws -> Data {
        let file = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw FeedImportError.incomplete(name) }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= maximum else { throw FeedImportError.invalid("bounded regular file required") }
        var bytes = Data(); bytes.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw FeedImportError.incomplete(name) }
            if count == 0 { break }
            guard bytes.count <= maximum - count else { throw FeedImportError.invalid("file exceeds limit") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(file, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              bytes.count == Int(before.st_size) else { throw FeedImportError.changedDuringImport }
        return bytes
    }
}

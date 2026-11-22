import CryptoKit
import Darwin
import Foundation
import SwiftData

public enum ContextRepositoryError: LocalizedError, Equatable {
    case invalidState(String)
    case invalidPayload
    case unsupportedSchema
    case invalidBackup
    case libraryChangedDuringRestore
    case unavailableBackupAudio(String)
    case destinationExists
    case unsafePath
    case lockUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidState(let reason): return "The library could not be saved: \(reason)."
        case .invalidPayload: return "A source payload is missing, changed, or invalid."
        case .unsupportedSchema: return "This library or backup uses an unsupported version."
        case .libraryChangedDuringRestore: return "The library changed after restore was requested. Your newer work was preserved. Review it before restoring again."
        case .invalidBackup: return "The backup is incomplete or invalid. The current library was preserved."
        case .unavailableBackupAudio(let filename): return "The linked audio for \(filename) is unavailable, exceeds backup limits, or does not match its saved identity."
        case .destinationExists: return "Choose a new, empty backup destination."
        case .unsafePath: return "The selected location is not a supported regular file or directory."
        case .lockUnavailable: return "The library transaction lock could not be acquired."
        }
    }
}

// V1 deliberately stores one Codable domain snapshot per transaction. This
// permits reviewable atomic graph validation while the public schema settles.
// Individual indexed relational models can replace it in a versioned migration.
enum ContextSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Snapshot.self] }
    @Model final class Snapshot {
        @Attribute(.unique) var key: String
        var schemaVersion: Int
        var payload: Data
        init(key: String = "library", schemaVersion: Int = 1, payload: Data) {
            self.key = key; self.schemaVersion = schemaVersion; self.payload = payload
        }
    }
}

enum ContextMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ContextSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

public struct ContextBackupManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var createdAt: Date
    public var stateSHA256: String
    public var stateByteCount: UInt64
    public var payloads: [PayloadReference]
    public var omittedAudio: [String]
    public var includedAudioRecordingIDs: [UUID]?
    /// Earlier format-v1 backups did not report individual transcript omissions.
    public var omittedTranscriptCaches: [TranscriptCacheOmission]?
    public var exclusions: [String]
}

public struct TranscriptCacheOmission: Codable, Equatable, Sendable {
    public var recordingID: UUID
    public var revisionID: UUID
    public var payloadSHA256: String
}

public struct TranscriptCacheCleanupResult: Equatable, Sendable {
    public var revisionsRemoved: Int
    public var payloadsRemoved: Int
    public var bytesRemoved: UInt64
}

@MainActor
public final class ContextRepository {
    nonisolated public static let maximumPayloadBytes: UInt64 = 128 * 1_024 * 1_024
    nonisolated public static let maximumStateBytes: UInt64 = 64 * 1_024 * 1_024
    public private(set) var state: ContextState
    public private(set) var unavailablePayloads: [PayloadReference] = []
    nonisolated public let rootURL: URL
    private let container: ModelContainer
    private let lockURL: URL
    nonisolated private var fileManager: FileManager { .default }

    public nonisolated static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCP Desktop", isDirectory: true)
    }

    public init(rootURL: URL = ContextRepository.defaultRootURL) throws {
        let fileManager = FileManager.default
        guard rootURL.isFileURL else { throw ContextRepositoryError.unsafePath }
        self.rootURL = rootURL.standardizedFileURL
        self.lockURL = self.rootURL.appendingPathComponent("transaction.lock")
        self.state = ContextState()
        try Self.ensureDirectory(self.rootURL)
        try Self.ensureDirectory(self.rootURL.appendingPathComponent("payloads", isDirectory: true))
        let storeURL = self.rootURL.appendingPathComponent("Library.store")
        if fileManager.fileExists(atPath: storeURL.path) { try Self.requireRegularFile(storeURL) }
        let versionURL = self.rootURL.appendingPathComponent("schema-version.json")
        if fileManager.fileExists(atPath: versionURL.path) {
            let versionData = try Self.readRegularFile(versionURL, maximum: 1_024)
            guard let version = try? JSONDecoder().decode(Int.self, from: versionData), version == 1 else {
                throw ContextRepositoryError.unsupportedSchema
            }
        }
        // Bootstrap is serialized as well; independent app/stdio processes may
        // open the library at the same time.
        let descriptor = try Self.openLock(self.lockURL)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ContextRepositoryError.lockUnavailable }
        let schema = Schema(versionedSchema: ContextSchemaV1.self)
        let configuration = ModelConfiguration("LCPContext", schema: schema, url: storeURL,
                                               allowsSave: true, cloudKitDatabase: .none)
        self.container = try ModelContainer(for: schema, migrationPlan: ContextMigrationPlan.self,
                                            configurations: [configuration])
        self.state = try readState()
        try Self.validate(self.state, requirePayloadBytes: false, payload: { try self.readPayload($0) })
        self.unavailablePayloads = try Self.allPayloads(self.state).filter { (try? self.readPayload($0)) == nil }
        if !fileManager.fileExists(atPath: versionURL.path) {
            try JSONEncoder().encode(1).write(to: versionURL, options: .atomic)
        }
    }

    /// Re-read through a fresh SwiftData context on each external tool request.
    /// This makes revocation visible across the desktop and its stdio adapter.
    public func refresh() throws {
        try withLock(exclusive: false) {
            let next = try readState()
            try Self.validate(next, requirePayloadBytes: false, payload: { try self.readPayload($0) })
            state = next
            unavailablePayloads = try Self.allPayloads(next).filter { (try? self.readPayload($0)) == nil }
        }
    }

    /// Reload, mutate a value snapshot, validate the entire graph and its bytes,
    /// then save one SwiftData transaction. A throwing mutation never commits.
    public func update(_ mutation: (inout ContextState) throws -> Void) throws {
        try withLock(exclusive: true) {
            let previous = try readState()
            var next = previous
            try mutation(&next)
            try prepareRecordingAssociations(&next, previous: previous)
            try prepareActivities(&next, previous: previous)
            try preserveImmutableHistory(previous: previous, next: next)
            for revision in next.materialRevisions where !previous.materialRevisions.contains(where: { $0.id == revision.id }) {
                _ = try readPayload(revision.original)
                if let text = revision.text { _ = try readPayload(text) }
            }
            for revision in next.transcriptRevisions where !previous.transcriptRevisions.contains(where: { $0.id == revision.id }) {
                _ = try readPayload(revision.content)
            }
            try pinCitations(&next, previous: previous)
            try Self.validate(next, requirePayloadBytes: false, payload: { try self.readPayload($0) })
            let (revision, overflow) = previous.revision.addingReportingOverflow(1)
            guard !overflow else { throw ContextRepositoryError.invalidState("revision overflow") }
            next.revision = revision
            try writeState(next)
            state = next
            unavailablePayloads = try Self.allPayloads(next).filter { (try? self.readPayload($0)) == nil }
        }
    }

    public func storePayload(_ data: Data, mediaType: String = "application/octet-stream") throws -> PayloadReference {
        try withLock(exclusive: true) { try writePayload(data, mediaType: mediaType) }
    }

    public func payloadData(_ reference: PayloadReference) throws -> Data { try readPayload(reference) }

    public func payloadURL(_ reference: PayloadReference) throws -> URL {
        _ = try readPayload(reference)
        return payloadPath(reference)
    }

    public func exportBackup(to destination: URL, includingLinkedAudio: Bool = false) throws {
        let snapshot = try withLock(exclusive: false) { try readState() }
        try exportUnlocked(snapshot, to: destination, audioScope: includingLinkedAudio ? .linked : .omit)
    }

    public func exportBackupInBackground(to destination: URL, includingLinkedAudio: Bool = false) async throws {
        let snapshot = try withLock(exclusive: false) { try readState() }
        try await Self.backgroundIO {
            try self.exportUnlocked(snapshot, to: destination, audioScope: includingLinkedAudio ? .linked : .omit)
        }
    }

    private static func backgroundIO<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    /// The only operation permitted to retire immutable transcript cache rows.
    /// Authored references and explicit pins keep their exact revisions. Store
    /// metadata commits before file cleanup; a failed deletion only leaves an orphan.
    @discardableResult
    public func purgeUnpinnedTranscriptCaches() throws -> TranscriptCacheCleanupResult {
        try withLock(exclusive: true) {
            let previous = try readState()
            var next = previous
            let removed = try removeUnpinnedTranscriptRows(from: &next, original: previous)
            guard previous.revision < UInt64.max else { throw ContextRepositoryError.invalidState("revision overflow") }
            next.revision = previous.revision + 1
            try Self.validate(next, requirePayloadBytes: false, payload: { try self.readPayload($0) })
            let surviving = Set(try Self.allPayloads(next).map(\.sha256))
            try writeState(next)
            state = next
            var result = TranscriptCacheCleanupResult(revisionsRemoved: removed.count, payloadsRemoved: 0, bytesRemoved: 0)
            var visited: Set<String> = []
            for revision in removed where !surviving.contains(revision.content.sha256) && visited.insert(revision.content.sha256).inserted {
                let path = payloadPath(revision.content)
                if (try? Self.requireRegularFile(path)) != nil, (try? fileManager.removeItem(at: path)) != nil {
                    result.payloadsRemoved += 1; result.bytesRemoved += revision.content.byteCount
                }
            }
            unavailablePayloads = try Self.allPayloads(next).filter { (try? self.readPayload($0)) == nil }
            return result
        }
    }

    /// Used for both cache cleanup and portable export. This only edits the value
    /// snapshot; the caller decides whether to commit it and clean up local files.
    nonisolated private func removeUnpinnedTranscriptRows(from state: inout ContextState, original: ContextState) throws -> [TranscriptRevision] {
        try pinCitations(&state, previous: original)
        let pins = Set(state.pinnedPayloads.map(\.sha256))
        let removed = state.transcriptRevisions.filter { !pins.contains($0.content.sha256) }
        let removedIDs = Set(removed.map(\.id))
        state.transcriptRevisions.removeAll { removedIDs.contains($0.id) }
        for index in state.recordings.indices {
            if let current = state.recordings[index].currentTranscriptRevisionID, removedIDs.contains(current) {
                state.recordings[index].currentTranscriptRevisionID = nil
                state.recordings[index].status.transcriptAvailable = "not_cached"
            }
        }
        return removed
    }

    /// Validate and exercise a separate temporary SwiftData store first. Only
    /// then create a pre-restore backup and atomically replace the state graph.
    /// Original payloads remain immutable; no existing payload is removed.
    public func restoreBackup(from source: URL) throws {
        let previous = try withLock(exclusive: false) { try readState() }
        let stage = try restoreStagingStore()
        defer { try? fileManager.removeItem(at: stage.rootURL) }
        let prepared = try prepareRestore(from: source, previous: previous, stage: stage)
        try commitRestore(prepared, expectedRevision: previous.revision, stagedIn: stage.rootURL)
    }

    public func restoreBackupInBackground(from source: URL, expectedRevision: UInt64,
                                          beforeCommit: @MainActor () throws -> Void = {}) async throws {
        let previous = try withLock(exclusive: false) { try readState() }
        guard previous.revision == expectedRevision else { throw ContextRepositoryError.libraryChangedDuringRestore }
        let stage = try restoreStagingStore()
        defer { try? fileManager.removeItem(at: stage.rootURL) }
        let prepared = try await Self.backgroundIO {
            try self.prepareRestore(from: source, previous: previous, stage: stage)
        }
        try Task.checkCancellation()
        try beforeCommit()
        try commitRestore(prepared, expectedRevision: expectedRevision, stagedIn: stage.rootURL)
    }

    private func restoreStagingStore() throws -> ContextRepository {
        let staging = rootURL.appendingPathComponent(".restore-" + UUID().uuidString, isDirectory: true)
        // Keep verification bytes on the target volume so commit only renames verified files.
        guard mkdir(staging.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { return try ContextRepository(rootURL: staging) }
        catch { try? fileManager.removeItem(at: staging); throw error }
    }

    private struct PreparedRestore: Sendable {
        var state: ContextState
        let references: [PayloadReference]
        let audio: [LectureRecording]
    }

    nonisolated private func prepareRestore(from source: URL, previous: ContextState, stage: ContextRepository) throws -> PreparedRestore {
        let (restored, references, audio) = try Self.readBackup(source)
        try RecordingAudioBackup.stage(audio, from: source, in: stage.rootURL)
        for reference in references {
            try Task.checkCancellation()
            let bytes = try Self.readBackupPayload(reference, root: source)
            _ = try stage.writePayload(bytes, mediaType: reference.mediaType)
        }
        // Exercise the staged SwiftData store using fresh ModelContexts on this
        // executor. Only value records and file URLs leave this preparation step.
        try Self.validate(restored, payload: stage.readPayload)
        try stage.writeState(restored)
        let verified = try stage.readState()
        try Self.validate(verified, payload: stage.readPayload)

        let recovery = stage.rootURL.appendingPathComponent("recovery", isDirectory: true)
        do { try exportUnlocked(previous, to: recovery, includeUnpinnedTranscriptCaches: true, audioScope: .managedRecovery(rootURL)) }
        catch is CancellationError { throw CancellationError() }
        catch { try exportIncompleteRecovery(previous, to: recovery) }
        return PreparedRestore(state: verified, references: references, audio: audio)
    }

    private func commitRestore(_ prepared: PreparedRestore, expectedRevision: UInt64, stagedIn staging: URL) throws {
        try withLock(exclusive: true) {
            guard try readState().revision == expectedRevision else { throw ContextRepositoryError.libraryChangedDuringRestore }
            guard expectedRevision < UInt64.max else { throw ContextRepositoryError.invalidState("revision overflow") }
            let backups = rootURL.appendingPathComponent("backups", isDirectory: true)
            try Self.ensureDirectory(backups)
            let recovery = backups.appendingPathComponent("pre-restore-" + UUID().uuidString, isDirectory: true)
            try fileManager.moveItem(at: staging.appendingPathComponent("recovery"), to: recovery)

            // All bytes and citation relationships were verified in the private
            // stage. Publish each immutable digest with a same-volume atomic rename.
            try Self.requireDirectory(rootURL.appendingPathComponent("payloads"))
            for reference in prepared.references {
                let destination = payloadPath(reference)
                if fileManager.fileExists(atPath: destination.path) { try Self.requireRegularFile(destination) }
                let source = staging.appendingPathComponent("payloads").appendingPathComponent(destination.lastPathComponent)
                guard rename(source.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            let audioPaths = try RecordingAudioBackup.install(prepared.audio, stagedIn: staging, under: rootURL)
            var next = prepared.state
            for index in next.recordings.indices {
                next.recordings[index].localAudioPath = audioPaths[next.recordings[index].id]
            }
            next.grants = []
            next.revision = expectedRevision + 1
            try writeState(next)
            state = next
            unavailablePayloads = []
        }
    }

    private func withLock<T>(exclusive: Bool, _ work: () throws -> T) throws -> T {
        let descriptor = try Self.openLock(lockURL)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw ContextRepositoryError.lockUnavailable }
        return try work()
    }

    nonisolated private static func openLock(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ContextRepositoryError.lockUnavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor); throw ContextRepositoryError.unsafePath
        }
        return descriptor
    }

    nonisolated private func readState() throws -> ContextState {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<ContextSchemaV1.Snapshot>())
        guard rows.count <= 1 else { throw ContextRepositoryError.invalidState("multiple state snapshots") }
        guard let row = rows.first else { return ContextState() }
        guard row.key == "library", row.schemaVersion == ContextState.currentSchemaVersion,
              row.payload.count <= Self.maximumStateBytes else { throw ContextRepositoryError.unsupportedSchema }
        let decoded = try JSONDecoder().decode(ContextState.self, from: row.payload)
        guard decoded.schemaVersion == ContextState.currentSchemaVersion else { throw ContextRepositoryError.unsupportedSchema }
        return decoded
    }

    nonisolated private func writeState(_ next: ContextState) throws {
        let data = try Self.encode(next)
        guard data.count <= Self.maximumStateBytes else { throw ContextRepositoryError.invalidState("library size limit exceeded") }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<ContextSchemaV1.Snapshot>())
        guard rows.count <= 1 else { throw ContextRepositoryError.invalidState("multiple state snapshots") }
        if let row = rows.first { row.payload = data; row.schemaVersion = next.schemaVersion }
        else { context.insert(ContextSchemaV1.Snapshot(payload: data)) }
        try context.save()
    }

    nonisolated private func payloadPath(_ reference: PayloadReference) -> URL {
        rootURL.appendingPathComponent("payloads", isDirectory: true).appendingPathComponent(reference.sha256 + ".blob")
    }

    nonisolated private func readPayload(_ reference: PayloadReference) throws -> Data {
        guard Self.validDigest(reference.sha256), reference.byteCount <= Self.maximumPayloadBytes else {
            throw ContextRepositoryError.invalidPayload
        }
        try Self.requireDirectory(rootURL.appendingPathComponent("payloads", isDirectory: true))
        let data = try Self.readRegularFile(payloadPath(reference), maximum: Self.maximumPayloadBytes)
        guard data.count == reference.byteCount, Self.digest(data) == reference.sha256 else {
            throw ContextRepositoryError.invalidPayload
        }
        return data
    }

    nonisolated private func writePayload(_ data: Data, mediaType: String) throws -> PayloadReference {
        guard data.count <= Self.maximumPayloadBytes, mediaType.count <= 256 else {
            throw ContextRepositoryError.invalidPayload
        }
        try Self.requireDirectory(rootURL.appendingPathComponent("payloads", isDirectory: true))
        let reference = PayloadReference(sha256: Self.digest(data), byteCount: UInt64(data.count), mediaType: mediaType)
        let path = payloadPath(reference)
        if fileManager.fileExists(atPath: path.path) {
            do { _ = try readPayload(reference) }
            catch {
                // An explicit import/relink can repair corrupt/missing bytes,
                // but cannot redirect a digest or replace a symlink/device.
                try Self.requireRegularFile(path)
                try data.write(to: path, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
        } else {
            // The process lock serializes local writers. Atomic write prevents
            // another reader from observing an unfinished source file.
            // Foundation forbids combining .atomic and .withoutOverwriting.
            // The exclusive repository lock already excludes competing writers.
            try data.write(to: path, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        return reference
    }

    private func prepareRecordingAssociations(_ next: inout ContextState, previous: ContextState) throws {
        let savedCitations = Self.allCitations(previous)
        for index in next.recordings.indices {
            let recording = next.recordings[index]
            guard let old = previous.recordings.first(where: { $0.id == recording.id }) else {
                guard recording.associationHistory == nil else {
                    throw ContextRepositoryError.invalidState("new recording association history must be generated by the repository")
                }
                continue
            }
            guard recording.associationHistory == old.associationHistory else {
                throw ContextRepositoryError.invalidState("recording association history cannot be erased or edited")
            }
            guard recording.classID != old.classID else { continue }
            var retained: [SourceCitation] = []
            for citation in savedCitations where citation.sourceKind == "transcript"
                && citation.sourceID == old.id && citation.classID == old.classID {
                if !retained.contains(citation) { retained.append(citation) }
            }
            var history = old.associationHistory ?? []
            history.append(RecordingAssociationRevision(fromClassID: old.classID, toClassID: recording.classID,
                                                        retainedCitations: retained))
            next.recordings[index].associationHistory = history
        }
    }

    private func prepareActivities(_ next: inout ContextState, previous: ContextState) throws {
        for index in next.activities.indices {
            var entry = next.activities[index]
            // Schema-v1 records written before input provenance was introduced
            // have no historical agent identity/manifest fields. Leave an
            // unchanged immutable revision intact rather than backfilling it
            // from today's mutable entry during an unrelated transaction.
            if previous.activities.contains(entry),
               next.activityRevisions.contains(where: { $0.id == entry.revisionID }) { continue }
            if let old = previous.activities.first(where: { $0.id == entry.id }), old != entry {
                if old.revisionID == entry.revisionID { entry.revisionID = UUID() }
                if old.version >= entry.version {
                    guard old.version < UInt64.max else { throw ContextRepositoryError.invalidState("activity version overflow") }
                    entry.version = old.version + 1
                }
            }
            let content = try writePayload(Data(entry.body.utf8), mediaType: "text/plain; charset=utf-8")
            entry.content = content
            let revision = ActivityRevision(id: entry.revisionID, activityID: entry.id, classID: entry.classID,
                                            version: entry.version, title: entry.title, body: entry.body,
                                            content: content, citations: entry.citations, recordedAt: entry.recordedAt,
                                            agentIdentity: entry.agentIdentity, inputContextManifest: entry.inputContextManifest)
            if let existing = next.activityRevisions.first(where: { $0.id == entry.revisionID }) {
                guard existing == revision else { throw ContextRepositoryError.invalidState("activity revision changed") }
            } else { next.activityRevisions.append(revision) }
            next.activities[index] = entry
        }
    }

    private func preserveImmutableHistory(previous: ContextState, next: ContextState) throws {
        func unchanged<T: Identifiable & Equatable>(_ old: [T], _ new: [T]) throws where T.ID == UUID {
            let lookup = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for item in old where lookup[item.id] != item {
                throw ContextRepositoryError.invalidState("an immutable source revision was removed or changed")
            }
        }
        try unchanged(previous.materialRevisions, next.materialRevisions)
        try unchanged(previous.transcriptRevisions, next.transcriptRevisions)
        try unchanged(previous.activityRevisions, next.activityRevisions)
        for old in previous.recordings {
            guard let new = next.recordings.first(where: { $0.id == old.id }) else {
                throw ContextRepositoryError.invalidState("recordings must be explicitly retired")
            }
            guard new.filename == old.filename, new.sizeBytes == old.sizeBytes, new.sha256 == old.sha256 else {
                throw ContextRepositoryError.invalidState("recording source identity changed")
            }
            let oldHistory = old.associationHistory ?? []
            guard Array((new.associationHistory ?? []).prefix(oldHistory.count)) == oldHistory else {
                throw ContextRepositoryError.invalidState("immutable recording association history changed")
            }
        }
    }

    nonisolated private func pinCitations(_ next: inout ContextState, previous: ContextState) throws {
        let citations = Self.allCitations(next)
        let existingCitations = Self.allCitations(previous)
        for reference in next.pinnedPayloads where !previous.pinnedPayloads.contains(reference) {
            _ = try readPayload(reference)
        }
        var pins = Dictionary(next.pinnedPayloads.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        for citation in citations {
            if !existingCitations.contains(citation) {
                try Self.validateCitationBytes(citation, state: next, payload: { try self.readPayload($0) })
            }
            for reference in try Self.references(for: citation, state: next) {
                if !existingCitations.contains(citation) {
                    _ = try readPayload(reference) // New citations require their bytes before committing.
                }
                pins[reference.sha256] = reference
            }
        }
        next.pinnedPayloads = pins.values.sorted { $0.sha256 < $1.sha256 }
    }

    nonisolated private static func allCitations(_ state: ContextState) -> [SourceCitation] {
        let coursework = state.coursework.flatMap { [$0.sourceCitation].compactMap { $0 } + ($0.relatedCitations ?? []) }
        return coursework + state.pinnedCitations + state.activities.flatMap { $0.citations + ($0.inputContextManifest ?? []) }
            + state.activityRevisions.flatMap { $0.citations + ($0.inputContextManifest ?? []) }
            + state.proposals.flatMap { $0.citations + $0.contextManifest }
            + state.recordings.flatMap { ($0.associationHistory ?? []).flatMap(\.retainedCitations) }
    }

    nonisolated private static func references(for citation: SourceCitation, state: ContextState) throws -> [PayloadReference] {
        guard state.classes.contains(where: { $0.id == citation.classID }), validDigest(citation.payloadSHA256) else {
            throw ContextRepositoryError.invalidState("citation has an invalid class or digest")
        }
        let references: [PayloadReference]
        switch citation.sourceKind {
        case "material":
            guard let material = state.materials.first(where: { $0.id == citation.sourceID && $0.classID == citation.classID }),
                  let revision = state.materialRevisions.first(where: { $0.id == citation.revisionID && $0.materialID == material.id }) else {
                throw ContextRepositoryError.invalidState("citation source revision is missing")
            }
            references = [revision.original] + [revision.text].compactMap { $0 }
        case "activity":
            guard let revision = state.activityRevisions.first(where: {
                $0.id == citation.revisionID && $0.activityID == citation.sourceID && $0.classID == citation.classID
            }) else { throw ContextRepositoryError.invalidState("activity citation revision is missing") }
            switch citation.locator {
            case .whole: break
            case .text(let start, let length):
                guard validUTF8Range(start: start, length: length, in: revision.body) else {
                    throw ContextRepositoryError.invalidState("activity citation text range is invalid")
                }
            default: throw ContextRepositoryError.invalidState("activity citation locator is invalid")
            }
            references = [revision.content]
        case "transcript":
            guard let recording = state.recordingForCitation(citation),
                  let revision = state.transcriptRevisions.first(where: { $0.id == citation.revisionID && $0.recordingID == recording.id }) else {
                throw ContextRepositoryError.invalidState("transcript citation revision is missing")
            }
            if case .cues(let start, let end) = citation.locator {
                guard start >= 0, end >= start, end < revision.cues.count else {
                    throw ContextRepositoryError.invalidState("citation cue range is invalid")
                }
            }
            switch citation.locator {
            case .whole, .cues: break
            default: throw ContextRepositoryError.invalidState("transcript citation locator is invalid")
            }
            references = [revision.content]
        default: throw ContextRepositoryError.invalidState("citation source kind is unsupported")
        }
        guard references.contains(where: { $0.sha256 == citation.payloadSHA256 }) else {
            throw ContextRepositoryError.invalidState("citation payload does not match its revision")
        }
        switch citation.locator {
        case .page(let page): guard page > 0 else { throw ContextRepositoryError.invalidState("citation page is invalid") }
        case .text(let start, let length):
            guard start >= 0, length > 0, !start.addingReportingOverflow(length).overflow else {
                throw ContextRepositoryError.invalidState("citation text range is invalid")
            }
        case .section(let section): guard !section.isEmpty else { throw ContextRepositoryError.invalidState("citation section is empty") }
        case .cues(let start, let end):
            guard citation.sourceKind == "transcript", start >= 0, end >= start else {
                throw ContextRepositoryError.invalidState("citation cue range is invalid")
            }
        case .whole: break
        }
        return references
    }

    nonisolated private static func validUTF8Range(start: Int, length: Int, in text: String) -> Bool {
        let (end, overflow) = start.addingReportingOverflow(length)
        let bytes = Data(text.utf8)
        guard !overflow, start >= 0, length > 0, end <= bytes.count else { return false }
        return String(data: bytes.subdata(in: start..<end), encoding: .utf8) != nil
    }

    /// The portable extraction envelope is part of the core source contract.
    /// Decode only the fields needed to validate a locator, avoiding a services dependency.
    nonisolated private static func validateCitationBytes(_ citation: SourceCitation, state: ContextState,
                                              payload: (PayloadReference) throws -> Data) throws {
        _ = try references(for: citation, state: state)
        guard citation.sourceKind == "material", citation.locator != .whole else { return }
        guard let revision = state.materialRevisions.first(where: { $0.id == citation.revisionID }),
              let textReference = revision.text, textReference.sha256 == citation.payloadSHA256 else {
            throw ContextRepositoryError.invalidState("material locator requires exact extracted text")
        }
        struct Passage: Decodable { var locator: SourceLocator; var text: String }
        struct Extraction: Decodable { var schemaVersion: Int; var plainText: String; var passages: [Passage] }
        let extraction = try JSONDecoder().decode(Extraction.self, from: payload(textReference))
        guard extraction.schemaVersion == 1 else { throw ContextRepositoryError.invalidState("extraction schema is unsupported") }
        switch citation.locator {
        case .text(let start, let length):
            guard validUTF8Range(start: start, length: length, in: extraction.plainText) else {
                throw ContextRepositoryError.invalidState("material text locator is outside its exact revision")
            }
        case .page, .section:
            guard extraction.passages.contains(where: { $0.locator == citation.locator && !$0.text.isEmpty }) else {
                throw ContextRepositoryError.invalidState("material locator does not exist in its exact revision")
            }
        default: throw ContextRepositoryError.invalidState("material citation locator is invalid")
        }
    }

    nonisolated private static func allPayloads(_ state: ContextState) throws -> [PayloadReference] {
        let references = state.materialRevisions.flatMap { [$0.original] + [$0.text].compactMap { $0 } }
            + state.activityRevisions.map(\.content) + state.transcriptRevisions.map(\.content) + state.pinnedPayloads
        var unique: [String: PayloadReference] = [:]
        for reference in references {
            if let existing = unique[reference.sha256], existing.byteCount != reference.byteCount {
                throw ContextRepositoryError.invalidPayload
            }
            unique[reference.sha256] = reference
        }
        return unique.values.sorted { $0.sha256 < $1.sha256 }
    }

    nonisolated private static func validateInputContext(_ citations: [SourceCitation]?, classID: UUID) throws {
        guard let citations else { return }
        guard citations.count <= 128, citations.allSatisfy({ $0.classID == classID }) else {
            throw ContextRepositoryError.invalidState("agent input context exceeds its bound or belongs to another class")
        }
    }

    nonisolated private static func validate(_ state: ContextState, requirePayloadBytes: Bool = true,
                                 payload: (PayloadReference) throws -> Data) throws {
        guard state.schemaVersion == ContextState.currentSchemaVersion else { throw ContextRepositoryError.unsupportedSchema }
        func unique<T: Identifiable>(_ records: [T]) throws where T.ID == UUID {
            guard records.count <= 100_000, Set(records.map(\.id)).count == records.count else {
                throw ContextRepositoryError.invalidState("duplicate identifiers or record limit exceeded")
            }
        }
        try unique(state.terms); try unique(state.courses); try unique(state.classes); try unique(state.materials)
        try unique(state.materialRevisions); try unique(state.activities); try unique(state.activityRevisions)
        try unique(state.coursework); try unique(state.recordings); try unique(state.transcriptRevisions)
        try unique(state.connections); try unique(state.grants); try unique(state.proposals)
        let termIDs = Set(state.terms.map(\.id)), courseIDs = Set(state.courses.map(\.id))
        let classIDs = Set(state.classes.map(\.id)), materialIDs = Set(state.materials.map(\.id))
        let recordingIDs = Set(state.recordings.map(\.id))
        for term in state.terms {
            guard !term.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  TimeZone(identifier: term.timeZoneID) != nil else { throw ContextRepositoryError.invalidState("term metadata is invalid") }
            if let value = term.startDate { try validateDate(value) }
            if let value = term.endDate { try validateDate(value) }
        }
        for item in state.classes {
            guard item.termID.map(termIDs.contains) ?? true, item.courseID.map(courseIDs.contains) ?? true,
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.credits.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  item.sessionDetails.map({ $0.utf8.count <= 16_384 }) ?? true,
                  item.location.map({ $0.utf8.count <= 4_096 }) ?? true else {
                throw ContextRepositoryError.invalidState("class identity or metadata is invalid")
            }
        }
        for material in state.materials {
            guard classIDs.contains(material.classID), !material.title.isEmpty,
                  material.currentRevisionID.map({ id in state.materialRevisions.contains { $0.id == id && $0.materialID == material.id } }) ?? true else {
                throw ContextRepositoryError.invalidState("material relationship is invalid")
            }
        }
        for revision in state.materialRevisions where !materialIDs.contains(revision.materialID) {
            throw ContextRepositoryError.invalidState("material revision parent is missing")
        }
        for revision in state.materialRevisions {
            if let context = revision.courseworkContext {
                guard state.materials.contains(where: { $0.id == revision.materialID && $0.kind == "uci-canvas" }),
                      revision.importedSource?.provider == "UCI Canvas",
                      !context.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      context.title.utf8.count <= 2_048, ["assignment", "quiz"].contains(context.kind),
                      context.dueAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
                    throw ContextRepositoryError.invalidState("imported coursework context is invalid")
                }
            }
        }
        for activity in state.activities {
            guard classIDs.contains(activity.classID), let content = activity.content,
                  state.activityRevisions.contains(where: {
                      $0.id == activity.revisionID && $0.activityID == activity.id && $0.classID == activity.classID
                          && $0.content == content && $0.inputContextManifest == activity.inputContextManifest
                  }),
                  try !requirePayloadBytes || Data(activity.body.utf8) == payload(content) else {
                throw ContextRepositoryError.invalidState("activity revision or content is invalid")
            }
            try validateInputContext(activity.inputContextManifest, classID: activity.classID)
        }
        let activityByID = Dictionary(uniqueKeysWithValues: state.activities.map { ($0.id, $0) })
        for activity in state.activities {
            if let targetID = activity.supersedesID {
                guard targetID != activity.id, let target = activityByID[targetID], target.classID == activity.classID else {
                    throw ContextRepositoryError.invalidState("activity correction target is missing or belongs to another class")
                }
            }
        }
        // Every entry has at most one outgoing correction edge. Mark complete
        // paths so even a long valid history takes linear validation work.
        var completedCorrections: Set<UUID> = []
        for activity in state.activities where !completedCorrections.contains(activity.id) {
            var path: Set<UUID> = []
            var cursor: UUID? = activity.id
            while let id = cursor, !completedCorrections.contains(id) {
                guard path.insert(id).inserted else {
                    throw ContextRepositoryError.invalidState("activity correction history contains a cycle")
                }
                cursor = activityByID[id]?.supersedesID
            }
            completedCorrections.formUnion(path)
        }
        for revision in state.activityRevisions {
            guard activityByID[revision.activityID]?.classID == revision.classID, classIDs.contains(revision.classID),
                  try !requirePayloadBytes || Data(revision.body.utf8) == payload(revision.content) else {
                throw ContextRepositoryError.invalidState("activity history is invalid")
            }
            try validateInputContext(revision.inputContextManifest, classID: revision.classID)
        }
        for item in state.coursework {
            guard classIDs.contains(item.classID) else { throw ContextRepositoryError.invalidState("coursework class is missing") }
            let citations = [item.sourceCitation].compactMap { $0 } + (item.relatedCitations ?? [])
            guard citations.count <= 65,
                  citations.allSatisfy({ $0.classID == item.classID && $0.sourceKind == "material" }) else {
                throw ContextRepositoryError.invalidState("coursework evidence belongs to another class or exceeds its limit")
            }
            if let source = item.sourceCitation {
                guard state.materialRevisions.contains(where: {
                    $0.id == source.revisionID && $0.materialID == source.sourceID && $0.courseworkContext != nil
                }) else { throw ContextRepositoryError.invalidState("coursework source is not an imported assignment revision") }
            }
            if let due = item.due {
                switch due {
                case .dateOnly(let date): try validateDate(date)
                case .timed(let instant, let timeZoneID):
                    guard instant.timeIntervalSinceReferenceDate.isFinite, TimeZone(identifier: timeZoneID) != nil else {
                        throw ContextRepositoryError.invalidState("deadline timezone or instant is invalid")
                    }
                }
            }
        }
        var associationRevisionIDs: Set<UUID> = []
        for recording in state.recordings {
            guard recording.classID.map({ classIDs.contains($0) }) ?? true,
                  !recording.filename.isEmpty, !recording.filename.contains("/"), !recording.filename.contains("\\"),
                  recording.sizeBytes > 0, validDigest(recording.sha256) else {
                throw ContextRepositoryError.invalidState("recording source identity is invalid")
            }
            if let current = recording.currentTranscriptRevisionID {
                guard state.transcriptRevisions.contains(where: {
                    $0.id == current && $0.recordingID == recording.id && $0.acceptedJobID == recording.acceptedJobID
                }) else { throw ContextRepositoryError.invalidState("current transcript revision does not match its recording") }
            }
            if let history = recording.associationHistory {
                guard !history.isEmpty, history.count <= 100_000, history.last?.toClassID == recording.classID else {
                    throw ContextRepositoryError.invalidState("recording association history is empty or differs from its current class")
                }
                for (index, revision) in history.enumerated() {
                    guard associationRevisionIDs.insert(revision.id).inserted, associationRevisionIDs.count <= 100_000,
                          revision.fromClassID != revision.toClassID,
                          revision.fromClassID.map({ classIDs.contains($0) }) ?? true,
                          revision.toClassID.map({ classIDs.contains($0) }) ?? true,
                          revision.changedAt.timeIntervalSinceReferenceDate.isFinite,
                          index == 0 || revision.fromClassID == history[index - 1].toClassID,
                          revision.retainedCitations.count <= 100_000,
                          revision.retainedCitations.allSatisfy({
                              $0.sourceKind == "transcript" && $0.sourceID == recording.id
                                  && $0.classID == revision.fromClassID
                          }) else {
                        throw ContextRepositoryError.invalidState("recording association chain or retained source is invalid")
                    }
                }
            }
        }
        for revision in state.transcriptRevisions {
            guard recordingIDs.contains(revision.recordingID), !revision.acceptedJobID.isEmpty,
                  revision.duration.isFinite, revision.duration >= 0 else {
                throw ContextRepositoryError.invalidState("transcript identity is invalid")
            }
            var previousStart: Double = -1
            for cue in revision.cues {
                guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start,
                      cue.start >= previousStart, revision.duration == 0 || cue.end <= revision.duration,
                      !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ContextRepositoryError.invalidState("transcript speech endpoints are invalid")
                }
                previousStart = cue.start
            }
            for event in revision.audioEvents {
                guard event.type == "audio_event", event.start.isFinite, event.end.isFinite,
                      event.start >= 0, event.end > event.start,
                      revision.duration == 0 || event.end <= revision.duration, !event.text.isEmpty else {
                    throw ContextRepositoryError.invalidState("transcript event endpoints are invalid")
                }
            }
        }
        let connectionIDs = Set(state.connections.map(\.id))
        for grant in state.grants {
            guard connectionIDs.contains(grant.connectionID), Set(grant.allowedClassIDs).isSubset(of: classIDs),
                  grant.allowedMaterialIDs.map({ Set($0).isSubset(of: materialIDs) }) ?? true,
                  grant.eventFrom.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  grant.eventUntil.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  grant.eventFrom == nil || grant.eventUntil == nil || grant.eventFrom! <= grant.eventUntil! else {
                throw ContextRepositoryError.invalidState("agent grant scope is invalid")
            }
            if let ids = grant.allowedMaterialIDs {
                for material in state.materials where ids.contains(material.id) && !grant.allowedClassIDs.contains(material.classID) {
                    throw ContextRepositoryError.invalidState("agent grant includes an unallowed class")
                }
            }
        }
        for proposal in state.proposals {
            guard classIDs.contains(proposal.classID), !proposal.agentIdentity.isEmpty, !proposal.idempotencyKey.isEmpty else {
                throw ContextRepositoryError.invalidState("agent proposal identity is invalid")
            }
        }
        for citation in allCitations(state) {
            _ = try references(for: citation, state: state)
            if requirePayloadBytes { try validateCitationBytes(citation, state: state, payload: payload) }
        }
        for reference in try allPayloads(state) {
            guard validDigest(reference.sha256), reference.byteCount <= maximumPayloadBytes else {
                throw ContextRepositoryError.invalidPayload
            }
            if requirePayloadBytes { _ = try payload(reference) }
        }
    }

    nonisolated private static func validateDate(_ value: LocalDate) throws {
        let calendar = Calendar(identifier: .gregorian)
        let parts = DateComponents(year: value.year, month: value.month, day: value.day)
        guard (1...9999).contains(value.year), let date = calendar.date(from: parts),
              calendar.component(.year, from: date) == value.year,
              calendar.component(.month, from: date) == value.month,
              calendar.component(.day, from: date) == value.day else {
            throw ContextRepositoryError.invalidState("date-only value is invalid")
        }
    }

    nonisolated private func exportUnlocked(_ snapshot: ContextState, to destination: URL,
                                includeUnpinnedTranscriptCaches: Bool = false, audioScope: RecordingAudioBackup.Scope = .omit) throws {
        guard destination.isFileURL else { throw ContextRepositoryError.unsafePath }
        guard !fileManager.fileExists(atPath: destination.path) else { throw ContextRepositoryError.destinationExists }
        try Self.ensureDirectory(destination.deletingLastPathComponent())
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".lcp-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try Self.ensureDirectory(staging)
        try Self.ensureDirectory(staging.appendingPathComponent("payloads", isDirectory: true))
        var portable = snapshot
        let removed = includeUnpinnedTranscriptCaches ? [] : try removeUnpinnedTranscriptRows(from: &portable, original: snapshot)
        portable.grants = []
        for index in portable.recordings.indices { portable.recordings[index].localAudioPath = nil }
        try Self.validate(portable, payload: { try self.readPayload($0) })
        let references = try Self.allPayloads(portable)
        var total: UInt64 = 0
        for reference in references {
            try Task.checkCancellation()
            total += reference.byteCount
            guard total <= 1_024 * 1_024 * 1_024 else { throw ContextRepositoryError.invalidBackup }
            let bytes = try readPayload(reference)
            try bytes.write(to: staging.appendingPathComponent("payloads").appendingPathComponent(reference.sha256 + ".blob"), options: .withoutOverwriting)
        }
        let includedAudio = try RecordingAudioBackup.export(snapshot.recordings, to: staging, scope: audioScope)
        let includedIDs = Set(includedAudio.map(\.id))
        let omittedAudio = portable.recordings.filter { !includedIDs.contains($0.id) }.map(\.filename)
        // Default and audio-free backups retain the v1 portable representation.
        let includesAudio = !includedAudio.isEmpty
        let stateData = try Self.encode(portable)
        try stateData.write(to: staging.appendingPathComponent("context.json"), options: .withoutOverwriting)
        var manifest = ContextBackupManifest(version: includesAudio ? 2 : 1, createdAt: Date(), stateSHA256: Self.digest(stateData),
                                             stateByteCount: UInt64(stateData.count), payloads: references,
                                             omittedAudio: omittedAudio,
                                             includedAudioRecordingIDs: includesAudio ? includedAudio.map(\.id) : nil,
                                             exclusions: ["access grants", "connection secrets", "derived search index"])
        if !includesAudio { manifest.exclusions.append("raw audio") }
        manifest.omittedTranscriptCaches = removed.map {
            TranscriptCacheOmission(recordingID: $0.recordingID, revisionID: $0.id, payloadSHA256: $0.content.sha256)
        }
        if !includeUnpinnedTranscriptCaches { manifest.exclusions.append("unpinned transcript caches") }
        try Self.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try Task.checkCancellation()
        try fileManager.moveItem(at: staging, to: destination)
    }

    nonisolated private static func readBackup(_ source: URL) throws -> (ContextState, [PayloadReference], [LectureRecording]) {
        do {
            try requireDirectory(source)
            let manifestData = try readRegularFile(source.appendingPathComponent("manifest.json"), maximum: maximumStateBytes)
            let manifest = try JSONDecoder().decode(ContextBackupManifest.self, from: manifestData)
            guard manifest.version == 1 || manifest.version == 2 else { throw ContextRepositoryError.unsupportedSchema }
            guard manifest.stateByteCount <= maximumStateBytes, validDigest(manifest.stateSHA256), manifest.payloads.count <= 100_000 else {
                throw ContextRepositoryError.invalidBackup
            }
            let stateData = try readRegularFile(source.appendingPathComponent("context.json"), maximum: maximumStateBytes)
            guard stateData.count == manifest.stateByteCount, digest(stateData) == manifest.stateSHA256 else {
                throw ContextRepositoryError.invalidBackup
            }
            let decoded = try JSONDecoder().decode(ContextState.self, from: stateData)
            guard decoded.grants.isEmpty else { throw ContextRepositoryError.invalidBackup }
            if let omitted = manifest.omittedTranscriptCaches {
                let recordingIDs = Set(decoded.recordings.map(\.id))
                var revisionIDs = Set(decoded.transcriptRevisions.map(\.id))
                guard omitted.count <= 100_000, omitted.allSatisfy({
                    recordingIDs.contains($0.recordingID) && validDigest($0.payloadSHA256)
                        && revisionIDs.insert($0.revisionID).inserted
                }) else { throw ContextRepositoryError.invalidBackup }
            }
            let required = try allPayloads(decoded)
            guard Set(required.map(\.sha256)) == Set(manifest.payloads.map(\.sha256)),
                  Set(manifest.payloads.map(\.sha256)).count == manifest.payloads.count else {
                throw ContextRepositoryError.invalidBackup
            }
            var total: UInt64 = 0
            for reference in manifest.payloads {
                guard reference.byteCount <= maximumPayloadBytes else { throw ContextRepositoryError.invalidBackup }
                total += reference.byteCount
                guard total <= 1_024 * 1_024 * 1_024 else { throw ContextRepositoryError.invalidBackup }
                _ = try readBackupPayload(reference, root: source)
            }
            try validate(decoded, payload: { try readBackupPayload($0, root: source) })
            let audio = try RecordingAudioBackup.selections(in: manifest, recordings: decoded.recordings)
            return (decoded, manifest.payloads, audio)
        } catch is CancellationError { throw CancellationError() }
        catch ContextRepositoryError.unsupportedSchema { throw ContextRepositoryError.unsupportedSchema }
        catch { throw ContextRepositoryError.invalidBackup }
    }

    /// A damaged current library still gets a truthful pre-restore record. This
    /// deliberately has no manifest.json and cannot masquerade as a complete backup.
    nonisolated private func exportIncompleteRecovery(_ snapshot: ContextState, to destination: URL) throws {
        try Self.ensureDirectory(destination)
        try Self.ensureDirectory(destination.appendingPathComponent("payloads", isDirectory: true))
        try Self.encode(snapshot).write(to: destination.appendingPathComponent("context.json"), options: .atomic)
        var missing: [PayloadReference] = []
        for reference in try Self.allPayloads(snapshot) {
            if let bytes = try? readPayload(reference) {
                try bytes.write(to: destination.appendingPathComponent("payloads").appendingPathComponent(reference.sha256 + ".blob"), options: .atomic)
            } else { missing.append(reference) }
        }
        struct IncompleteRecovery: Encodable { var complete = false; var missingPayloads: [PayloadReference] }
        try Self.encode(IncompleteRecovery(missingPayloads: missing))
            .write(to: destination.appendingPathComponent("incomplete-recovery.json"), options: .atomic)
    }

    nonisolated private static func readBackupPayload(_ reference: PayloadReference, root: URL) throws -> Data {
        guard validDigest(reference.sha256), reference.byteCount <= maximumPayloadBytes else { throw ContextRepositoryError.invalidBackup }
        let directory = root.appendingPathComponent("payloads", isDirectory: true)
        try requireDirectory(directory)
        let bytes = try readRegularFile(directory.appendingPathComponent(reference.sha256 + ".blob"), maximum: maximumPayloadBytes)
        guard bytes.count == reference.byteCount, digest(bytes) == reference.sha256 else { throw ContextRepositoryError.invalidBackup }
        return bytes
    }

    nonisolated private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated private static func validDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    nonisolated private static func ensureDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw ContextRepositoryError.unsafePath }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(url)
    }
    nonisolated private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard url.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else { throw ContextRepositoryError.unsafePath }
    }
    nonisolated private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else { throw ContextRepositoryError.unsafePath }
    }
    nonisolated private static func readRegularFile(_ url: URL, maximum: UInt64) throws -> Data {
        try requireRegularFile(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ContextRepositoryError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_size >= 0, UInt64(initial.st_size) <= maximum else { throw ContextRepositoryError.unsafePath }
        var data = Data()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= maximum else { throw ContextRepositoryError.invalidPayload }
            data.append(chunk)
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              data.count == final.st_size else { throw ContextRepositoryError.invalidPayload }
        return data
    }
}

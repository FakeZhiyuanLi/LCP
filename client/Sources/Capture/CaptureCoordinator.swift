import Combine
import Foundation

public enum CaptureState: String, Codable, Sendable {
    case idle, requestingPermission, recording, finalizing, blocked
}

public struct CaptureDestination: Identifiable, Equatable, Codable, Sendable {
    public var id: String { courseCode }
    public let name: String
    public let courseCode: String
    public let driveFolderID: String?
}

public struct CaptureSession: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let academicClassID: UUID?
    public let destination: CaptureDestination
    public let startedAt: Date
    public let timeZoneIdentifier: String
}

public struct FinalizedCapture: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID { session.id }
    public let session: CaptureSession
    public let filename: String
    public let sizeBytes: UInt64
    public let sha256: String
    public let audioURL: URL
    public let readyURL: URL
}

public struct CaptureConfiguration: Sendable {
    public let stagingDirectory: URL
    public let catalogURL: URL
    public let leaseURL: URL
    public let legacyBundleURLs: [URL]

    public init(stagingDirectory: URL, catalogURL: URL, leaseURL: URL, legacyBundleURLs: [URL]) {
        self.stagingDirectory = stagingDirectory
        self.catalogURL = catalogURL
        self.leaseURL = leaseURL
        self.legacyBundleURLs = legacyBundleURLs
    }

    public static var live: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(
            stagingDirectory: home.appendingPathComponent("Lectures/Incoming"),
            catalogURL: home.appendingPathComponent("Lectures/Classes/classes.json"),
            leaseURL: home.appendingPathComponent("Library/Application Support/LCP Capture/capture.lock"),
            legacyBundleURLs: [home.appendingPathComponent("Applications/LCP Recorder.app"), URL(fileURLWithPath: "/Applications/LCP Recorder.app")]
        )
    }

    /// Unlike a recording destination, the configured Drive root is an identity
    /// that can be revalidated on Drive even when the catalog is old.
    public func publishedDriveRootID() throws -> String? {
        let store = ClassManifestStore(manifestURL: catalogURL, maximumAge: .infinity)
        do { _ = try catalogURL.resourceValues(forKeys: [.isRegularFileKey]) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return nil }
        let id = try store.load().rootFolderID
        guard id != "root" else { throw ClassManifestError.invalidMetadata }
        return id
    }
}

public enum CaptureError: LocalizedError, Equatable {
    case invalidConfiguration, captureInUse, leaseUnavailable, invalidDestination, destinationChanged, permissionDenied, cancelled
    case incompatibleRecorder(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Capture requires local staging, catalog and lease paths."
        case .captureInUse: return "Another LCP recording or microphone check is active or still finalizing. Wait for it to finish."
        case .leaseUnavailable: return "The shared recording lease could not be opened. Check local capture storage permissions."
        case .invalidDestination: return "Choose a destination from the current synced class catalog. Organizer classes alone cannot authorize recording."
        case .destinationChanged: return "The synced Drive folder no longer matches this class mapping. Review and explicitly update the recording destination before starting."
        case .permissionDenied: return "Allow microphone access in System Settings > Privacy & Security > Microphone."
        case .cancelled: return "Recording start was cancelled."
        case .incompatibleRecorder(let reason): return reason
        }
    }
}

/// The only supported recording entry point for the desktop and compatible
/// recorder hosts. It has no network, provider or organizer persistence code.
@MainActor
public final class CaptureCoordinator: ObservableObject {
    @Published public private(set) var state: CaptureState = .idle
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var levels: CaptureLevels?
    @Published public private(set) var microphoneDevices: [MicrophoneDevice] = []
    @Published public private(set) var selectedMicrophoneID = ""
    @Published public private(set) var defaultMicrophoneName: String?
    @Published public private(set) var activeMicrophoneName: String?
    @Published public private(set) var isMonitoring = false
    @Published public private(set) var destinations: [CaptureDestination] = []
    @Published public private(set) var catalogIsUsable = false
    @Published public private(set) var catalogIssue: String?
    @Published public private(set) var compatibilityIssue: String?
    @Published public private(set) var activeSession: CaptureSession?
    @Published public private(set) var lastFinalized: FinalizedCapture?

    // Keep the coordinator/lease alive through asynchronous encoder closure,
    // including when a window closes. Hosts must use deferred termination.
    private static var retainedSessions: [UUID: CaptureCoordinator] = [:]
    let engine: AudioRecorder
    private let configuration: CaptureConfiguration
    private let catalog: ClassManifestStore
    private let compatibilityCheck: () throws -> Void
    private let now: () -> Date
    private var lease: CaptureLease?
    private var monitoringLease: CaptureLease?
    private var monitoringID: UUID?
    private var pendingMicrophoneCheck: UUID?
    private var subscriptions = Set<AnyCancellable>()
    private var levelTimer: Timer?
    private var startPending = false

    public convenience init(configuration: CaptureConfiguration = .live) throws {
        guard configuration.stagingDirectory.isFileURL, configuration.catalogURL.isFileURL,
              configuration.leaseURL.isFileURL else { throw CaptureError.invalidConfiguration }
        let engine = try AudioRecorder(ingestManager: IngestManager(stagingDirectory: configuration.stagingDirectory,
                                                                    createDirectory: false))
        self.init(engine: engine, configuration: configuration, compatibilityCheck: { try CaptureCompatibility.check(configuration: configuration) })
    }

    init(engine: AudioRecorder, configuration: CaptureConfiguration,
         compatibilityCheck: @escaping () throws -> Void, now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.configuration = configuration
        self.catalog = ClassManifestStore(manifestURL: configuration.catalogURL)
        self.compatibilityCheck = compatibilityCheck
        self.now = now
        engine.onSessionEnded = { [weak self] url, published in self?.sessionEnded(url: url, published: published) }
        engine.onMonitoringEnded = { [weak self] failure in
            self?.releaseMonitoringLease()
            if let failure { self?.statusMessage = failure }
        }
        engine.$microphoneDevices.assign(to: &$microphoneDevices)
        engine.$selectedMicrophoneID.assign(to: &$selectedMicrophoneID)
        engine.$defaultMicrophoneName.assign(to: &$defaultMicrophoneName)
        engine.$activeMicrophoneName.assign(to: &$activeMicrophoneName)
        engine.$isMonitoring.assign(to: &$isMonitoring)
        engine.$duration.sink { [weak self] in self?.duration = $0 }.store(in: &subscriptions)
        engine.$isFinishing.sink { [weak self] finishing in
            if finishing { self?.state = .finalizing }
        }.store(in: &subscriptions)
        reloadDestinations()
    }

    public func reloadDestinations() {
        _ = try? refreshCatalog()
        guard activeSession == nil, !startPending else { return }
        try? checkCompatibility()
        statusMessage = compatibilityIssue ?? catalogIssue
        state = statusMessage == nil ? .idle : .blocked
    }

    public func start(destinationID: String, academicClassID: UUID? = nil, expectedDriveFolderID: String? = nil) async throws {
        try await start(academicClassID: academicClassID, resolve: {
            try currentDestination(id: destinationID, expectedDriveFolderID: expectedDriveFolderID)
        })
    }

    public func startLocal(academicClassID: UUID, className: String, recordingsDirectory: URL) async throws {
        let destination = CaptureDestination(name: className, courseCode: className, driveFolderID: nil)
        try await start(academicClassID: academicClassID, resolve: { destination }) { session in
            try IngestManager.localRecordingURL(in: recordingsDirectory, excluding: self.configuration.stagingDirectory,
                                                academicClassID: academicClassID, session: session)
        }
    }

    private func start(academicClassID: UUID?, resolve: () throws -> CaptureDestination,
                       localOutput: ((CaptureSession) throws -> URL)? = nil) async throws {
        guard activeSession == nil, !startPending else { throw CaptureError.captureInUse }
        startPending = true
        defer { startPending = false }
        do {
            try checkCompatibility()
            _ = try resolve()
            stopMonitoring()
            state = .requestingPermission
            statusMessage = nil
            guard await engine.requestPermission() else { throw CaptureError.permissionDenied }
            guard !Task.isCancelled else { throw CaptureError.cancelled }
            // Permission is an asynchronous UI boundary. Revalidate both the
            // installed/running versions and the catalog immediately afterward.
            let sessionID = UUID()
            lease = try CaptureLease.acquire(at: configuration.leaseURL, sessionID: sessionID)
            try checkCompatibility()
            let destination = try resolve()
            let session = CaptureSession(id: sessionID, academicClassID: academicClassID, destination: destination,
                                         startedAt: now(), timeZoneIdentifier: TimeZone.current.identifier)
            activeSession = session
            Self.retainedSessions[sessionID] = self
            engine.courseCode = destination.courseCode
            try engine.startRecording(at: try localOutput?(session))
            state = .recording
            startLevelTimer()
        } catch {
            releaseSession()
            state = .blocked
            statusMessage = error.localizedDescription
            throw error
        }
    }

    public func stop() {
        stopMonitoring()
        engine.stopRecording()
    }

    public func deferApplicationTermination() -> Bool { engine.deferApplicationTermination() }

    public func refreshLevels() {
        let sample = engine.sampleAudioLevels()
        if levels != sample { levels = sample }
    }

    private func startLevelTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLevels() }
        }
        levelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        levels = nil
    }

    public func refreshMicrophones() { engine.refreshMicrophones() }

    public func selectMicrophone(_ id: String) {
        guard activeSession == nil, !startPending, pendingMicrophoneCheck == nil else { return }
        engine.selectMicrophone(id)
    }

    /// The view owns its check, including time spent waiting in the macOS permission dialog.
    public func beginMicrophoneCheck(id: UUID) async throws {
        try Task.checkCancellation()
        guard activeSession == nil, !startPending, monitoringID == nil, pendingMicrophoneCheck == nil else {
            throw CaptureError.captureInUse
        }
        try checkCompatibility()
        pendingMicrophoneCheck = id
        defer { if pendingMicrophoneCheck == id { pendingMicrophoneCheck = nil } }
        let allowed = await engine.requestPermission()
        try Task.checkCancellation()
        guard pendingMicrophoneCheck == id else { throw CancellationError() }
        guard allowed else { throw CaptureError.permissionDenied }
        try startMonitoring(id: id)
    }

    public func endMicrophoneCheck(id: UUID) {
        if pendingMicrophoneCheck == id { pendingMicrophoneCheck = nil }
        if monitoringID == id { stopMonitoring() }
    }

    func startMonitoring(id: UUID = UUID()) throws {
        guard activeSession == nil, !startPending else { throw CaptureError.captureInUse }
        guard !engine.isMonitoring else { return }
        do {
            try compatibilityCheck()
            monitoringLease = try CaptureLease.acquire(at: configuration.leaseURL, sessionID: id)
            monitoringID = id
            Self.retainedSessions[id] = self
            try engine.startMonitoring()
            startLevelTimer()
        } catch {
            releaseMonitoringLease()
            statusMessage = error.localizedDescription
            throw error
        }
    }

    func stopMonitoring() {
        pendingMicrophoneCheck = nil
        engine.stopMonitoring()
    }

    private func releaseMonitoringLease() {
        stopLevelTimer()
        monitoringLease?.release()
        monitoringLease = nil
        if let id = monitoringID { Self.retainedSessions.removeValue(forKey: id) }
        monitoringID = nil
    }

    private func eligibleDestinations() throws -> [CaptureDestination] {
        try catalog.loadClasses(now: now()).filter {
            $0.name.compare("LCP Test", options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
                && $0.courseCode.compare("LCP Test", options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }.map { CaptureDestination(name: $0.name, courseCode: $0.courseCode, driveFolderID: $0.driveFolderID) }
    }

    private func checkCompatibility() throws {
        do {
            try compatibilityCheck()
            compatibilityIssue = nil
        } catch {
            compatibilityIssue = error.localizedDescription
            throw error
        }
    }

    private func refreshCatalog() throws {
        do {
            destinations = try eligibleDestinations()
            catalogIsUsable = true
            catalogIssue = nil
        } catch {
            destinations = []
            catalogIsUsable = false
            catalogIssue = error.localizedDescription
            throw error
        }
    }

    private func currentDestination(id: String, expectedDriveFolderID: String?) throws -> CaptureDestination {
        try refreshCatalog()
        guard let destination = destinations.first(where: { $0.id == id }) else { throw CaptureError.invalidDestination }
        if let expectedDriveFolderID, destination.driveFolderID != expectedDriveFolderID {
            throw CaptureError.destinationChanged
        }
        return destination
    }

    private func sessionEnded(url: URL, published: Bool) {
        if published, let session = activeSession {
            do {
                let ready = RecordingManifest.readyURL(for: url)
                let marker = try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: ready))
                guard marker.version == 1, marker.filename == url.lastPathComponent, marker.sizeBytes > 0,
                      marker.sha256.count == 64 else { throw CaptureError.invalidConfiguration }
                lastFinalized = FinalizedCapture(session: session, filename: marker.filename, sizeBytes: marker.sizeBytes,
                                                sha256: marker.sha256, audioURL: url, readyURL: ready)
                statusMessage = nil
                state = .idle
            } catch {
                statusMessage = "Audio finalized, but its identity could not be read: \(error.localizedDescription)"
                state = .blocked
            }
        } else {
            statusMessage = engine.errorMessage ?? "Recording was not finalized successfully; no completion marker was published."
            state = .blocked
        }
        // Release only after marker creation and finalized identity delivery.
        releaseSession()
    }

    private func releaseSession() {
        // A configuration error can happen before start() ends an existing mic check.
        if monitoringID == nil { stopLevelTimer() }
        lease?.release()
        lease = nil
        if let id = activeSession?.id { Self.retainedSessions.removeValue(forKey: id) }
        activeSession = nil
    }
}

import AppKit
import AVFoundation
import Combine

/// The operations used by the engine, separate from microphone hardware.
protocol AudioRecording: AnyObject {
    var delegate: (any AVAudioRecorderDelegate)? { get set }
    var currentTime: TimeInterval { get }
    var finalizesAsynchronously: Bool { get }
    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
    @discardableResult func deleteRecording() -> Bool
}

extension AudioRecording {
    var finalizesAsynchronously: Bool { false }
}

extension AVAudioRecorder: AudioRecording {}

protocol MeteredAudioRecording: AudioRecording {
    func sampleAudioLevels() -> CaptureLevels?
}

/// Own this engine for the lifetime of the menu bar app. Handle initialization
/// and start errors in the UI; a failed recording never becomes active.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published var courseCode = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var microphoneDevices: [MicrophoneDevice] = []
    @Published private(set) var selectedMicrophoneID = ""
    @Published private(set) var defaultMicrophoneName: String?
    @Published private(set) var activeMicrophoneName: String?
    @Published private(set) var isMonitoring = false
    @Published private(set) var isFinishing = false
    /// Internal coordinator boundary; invoked after the encoder and marker work.
    var onSessionEnded: ((URL, Bool) -> Void)?
    var onMonitoringEnded: ((String?) -> Void)?

    private static let microphonePreference = "preferredMicrophoneID"
    private let ingestManager: IngestManager
    private let dependencies: Dependencies
    private let configuration = AudioConfig()
    private var recorder: (any AudioRecording)?
    private var outputURL: URL?
    private var durationTimer: Timer?
    private var monitor: (any MeteredAudioRecording)?
    private var publishOnFinish = true
    private var terminationDeferred = false
    private nonisolated let recordingFailures = RecordingFailureState()

    init(
        ingestManager: IngestManager? = nil,
        dependencies: Dependencies = .live
    ) throws {
        self.ingestManager = try ingestManager ?? IngestManager()
        self.dependencies = dependencies
        super.init()
        if dependencies.routesMicrophone {
            selectedMicrophoneID = UserDefaults.standard.string(forKey: Self.microphonePreference) ?? ""
            refreshMicrophones()
        }

        // AVCapture hosts defer termination via their AppKit delegate. This
        // notification also covers hosts using a synchronous recorder.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    // Swift 6 normally destroys actor-isolated instances from a nonisolated
    // context. Keep teardown on MainActor there so Timer, AVAudioRecorder,
    // and the injected finalization closure are released and flushed on the
    // same executor that owns the recording state. Swift 5.9 has no
    // `isolated deinit` syntax, so retain the synchronous compatibility path.
#if compiler(>=6.0)
    isolated deinit {
        durationTimer?.invalidate()
        monitor?.stop()
        if let recorder {
            recorder.delegate = nil
            recorder.stop()
            let failure = recordingFailures.finish(identity: ObjectIdentifier(recorder))
            if !recorder.finalizesAsynchronously, failure == nil, let outputURL {
                try? dependencies.writeManifest(outputURL)
            }
        }
        NotificationCenter.default.removeObserver(self)
    }
#else
    deinit {
        durationTimer?.invalidate()
        monitor?.stop()
        if let recorder {
            recorder.delegate = nil
            recorder.stop()
            let failure = recordingFailures.finish(identity: ObjectIdentifier(recorder))
            if !recorder.finalizesAsynchronously, failure == nil, let outputURL {
                try? dependencies.writeManifest(outputURL)
            }
        }
        NotificationCenter.default.removeObserver(self)
    }
#endif
    func refreshMicrophones() {
        let devices = MicrophoneCapture.devices().map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        let defaultName = (try? MicrophoneCapture.device(id: ""))?.localizedName
        if devices != microphoneDevices { microphoneDevices = devices }
        if defaultName != defaultMicrophoneName { defaultMicrophoneName = defaultName }
    }

    func selectMicrophone(_ id: String) {
        guard !isRecording, !isMonitoring, id != selectedMicrophoneID,
              id.isEmpty || microphoneDevices.contains(where: { $0.id == id }) else { return }
        selectedMicrophoneID = id
        UserDefaults.standard.set(id, forKey: Self.microphonePreference)
        errorMessage = nil
    }

    func startMonitoring() throws {
        guard !isRecording, !isMonitoring else { return }
        errorMessage = nil
        do {
            guard dependencies.hasMicrophoneUsageDescription() else {
                throw RecordingError.missingMicrophoneUsageDescription
            }
            guard dependencies.authorizationStatus() == .authorized else {
                throw RecordingError.microphonePermissionRequired
            }
            let (capture, name) = try makeMicrophoneCapture(url: nil)
            guard capture.prepareToRecord() else {
                capture.stop()
                throw RecordingError.failedToStart
            }
            monitor = capture
            activeMicrophoneName = name
            isMonitoring = true
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func stopMonitoring(failure: String? = nil) {
        guard let monitor else { return }
        monitor.stop()
        self.monitor = nil
        isMonitoring = false
        if !isRecording { activeMicrophoneName = nil }
        onMonitoringEnded?(failure)
    }

    func sampleAudioLevels() -> CaptureLevels? {
        guard !isFinishing else { return nil }
        return (recorder as? any MeteredAudioRecording ?? monitor)?.sampleAudioLevels()
    }

    private func makeMicrophoneCapture(url: URL?) throws -> (any MeteredAudioRecording, String) {
        try dependencies.makeMicrophone(selectedMicrophoneID, url, configuration.recorderSettings,
            { [weak self] identity, success in
                self?.recordingDidFinish(identity: identity, successfully: success)
            },
            { [weak self] identity, message in
                self?.recordingFailures.record(identity: identity, message: message)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let monitor = self.monitor, ObjectIdentifier(monitor) == identity {
                        self.errorMessage = message
                        self.stopMonitoring(failure: message)
                    } else {
                        self.failEncoding(identity: identity, message: message)
                    }
                }
            }
        )
    }

    /// The eventual app bundle must provide NSMicrophoneUsageDescription.
    /// Checking it here avoids a privacy exception in an unconfigured host.
    func requestPermission() async -> Bool {
        guard dependencies.hasMicrophoneUsageDescription() else {
            errorMessage = RecordingError.missingMicrophoneUsageDescription.localizedDescription
            return false
        }

        let granted: Bool
        switch dependencies.authorizationStatus() {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await dependencies.requestAccess()
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }

        errorMessage = granted ? nil : RecordingError.microphonePermissionRequired.localizedDescription
        return granted
    }

    /// Call requestPermission() before starting. Repeated starts are harmless.
    func startRecording(at localOutputURL: URL? = nil) throws {
        guard !isRecording else { return }

        errorMessage = nil
        do {
            guard dependencies.hasMicrophoneUsageDescription() else {
                throw RecordingError.missingMicrophoneUsageDescription
            }
            guard dependencies.authorizationStatus() == .authorized else {
                throw RecordingError.microphonePermissionRequired
            }

            let outputURL: URL
            if let localOutputURL {
                outputURL = localOutputURL
            } else {
                let course = courseCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard IngestManager.isValidCourseCode(course) else {
                    throw RecordingError.invalidCourseCode
                }
                try ingestManager.prepareDirectory()
                outputURL = ingestManager.makeOutputFileURL(courseCode: course)
            }
            // Minute-resolution names can collide after stopping and restarting.
            // AVAudioRecorder would otherwise replace an earlier lecture.
            guard !FileManager.default.fileExists(atPath: outputURL.path),
                  !FileManager.default.fileExists(atPath: RecordingManifest.readyURL(for: outputURL).path) else {
                throw RecordingError.outputAlreadyExists(outputURL.lastPathComponent)
            }

            stopMonitoring()
            let nextRecorder: any AudioRecording
            let microphoneName: String?
            if dependencies.routesMicrophone {
                let (capture, name) = try makeMicrophoneCapture(url: outputURL)
                nextRecorder = capture
                microphoneName = name
            } else {
                nextRecorder = try dependencies.makeRecorder(outputURL, configuration.recorderSettings)
                microphoneName = nil
            }
            nextRecorder.delegate = self
            recordingFailures.activate(identity: ObjectIdentifier(nextRecorder))

            guard nextRecorder.prepareToRecord() else {
                discardFailedStart(nextRecorder)
                throw RecordingError.failedToPrepare
            }
            guard nextRecorder.record() else {
                discardFailedStart(nextRecorder)
                throw RecordingError.failedToStart
            }

            recorder = nextRecorder
            self.outputURL = outputURL
            activeMicrophoneName = microphoneName
            publishOnFinish = true
            duration = 0
            isRecording = true
            startDurationTimer()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Keep the recording active until the encoder closes the file.
    func stopRecording() {
        endRecording(publishManifest: true)
    }

    /// Called by the menu bar host before AppKit terminates the app.
    func deferApplicationTermination() -> Bool {
        stopMonitoring()
        guard recorder?.finalizesAsynchronously == true else { return false }
        terminationDeferred = true
        stopRecording()
        return true
    }

    private func endRecording(publishManifest: Bool) {
        durationTimer?.invalidate()
        durationTimer = nil

        guard let recorder else { return }
        duration = max(duration, recorder.currentTime)
        if recorder.finalizesAsynchronously {
            publishOnFinish = publishOnFinish && publishManifest
            guard !isFinishing else { return }
            isFinishing = true
            recorder.stop()
        } else {
            recorder.delegate = nil
            recorder.stop()
            completeRecording(publishManifest: publishManifest)
        }
    }

    private func completeRecording(publishManifest: Bool) {
        let completedURL = outputURL
        var published = false
        if let recorder {
            recorder.delegate = nil
            let failure = recordingFailures.finish(identity: ObjectIdentifier(recorder))
            if let failure { errorMessage = failure }
            if publishManifest, failure == nil, let outputURL {
                do {
                    try dependencies.writeManifest(outputURL)
                    published = true
                } catch {
                    errorMessage = RecordingError.manifestWriteFailed(error.localizedDescription).localizedDescription
                }
            }
        }

        recorder = nil
        outputURL = nil
        activeMicrophoneName = nil
        isFinishing = false
        isRecording = false
        if let completedURL { onSessionEnded?(completedURL, published) }
        if terminationDeferred {
            terminationDeferred = false
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        recordingDidFinish(identity: ObjectIdentifier(recorder), successfully: flag)
    }

    nonisolated func recordingDidFinish(identity: ObjectIdentifier, successfully: Bool) {
        if !successfully {
            recordingFailures.record(
                identity: identity,
                message: RecordingError.recordingFailed.localizedDescription
            )
        }
        Task { @MainActor [weak self] in
            self?.finishRecording(identity: identity, successfully: successfully)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        let message = error?.localizedDescription ?? RecordingError.encodingFailed.localizedDescription
        recordingEncodingFailed(identity: ObjectIdentifier(recorder), message: message)
    }

    nonisolated func recordingEncodingFailed(identity: ObjectIdentifier, message: String) {
        recordingFailures.record(identity: identity, message: message)
        Task { @MainActor [weak self] in
            self?.failEncoding(identity: identity, message: message)
        }
    }

    func finishRecording(identity: ObjectIdentifier, successfully: Bool) {
        guard let recorder, ObjectIdentifier(recorder) == identity else { return }
        if !successfully {
            errorMessage = RecordingError.recordingFailed.localizedDescription
        }
        if recorder.finalizesAsynchronously {
            duration = max(duration, recorder.currentTime)
            durationTimer?.invalidate()
            durationTimer = nil
            completeRecording(publishManifest: successfully && publishOnFinish)
        } else {
            endRecording(publishManifest: successfully)
        }
    }

    func failEncoding(identity: ObjectIdentifier, message: String) {
        guard let recorder, ObjectIdentifier(recorder) == identity else { return }
        errorMessage = message
        endRecording(publishManifest: false)
    }

    private func startDurationTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, let recorder = self.recorder else { return }
                self.duration = max(self.duration, recorder.currentTime)
            }
        }
        durationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func discardFailedStart(_ recorder: any AudioRecording) {
        recorder.delegate = nil
        recorder.stop()
        _ = recordingFailures.finish(identity: ObjectIdentifier(recorder))
        recorder.deleteRecording()
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        stopRecording()
    }
}

extension AudioRecorder {
    /// System interactions are injectable so lifecycle tests never open the
    /// microphone. The app uses these live implementations by default.
    struct Dependencies {
        var hasMicrophoneUsageDescription: () -> Bool
        var authorizationStatus: () -> AVAuthorizationStatus
        var requestAccess: () async -> Bool
        var makeRecorder: (URL, [String: Any]) throws -> any AudioRecording
        var writeManifest: (URL) throws -> Void = { try RecordingManifest.write(for: $0) }
        var routesMicrophone = false
        var makeMicrophone: (String, URL?, [String: Any],
                             @escaping @Sendable (ObjectIdentifier, Bool) -> Void,
                             @escaping @Sendable (ObjectIdentifier, String) -> Void) throws -> (any MeteredAudioRecording, String) = {
            id, url, settings, finished, failed in
            let device = try MicrophoneCapture.device(id: id)
            let input = try MicrophoneCapture(device: device, url: url, settings: settings, onFinish: finished, onFailure: failed)
            return (input, device.localizedName)
        }

        static var live: Self {
            Self(
                hasMicrophoneUsageDescription: {
                    guard let description = Bundle.main.object(
                        forInfoDictionaryKey: "NSMicrophoneUsageDescription"
                    ) as? String else { return false }
                    return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                },
                authorizationStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
                requestAccess: { await AVCaptureDevice.requestAccess(for: .audio) },
                makeRecorder: { try AVAudioRecorder(url: $0, settings: $1) },
                routesMicrophone: true
            )
        }
    }

    enum RecordingError: LocalizedError {
        case missingMicrophoneUsageDescription
        case microphonePermissionRequired
        case microphoneUnavailable
        case invalidCourseCode
        case outputAlreadyExists(String)
        case failedToPrepare
        case failedToStart
        case recordingFailed
        case encodingFailed
        case manifestWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingMicrophoneUsageDescription:
                return "Add NSMicrophoneUsageDescription to the app's Info.plist before recording."
            case .microphonePermissionRequired:
                return "Allow microphone access in System Settings > Privacy & Security > Microphone."
            case .microphoneUnavailable:
                return "The selected microphone is unavailable. Reconnect it or choose another input."
            case .invalidCourseCode:
                return "Enter a course code using letters, numbers, spaces, underscores, or hyphens."
            case .outputAlreadyExists(let filename):
                return "A recording named \(filename) already exists. Wait until the next minute or use a different course code."
            case .failedToPrepare:
                return "The audio recorder could not prepare the output file."
            case .failedToStart:
                return "The audio recorder could not start recording."
            case .recordingFailed:
                return "Recording ended unexpectedly. The audio file may be incomplete."
            case .encodingFailed:
                return "The audio recorder encountered an encoding error."
            case .manifestWriteFailed(let reason):
                return "Audio was saved, but its completion marker could not be written: \(reason)"
            }
        }
    }
}

/// Delegate callbacks can arrive before their main-actor UI update runs. Latch
/// failures synchronously so a concurrent stop cannot publish failed audio.
private final class RecordingFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ObjectIdentifier?
    private var message: String?

    func activate(identity: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        self.identity = identity
        message = nil
    }

    func record(identity: ObjectIdentifier, message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.identity == identity else { return }
        self.message = message
    }

    func finish(identity: ObjectIdentifier) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard self.identity == identity else { return nil }
        self.identity = nil
        defer { message = nil }
        return message
    }
}

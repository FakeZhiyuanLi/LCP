import AVFoundation

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

struct AudioLevels {
    let averageDBFS: Float
    let peakDBFS: Float
}

/// An explicitly routed, local-only session. Mic Check runs an audio data
/// output and discards its buffers; recording runs the AAC file output.
final class MicrophoneCapture: NSObject, AudioRecording, AVCaptureFileOutputRecordingDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    // Serialize hardware transitions so a Mic Check is fully closed before
    // a subsequent recording opens the same device.
    private static let queue = DispatchQueue(label: "dev.lcp.microphone-capture", qos: .userInitiated)
    private let device: AVCaptureDevice
    private let fileOutput = AVCaptureAudioFileOutput()
    private let monitorOutput = AVCaptureAudioDataOutput()
    private let url: URL?
    private let encodingSettings: [String: Any]
    // Access only on queue. A file that closes without Stop/Quit must not be
    // mistaken for an intentionally completed lecture, even if it is playable.
    private var stopRequested = false
    private var observers: [any NSObjectProtocol] = []
    private let onFinish: @Sendable (ObjectIdentifier, Bool) -> Void
    private let onFailure: @Sendable (ObjectIdentifier, String) -> Void

    weak var delegate: (any AVAudioRecorderDelegate)?
    var finalizesAsynchronously: Bool { true }
    var currentTime: TimeInterval {
        let seconds = fileOutput.recordedDuration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.filter(\.isConnected)
    }

    static func device(id: String) throws -> AVCaptureDevice {
        let device = id.isEmpty
            ? AVCaptureDevice.default(for: .audio)
            : AVCaptureDevice(uniqueID: id)
        guard let device, device.isConnected, device.hasMediaType(.audio) else {
            throw AudioRecorder.RecordingError.microphoneUnavailable
        }
        return device
    }

    init(
        device: AVCaptureDevice,
        url: URL?,
        settings: [String: Any],
        onFinish: @escaping @Sendable (ObjectIdentifier, Bool) -> Void,
        onFailure: @escaping @Sendable (ObjectIdentifier, String) -> Void
    ) throws {
        self.device = device
        self.url = url
        self.encodingSettings = settings
        self.onFinish = onFinish
        self.onFailure = onFailure
        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AudioRecorder.RecordingError.failedToPrepare }
        session.addInput(input)
        if url == nil {
            guard session.canAddOutput(monitorOutput) else { throw AudioRecorder.RecordingError.failedToPrepare }
            monitorOutput.setSampleBufferDelegate(self, queue: Self.queue)
            session.addOutput(monitorOutput)
        } else {
            guard session.canAddOutput(fileOutput), AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.m4a) else {
                throw AudioRecorder.RecordingError.failedToPrepare
            }
            session.addOutput(fileOutput)
            // Attaching the output establishes its connection. Configuration
            // before attachment is discarded (audioSettings reads back nil).
            // Some devices finish negotiating only after startRunning; exact
            // acceptance is required there and immediately before file open.
            _ = CaptureFileEncoding.apply(settings, to: fileOutput)
        }
        guard audioConnection != nil else { throw AudioRecorder.RecordingError.failedToPrepare }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.reportFailure("The selected microphone was disconnected.")
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                self?.reportFailure("The microphone stopped responding.")
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func prepareToRecord() -> Bool {
        Self.queue.sync {
            guard device.isConnected else {
                session.stopRunning()
                return false
            }
            // Session startup negotiates the device's native audio format.
            // Reapply/verify encoding afterward, before any file is opened.
            if url == nil {
                session.startRunning()
                return session.isRunning
            }
            return CaptureFileEncoding.prepare(encodingSettings, output: fileOutput, startSession: {
                session.startRunning()
                return session.isRunning
            }, stopSession: { session.stopRunning() })
        }
    }

    func record() -> Bool {
        Self.queue.sync {
            guard let url else {
                session.stopRunning()
                return false
            }
            guard CaptureFileEncoding.readyToRecord(
                encodingSettings, output: fileOutput,
                sessionReady: device.isConnected && session.isRunning && fileOutput.connection(with: .audio)?.isActive == true,
                stopSession: { session.stopRunning() }
            ) else { return false }
            stopRequested = false
            fileOutput.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
            return true
        }
    }

    func stop() {
        if url == nil {
            // The coordinator may release the cross-process microphone lease
            // after this returns. Finish a monitor's closure synchronously.
            Self.queue.sync { session.stopRunning() }
        } else {
            Self.queue.async { [self] in
                stopRequested = true
                fileOutput.stopRecording()
            }
        }
    }

    @discardableResult
    func deleteRecording() -> Bool {
        // Before a successful start, no file was opened by this capture.
        // Never remove a file that appeared at the same URL concurrently.
        // Only discardFailedStart calls this method, from MainActor and before
        // a successful file start. Complete hardware cleanup before it returns
        // so the coordinator cannot release its lease while startup still owns
        // a live capture session. Active recordings use asynchronous didFinish.
        Self.queue.sync { session.stopRunning() }
        return true
    }

    func sampleAudioLevels() -> AudioLevels? {
        guard session.isRunning,
              let channels = audioConnection?.audioChannels,
              let average = channels.map(\.averagePowerLevel).filter(\.isFinite).max(),
              let peak = channels.map(\.peakHoldLevel).filter(\.isFinite).max() else { return nil }
        return AudioLevels(averageDBFS: average, peakDBFS: peak)
    }

    private var audioConnection: AVCaptureConnection? {
        (url == nil ? monitorOutput as AVCaptureOutput : fileOutput).connection(with: .audio)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // The file has closed. Check the actual format before allowing the
        // ready marker, including recordings cut short before any audio arrived.
        Self.queue.async { [self] in
            session.stopRunning()
            let problem = CaptureFileFinalization.problem(
                at: outputFileURL, stopRequested: stopRequested, error: error
            )
            if let problem { reportFailure(problem) }
            onFinish(ObjectIdentifier(self), problem == nil)
        }
    }

    private func reportFailure(_ message: String) {
        onFailure(ObjectIdentifier(self), message)
    }
}

/// The output may replace settings while negotiating a capture connection. Keep
/// reapplication and readback together, so an unsupported/reset format fails
/// before recording instead of silently using the device's 48 kHz defaults.
protocol CaptureFileAudioSettings: AnyObject {
    var audioSettings: [String: Any]? { get set }
}

extension AVCaptureAudioFileOutput: CaptureFileAudioSettings {}

enum CaptureFileEncoding {
    static func prepare(_ settings: [String: Any], output: any CaptureFileAudioSettings,
                        startSession: () -> Bool, stopSession: () -> Void) -> Bool {
        guard startSession(), apply(settings, to: output) else {
            stopSession()
            return false
        }
        return true
    }

    static func readyToRecord(_ settings: [String: Any], output: any CaptureFileAudioSettings,
                              sessionReady: Bool, stopSession: () -> Void) -> Bool {
        guard sessionReady, apply(settings, to: output) else {
            stopSession()
            return false
        }
        return true
    }

    static func apply(_ settings: [String: Any], to output: any CaptureFileAudioSettings) -> Bool {
        output.audioSettings = settings
        guard let accepted = output.audioSettings else { return false }
        return [AVFormatIDKey, AVSampleRateKey, AVNumberOfChannelsKey, AVEncoderBitRateKey, AVEncoderAudioQualityKey]
            .allSatisfy { key in
                guard let requested = settings[key] as? NSNumber, let actual = accepted[key] as? NSNumber else { return false }
                return requested == actual
            }
    }
}

enum CaptureFileFinalization {
    /// Called only after AVCaptureFileOutput reports all pending data written.
    /// Keep the strict source gate; a readable but incorrectly encoded file is
    /// preserved without a marker, and the UI reports its actual format.
    static func problem(at url: URL, stopRequested: Bool, error: Error?) -> String? {
        if let error {
            let failure = error as NSError
            return "The audio output could not finalize (\(failure.domain), code \(failure.code)). The audio was preserved without a completion marker."
        }
        guard stopRequested else {
            return "Recording ended without a Stop or Quit request. The audio was preserved without a completion marker."
        }
        guard let audio = try? AVAudioFile(forReading: url) else {
            return "The finalized audio could not be read. The file was preserved without a completion marker."
        }
        let format = audio.fileFormat
        guard format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              format.sampleRate == 16_000, format.channelCount == 1 else {
            return "The recording has an unexpected format (\(format.sampleRate.formatted()) Hz, \(format.channelCount) channels, codec \(format.streamDescription.pointee.mFormatID)); expected AAC, 16,000 Hz, mono. The audio was preserved without a completion marker."
        }
        guard audio.length > 0 else {
            return "The recording contains no audio frames. The file was preserved without a completion marker."
        }
        return nil
    }
}

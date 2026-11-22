import AVFoundation
import Darwin
import Foundation

private struct CheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

// The driver explicitly closes this real AAC writer after the peer has attempted
// Start. The engine handles its ordinary asynchronous completion callback.
private final class ToneRecorder: AudioRecording {
    weak var delegate: (any AVAudioRecorderDelegate)?
    let currentTime: TimeInterval = 1
    let finalizesAsynchronously = true
    private var writer: AVAudioFile?
    private(set) var stopRequested = false

    init(url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000),
              let samples = pcm.floatChannelData?[0] else { throw CheckFailure("PCM allocation failed") }
        pcm.frameLength = pcm.frameCapacity
        for index in 0..<Int(pcm.frameLength) {
            samples[index] = Float(0.1 * sin(2 * .pi * 440 * Double(index) / 16_000))
        }
        try file.write(from: pcm)
        writer = file
    }

    var writerIsOpen: Bool { writer != nil }
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { true }
    func stop() { stopRequested = true }
    func deleteRecording() -> Bool { false }

    func closeAfterStop() throws {
        try require(stopRequested && writerIsOpen, "Expected a stopped encoder awaiting close")
        guard let receiver = delegate as? AudioRecorder else { throw CheckFailure("Missing engine") }
        writer = nil
        receiver.recordingDidFinish(identity: ObjectIdentifier(self), successfully: true)
    }
}

@MainActor
private func waitFor(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while try !condition() {
        try require(ContinuousClock.now < deadline, "Timed out waiting for peer or encoder")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@main
private struct SavingPeerCheck {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, ["A", "B"].contains(args[1]) else { throw CheckFailure("Expected host A/B and fixture root") }
        let host = args[1]
        let root = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
        let tempRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        try require(root.deletingLastPathComponent().path == tempRoot.path
                    && root.lastPathComponent.hasPrefix("LCPSavingPeer-"), "Expected a private temporary fixture")
        let fm = FileManager.default
        let incoming = root.appendingPathComponent("Incoming")
        let configuration = CaptureConfiguration(stagingDirectory: incoming, catalogURL: root.appendingPathComponent("classes.json"),
                                                 leaseURL: root.appendingPathComponent("capture.lock"), legacyBundleURLs: [])
        var source: ToneRecorder?
        let engine = try AudioRecorder(ingestManager: IngestManager(stagingDirectory: incoming), dependencies: .init(
            hasMicrophoneUsageDescription: { true }, authorizationStatus: { .authorized }, requestAccess: { false },
            makeRecorder: { url, settings in
                let recorder = try ToneRecorder(url: url, settings: settings)
                source = recorder
                return recorder
            }))
        let capture = CaptureCoordinator(engine: engine, configuration: configuration,
                                         compatibilityCheck: { try CaptureCompatibility.check(configuration: configuration) })
        func signal(_ name: String, _ facts: [String: Any] = [:]) throws {
            let event = facts.merging(["host": host, "pid": getpid(), "uptimeNs": DispatchTime.now().uptimeNanoseconds,
                                       "state": capture.state.rawValue]) { _, new in new }
            try JSONSerialization.data(withJSONObject: event).write(to: root.appendingPathComponent(name), options: .atomic)
        }
        func wait(_ name: String) async throws {
            try await waitFor { fm.fileExists(atPath: root.appendingPathComponent(name).path) }
        }
        func files() throws -> [String] { try fm.contentsOfDirectory(atPath: incoming.path).sorted() }
        func start() async throws {
            try await capture.start(destinationID: "SavingPeer" + host, expectedDriveFolderID: "fixture_" + host)
        }

        if host == "B" {
            try await wait("A-saving.json")
            let before = try files()
            let ownerBefore = try Data(contentsOf: configuration.leaseURL)
            try require(before.count == 1 && before[0].hasPrefix("SavingPeerA_") && before[0].hasSuffix(".m4a"),
                        "Expected only A's open audio before the blocked Start")
            let attemptedAt = DispatchTime.now().uptimeNanoseconds
            do {
                try await start()
                throw CheckFailure("Peer Start succeeded during Saving")
            } catch CaptureError.captureInUse {
                try require(capture.state == .blocked && capture.activeSession == nil && capture.lastFinalized == nil
                            && source == nil, "Blocked peer reached recording or finalized state")
                try require(try before == files(), "Blocked Start created output")
                try require(try Data(contentsOf: configuration.leaseURL) == ownerBefore, "Blocked Start replaced lease owner")
                try signal("B-blocked.json", ["attemptedAtNs": attemptedAt, "error": "CaptureError.captureInUse",
                                              "message": capture.statusMessage ?? "", "stageEntries": before,
                                              "recorderConstructed": false, "leaseOwnerPreserved": true])
            }
            try await wait("A-finalized.json")
        }

        try await start()
        guard let session = capture.activeSession, let source else { throw CheckFailure("Missing recording/session") }
        try require(capture.state == .recording, "Start did not enter recording")
        try signal(host + "-recording.json", ["sessionID": session.id.uuidString])
        capture.stop()
        try require(capture.state == .finalizing && source.stopRequested && source.writerIsOpen, "Expected Saving with open encoder")
        if host == "A" {
            try signal("A-saving.json", ["sessionID": session.id.uuidString, "writerOpen": source.writerIsOpen])
            try await wait("B-blocked.json")
            try require(capture.state == .finalizing && source.writerIsOpen && capture.activeSession?.id == session.id,
                        "A left Saving during the peer Start")
            try require(try files().allSatisfy { !$0.hasSuffix(".ready.json") }, "Ready marker visible before close")
            try signal("A-closing.json", ["writerOpen": source.writerIsOpen, "sessionID": session.id.uuidString])
        }
        try source.closeAfterStop()
        try await waitFor { capture.state != .finalizing }
        guard capture.state == .idle, let result = capture.lastFinalized, result.session.id == session.id else {
            throw CheckFailure(capture.statusMessage ?? "Failed to finalize the correct session")
        }
        let reader = try AVAudioFile(forReading: result.audioURL)
        let format = reader.fileFormat
        try require(format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC && format.sampleRate == 16_000
                    && format.channelCount == 1 && reader.length > 0, "Finalized audio format failed validation")
        try signal(host + "-finalized.json", ["sessionID": session.id.uuidString, "filename": result.filename,
                                             "sizeBytes": result.sizeBytes, "sha256": result.sha256,
                                             "aac16kMono": true, "frames": reader.length])
        // Keep A alive until B reuses the lease, so process exit cannot explain release.
        if host == "A" { try await wait("B-finalized.json") }
    }
}

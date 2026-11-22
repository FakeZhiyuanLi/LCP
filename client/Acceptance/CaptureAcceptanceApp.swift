import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

/// Manual hardware checkpoint only. No app launch requests microphone access.
/// Both signed hosts call the production public coordinator with isolated data
/// and the ordinary shared lease. They never use AudioRecorder directly.
@main
@MainActor
struct CaptureAcceptanceApp: App {
    @NSApplicationDelegateAdaptor(AcceptanceDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            AcceptanceView(model: delegate.model)
        }.defaultSize(width: 720, height: 620)
    }
}

@MainActor
private final class AcceptanceDelegate: NSObject, NSApplicationDelegate {
    let model = AcceptanceModel()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareToTerminate() ? .terminateLater : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model.recordOrdinaryQuit() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct Fixture: Codable {
    let schemaVersion: Int
    let fictional: Bool
    let runID: String
    let entries: [FixtureEntry]
}

private struct FixtureEntry: Codable, Identifiable {
    let host: String
    let attempt: Int
    let courseCode: String
    let folderID: String
    let classID: UUID
    var id: String { courseCode }
}

private struct AcceptanceEvent: Encodable {
    let schemaVersion = 1
    let event: String
    let timestamp = Date()
    let monotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
    let runID: String
    let host: String
    let processID = ProcessInfo.processInfo.processIdentifier
    let state: String
    let detail: String?
    let sessionID: UUID?
    let academicClassID: UUID?
    let courseCode: String?
    let startedAt: Date?
    let timeZoneID: String?
    let filename: String?
    let sizeBytes: UInt64?
    let sha256: String?
}

@MainActor
private final class AcceptanceModel: ObservableObject {
    let host: String
    let runID: String
    let fixtureRoot: URL
    @Published private(set) var capture: CaptureCoordinator?
    @Published private(set) var entries: [FixtureEntry] = []
    @Published var selectedCourse = ""
    @Published private(set) var isStarting = false
    @Published private(set) var problem: String?
    @Published private(set) var receiptFailure: String?
    @Published private(set) var finalizedSummary: String?
    private var eventDescriptor: Int32 = -1
    private var subscriptions = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?
    private var quitRequested = false

    init() {
        let metadata = Bundle.main.infoDictionary ?? [:]
        host = metadata["LCPCaptureAcceptanceHost"] as? String ?? "invalid"
        runID = metadata["LCPCaptureAcceptanceRunID"] as? String ?? "invalid"
        fixtureRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LCP Capture/Acceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        do {
            guard ["A", "B"].contains(host), Self.validRunID(runID) else { throw AcceptanceError.invalidFixture }
            try Self.requireRealDirectory(fixtureRoot)
            let manifestURL = fixtureRoot.appendingPathComponent("fixture.json")
            let values = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 1_048_576 else { throw AcceptanceError.invalidFixture }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: manifestURL))
            guard fixture.schemaVersion == 1, fixture.fictional, fixture.runID == runID else { throw AcceptanceError.invalidFixture }
            entries = fixture.entries.filter { $0.host == host }.sorted { $0.attempt < $1.attempt }
            guard entries.count == 8, Set(entries.map(\.courseCode)).count == entries.count,
                  entries.allSatisfy({ $0.folderID == "lcp_acceptance_\(runID)_\(host)_\($0.attempt)"
                      && $0.courseCode == "LCPACCEPT_\(host)_\($0.attempt)" }) else { throw AcceptanceError.invalidFixture }
            selectedCourse = entries[0].courseCode
            let incoming = fixtureRoot.appendingPathComponent("Incoming", isDirectory: true)
            let events = fixtureRoot.appendingPathComponent("Events", isDirectory: true)
            try Self.requireRealDirectory(incoming)
            try Self.requireRealDirectory(events)
            let eventURL = events.appendingPathComponent("host-\(host)-\(getpid())-\(UUID().uuidString).jsonl")
            eventDescriptor = Darwin.open(eventURL.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard eventDescriptor >= 0 else { throw AcceptanceError.receiptUnavailable }
            let coordinator = try CaptureCoordinator(configuration: CaptureConfiguration(
                stagingDirectory: incoming,
                catalogURL: fixtureRoot.appendingPathComponent("classes.json"),
                leaseURL: CaptureConfiguration.live.leaseURL,
                legacyBundleURLs: CaptureConfiguration.live.legacyBundleURLs))
            capture = coordinator
            coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
            coordinator.$state.dropFirst().sink { [weak self] state in self?.record("state_changed", state: state.rawValue) }.store(in: &subscriptions)
            coordinator.$lastFinalized.compactMap { $0 }.sink { [weak self] finalized in
                guard let self else { return }
                self.record("finalized", session: finalized.session, finalized: finalized)
                self.finalizedSummary = "\(finalized.filename) · \(finalized.sizeBytes) bytes · SHA-256 \(finalized.sha256)"
            }.store(in: &subscriptions)
            record("launched", detail: "Manual fixture ready. Microphone not requested.")
        } catch {
            problem = error.localizedDescription
            if eventDescriptor >= 0 { Darwin.close(eventDescriptor); eventDescriptor = -1 }
        }
    }

    var canStart: Bool {
        guard let capture else { return false }
        return receiptFailure == nil && !quitRequested && !isStarting && capture.activeSession == nil
            && capture.state != .requestingPermission && capture.state != .finalizing && capture.catalogIsUsable
            && entries.contains { $0.courseCode == selectedCourse }
    }

    func start() {
        guard canStart, let capture, let entry = entries.first(where: { $0.courseCode == selectedCourse }) else { return }
        record("start_requested", detail: "Explicit user Start for \(entry.courseCode).")
        guard receiptFailure == nil else { return }
        isStarting = true
        problem = nil
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(destinationID: entry.courseCode, academicClassID: entry.classID, expectedDriveFolderID: entry.folderID)
                self.record("started", session: capture.activeSession)
            } catch {
                self.problem = error.localizedDescription
                self.record("start_blocked", detail: error.localizedDescription)
            }
            self.isStarting = false
            self.startTask = nil
            if self.quitRequested, !capture.deferApplicationTermination() {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    func stop() {
        record("stop_requested", session: capture?.activeSession)
        capture?.stop()
    }

    func refresh() {
        capture?.reloadDestinations()
        record("catalog_refreshed", detail: capture?.statusMessage)
    }

    func prepareToTerminate() -> Bool {
        record("quit_requested", session: capture?.activeSession)
        quitRequested = true
        if let startTask {
            startTask.cancel()
            return true
        }
        return capture?.deferApplicationTermination() ?? false
    }

    func recordOrdinaryQuit() {
        record("ordinary_quit", detail: "Normal AppKit termination; pending finalization completed.")
        if eventDescriptor >= 0 { Darwin.close(eventDescriptor); eventDescriptor = -1 }
    }

    private func record(_ event: String, state: String? = nil, detail: String? = nil,
                        session: CaptureSession? = nil, finalized: FinalizedCapture? = nil) {
        guard eventDescriptor >= 0 else { return }
        do {
            let value = AcceptanceEvent(event: event, runID: runID, host: host, state: state ?? capture?.state.rawValue ?? "unavailable",
                detail: detail, sessionID: session?.id, academicClassID: session?.academicClassID,
                courseCode: session?.destination.courseCode, startedAt: session?.startedAt, timeZoneID: session?.timeZoneIdentifier,
                filename: finalized?.filename, sizeBytes: finalized?.sizeBytes, sha256: finalized?.sha256)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var container = encoder.singleValueContainer()
                try container.encode(formatter.string(from: date))
            }
            var data = try encoder.encode(value)
            data.append(0x0A)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(eventDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw AcceptanceError.receiptUnavailable }
                    offset += written
                }
            }
            guard fsync(eventDescriptor) == 0 else { throw AcceptanceError.receiptUnavailable }
        } catch {
            receiptFailure = "Acceptance evidence could not be saved. Stop the test and retain its local files."
            if eventDescriptor >= 0 { Darwin.close(eventDescriptor); eventDescriptor = -1 }
            // Receipt failure must not allow unobserved manual test capture.
            if capture?.activeSession != nil { capture?.stop() }
        }
    }

    private static func validRunID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func requireRealDirectory(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.resolvingSymlinksInPath().path == standardized.path else { throw AcceptanceError.invalidFixture }
        let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AcceptanceError.invalidFixture }
    }
}

private enum AcceptanceError: LocalizedError {
    case invalidFixture, receiptUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidFixture: return "The isolated acceptance fixture is missing, unsafe, or does not match this signed host. Build a new run with build-capture-acceptance.sh."
        case .receiptUnavailable: return "The private acceptance event file could not be created or appended."
        }
    }
}

private struct AcceptanceView: View {
    @ObservedObject var model: AcceptanceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("LCP Capture Acceptance · Host \(model.host)").font(.title.bold())
            Text("Manual microphone test · isolated local recordings · run \(model.runID)").foregroundStyle(.secondary)
            Text("Opening this app does not start the microphone. Press Start only when you are ready to record a short fictional sentence. The shared lease also excludes the normal recorder and desktop.")
            Divider()
            LabeledContent("State", value: model.capture?.state.rawValue ?? "unavailable")
            LabeledContent("Catalog", value: model.capture?.catalogIsUsable == true ? "Valid" : "Unavailable or stale")
            LabeledContent("Duration", value: String(format: "%.1f seconds", model.capture?.duration ?? 0))
            Picker("Attempt", selection: $model.selectedCourse) {
                ForEach(model.entries) { entry in Text("\(entry.attempt) · \(entry.courseCode)").tag(entry.courseCode) }
            }.disabled(model.isStarting || model.capture?.activeSession != nil)
            Text("Use a new attempt for another recording in the same minute. Reusing an existing filename must fail without changing the first recording.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.isStarting ? "Requesting…" : "Start", action: model.start).buttonStyle(.borderedProminent).disabled(!model.canStart)
                Button("Stop", action: model.stop).disabled(model.capture?.activeSession == nil)
                Button("Refresh Catalog", action: model.refresh).disabled(model.isStarting || model.capture?.activeSession != nil)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            if let failure = model.receiptFailure ?? model.problem ?? model.capture?.statusMessage { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if let summary = model.finalizedSummary { Text(summary).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Spacer()
            Text(model.fixtureRoot.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Show Isolated Fixture") { NSWorkspace.shared.open(model.fixtureRoot) }
            Text("No Syncthing, transcription or Drive publication is configured for this fixture. Keep personal speech and test audio private.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 680, minHeight: 580)
    }
}

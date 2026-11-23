import Foundation
import OSLog
import os

/// One local reference follows a request through the UI, HTTP and decoding.
public struct AgentRequestDiagnostics: Sendable {
    public enum ChatStage: String, Sendable { case profiles, credential, context, generation, save }
    enum Operation: String { case connectionCheck, generate, stream }
    private static let log = Logger(subsystem: "org.lcp.Desktop", category: "Agent")
    public let id: UUID
    // URLSession invokes its delegate on a separate queue. Copies made by the UI,
    // transport and stream parser must all contribute to the same attempt.
    private let trace = OSAllocatedUnfairLock(initialState: Trace())

    private struct Trace: Sendable {
        var start: DispatchTime?
        var durationMS: UInt64?
        var requestBytes: Int?
        var idleSeconds = 0
        var totalSeconds = 0
        var httpStatus: Int?
        var headerMS: UInt64?
        var firstBodyMS: UInt64?
        var lastBodyMS: UInt64?
        var bodyBytes = 0
        var streamSummary: String?
        var transferSummary: String?

        var elapsedMS: UInt64? {
            start.map { (DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000 }
        }

        var timeoutPhase: AgentTimeoutPhase {
            if httpStatus == nil { return .beforeHeaders }
            return bodyBytes == 0 ? .beforeBody : .duringBody
        }

        var details: [String] {
            guard let requestBytes else { return [] }
            var lines = ["Request body: \(requestBytes) bytes",
                         "Timeouts: \(idleSeconds) s idle, \(totalSeconds) s total"]
            if let durationMS { lines.append("Elapsed: \(durationMS) ms") }
            if let httpStatus, let headerMS { lines.append("HTTP: \(httpStatus) after \(headerMS) ms") }
            else { lines.append("HTTP: no response headers") }
            lines.append("Response body: \(bodyBytes) bytes")
            if let firstBodyMS, let lastBodyMS {
                lines.append("Body timing: first \(firstBodyMS) ms, last \(lastBodyMS) ms")
            }
            if let streamSummary { lines.append("Stream: \(streamSummary)") }
            if let transferSummary { lines.append("Transport: \(transferSummary)") }
            return lines
        }
    }

    public init(id: UUID = UUID()) { self.id = id }

    public func chatStage(_ stage: ChatStage, failed: Bool = false, error: AgentProviderError? = nil) {
        if failed {
            Self.log.error("id=\(id.uuidString, privacy: .public) chat=\(stage.rawValue, privacy: .public) failed reason=\(error?.diagnosticCode ?? "local", privacy: .public)")
        } else {
            Self.log.info("id=\(id.uuidString, privacy: .public) chat=\(stage.rawValue, privacy: .public)")
        }
    }

    public func supportDetails(stage: ChatStage, error: AgentProviderError? = nil) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = ["LCP Desktop \(version) (\(build))", "Diagnostic ID: \(id.uuidString)", "Stage: \(stage.rawValue)"]
        if let error { lines.append("Reason: \(error.diagnosticCode)") }
        lines.append(contentsOf: trace.withLock { $0.details })
        return lines.joined(separator: "\n")
    }

    func sending(bodyBytes: Int, idle: TimeInterval, total: TimeInterval) {
        trace.withLock {
            $0.requestBytes = bodyBytes
            $0.idleSeconds = Int(idle)
            $0.totalSeconds = Int(total)
        }
        Self.log.notice("id=\(id.uuidString, privacy: .public) requestBodyBytes=\(bodyBytes) idleSeconds=\(Int(idle)) totalSeconds=\(Int(total))")
    }

    func received(_ response: HTTPURLResponse) {
        // Hosts, arbitrary headers and provider-supplied values can identify an account.
        let mime: String
        switch response.mimeType?.lowercased() {
        case "text/event-stream": mime = "sse"
        case "application/json": mime = "json"
        case "text/html": mime = "html"
        case nil: mime = "missing"
        default: mime = "other"
        }
        let elapsed = trace.withLock { state in
            state.httpStatus = response.statusCode
            state.headerMS = state.elapsedMS
            return state.headerMS ?? 0
        }
        Self.log.notice("id=\(id.uuidString, privacy: .public) http=\(response.statusCode) format=\(mime, privacy: .public) headersMS=\(elapsed)")
    }

    func receivedBody(bytes: Int) {
        guard bytes > 0 else { return }
        trace.withLock {
            $0.bodyBytes = bytes
            $0.lastBodyMS = $0.elapsedMS
            if $0.firstBodyMS == nil { $0.firstBodyMS = $0.lastBodyMS }
        }
    }

    func collected(_ metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last, transaction.resourceFetchType == .networkLoad else { return }
        func duration(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "unavailable" }
            return "\(Int(max(0, end.timeIntervalSince(start)) * 1_000))ms"
        }
        let timings = [
            "dns=\(duration(transaction.domainLookupStartDate, transaction.domainLookupEndDate))",
            "connect=\(duration(transaction.connectStartDate, transaction.connectEndDate))",
            "tls=\(duration(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate))",
            "uploadFinished=\(transaction.requestEndDate != nil)",
            "bodyBytesSent=\(transaction.countOfRequestBodyBytesSent)"
        ].joined(separator: " ")
        trace.withLock { $0.transferSummary = timings }
        Self.log.notice("id=\(id.uuidString, privacy: .public) transport=\(timings, privacy: .public)")
    }

    func streamSummary(_ parser: ProviderStreamParser) {
        trace.withLock { $0.streamSummary = "\(parser.format.rawValue), events=\(parser.events), last=\(parser.lastEvent.rawValue)" }
        Self.log.notice("id=\(id.uuidString, privacy: .public) wire=\(parser.format.rawValue, privacy: .public) bytes=\(parser.received) events=\(parser.events) lastEvent=\(parser.lastEvent.rawValue, privacy: .public)")
    }

    func run<T>(_ operation: Operation, _ perform: () async throws -> T) async throws -> T {
        trace.withLock { $0 = Trace(start: .now()) }
        func finish() -> UInt64 {
            trace.withLock {
                $0.durationMS = $0.elapsedMS
                return $0.durationMS ?? 0
            }
        }
        Self.log.notice("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) started")
        do {
            let result = try await perform()
            try Task.checkCancellation()
            let elapsed = finish()
            Self.log.notice("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) success elapsedMS=\(elapsed)")
            return result
        } catch {
            let elapsed = finish()
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                Self.log.notice("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) cancelled elapsedMS=\(elapsed)")
                throw CancellationError()
            }
            let failure: AgentProviderError
            if let provider = error as? AgentProviderError { failure = provider }
            else if case UniversityServiceError.http(let status) = error { failure = .http(status) }
            else if (error as? URLError)?.code == .timedOut { failure = .timeout(trace.withLock { $0.timeoutPhase }) }
            else if let network = error as? URLError {
                failure = network.code == .dataLengthExceedsMaximum ? .response(.outputTooLarge) : .network(network.errorCode)
            } else { failure = .requestFailed }
            Self.log.error("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) failure=\(failure.diagnosticCode, privacy: .public) elapsedMS=\(elapsed)")
            throw failure
        }
    }
}

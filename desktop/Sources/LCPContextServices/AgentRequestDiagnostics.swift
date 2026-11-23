import Foundation
import OSLog

/// One local reference follows a request through the UI, HTTP and decoding.
public struct AgentRequestDiagnostics: Sendable {
    public enum ChatStage: String, Sendable { case profiles, credential, context, generation, save }
    enum Operation: String { case connectionCheck, generate, stream }
    private static let log = Logger(subsystem: "org.lcp.Desktop", category: "Agent")
    public let id: UUID

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
        return lines.joined(separator: "\n")
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
        Self.log.notice("id=\(id.uuidString, privacy: .public) http=\(response.statusCode) format=\(mime, privacy: .public)")
    }

    func streamSummary(_ parser: ProviderStreamParser) {
        Self.log.notice("id=\(id.uuidString, privacy: .public) wire=\(parser.format.rawValue, privacy: .public) bytes=\(parser.received) events=\(parser.events) lastEvent=\(parser.lastEvent.rawValue, privacy: .public)")
    }

    func run<T>(_ operation: Operation, _ perform: () async throws -> T) async throws -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsedMS() -> UInt64 { (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        Self.log.notice("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) started")
        do {
            let result = try await perform()
            try Task.checkCancellation()
            Self.log.notice("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) success elapsedMS=\(elapsedMS())")
            return result
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                Self.log.notice("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) cancelled elapsedMS=\(elapsedMS())")
                throw CancellationError()
            }
            let failure: AgentProviderError
            if let provider = error as? AgentProviderError { failure = provider }
            else if case UniversityServiceError.http(let status) = error { failure = .http(status) }
            else if let network = error as? URLError {
                failure = network.code == .dataLengthExceedsMaximum ? .response(.outputTooLarge) : .network(network.errorCode)
            } else { failure = .requestFailed }
            Self.log.error("id=\(id.uuidString, privacy: .public) request=\(operation.rawValue, privacy: .public) failure=\(failure.diagnosticCode, privacy: .public) elapsedMS=\(elapsedMS())")
            throw failure
        }
    }
}

import Foundation
import LCPContextCore

public struct UniversityItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let metadata: [String: String]

    public init(id: String, title: String, detail: String, metadata: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.metadata = metadata
    }
}

public struct UniversityPage: Sendable {
    public let items: [UniversityItem]
    public let next: String?

    public init(items: [UniversityItem], next: String? = nil) {
        self.items = items
        self.next = next
    }
}

public struct UniversityDocument: Sendable {
    public let filename: String
    public let data: Data
    public let sourceURL: URL
    public let remoteID: String?
    public let courseworkContext: ImportedCourseworkContext?

    public init(filename: String, data: Data, sourceURL: URL, remoteID: String? = nil,
                courseworkContext: ImportedCourseworkContext? = nil) {
        self.filename = filename
        self.data = data
        self.sourceURL = sourceURL
        self.remoteID = remoteID
        self.courseworkContext = courseworkContext
    }
}

public enum UniversityServiceError: LocalizedError {
    case message(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .http(401): return "Your sign-in has expired or the access token is invalid. Reconnect this service."
        case .http(403): return "The service denied access. Check the connected account, API access, and permissions for this item."
        case .http(404): return "This item could not be found. Refresh the list and try again."
        case .http(429): return "The service is receiving too many requests. Please try again later."
        case .http(let code): return "The service returned HTTP \(code). Try again or open the item on its website."
        }
    }
}

/// University requests use isolated sessions and bounded response bodies.
public struct UniversityHTTP: Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.configuration = config
    }

    static func allows(_ url: URL, hosts: Set<String>) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, (parts.port ?? 443) == 443 else { return false }
        return hosts.contains(host) || hosts.contains { rule in
            rule.hasPrefix("*.") && host.hasSuffix(String(rule.dropFirst()))
        }
    }

    public func get(_ url: URL, bearer: String? = nil, allowedHosts: Set<String>,
                    limit: Int = 4_000_000) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url), bearer: bearer, allowedHosts: allowedHosts, limit: limit)
    }

    func postJSON(_ url: URL, body: Data, bearer: String, host: String) async throws -> Data {
        try await postJSONResponse(url, body: body, bearer: bearer, host: host).0
    }

    func postJSONResponse(_ url: URL, body: Data, bearer: String, host: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request, bearer: bearer, allowedHosts: [host], limit: 65_536)
    }

    func postJSONStream(_ url: URL, body: Data, bearer: String, host: String,
                        limit: Int, onResponse: @escaping @Sendable (HTTPURLResponse) -> Void) throws -> AsyncThrowingStream<Data, Error> {
        guard limit > 0, Self.allows(url, hosts: [host]), !bearer.isEmpty,
              bearer.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw UniversityServiceError.message("The service credential or destination is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let delegate = UniversityStreamingRequest(allowedHosts: [host], limit: limit,
                                                      continuation: continuation, onResponse: onResponse)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { @Sendable _ in session.invalidateAndCancel() }
            task.resume()
        }
    }

    private func send(_ input: URLRequest, bearer: String?, allowedHosts: Set<String>,
                      limit: Int) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = input.url, limit > 0, Self.allows(url, hosts: allowedHosts) else {
            throw UniversityServiceError.message("The service returned an unsupported download address.")
        }
        var request = input
        if let bearer {
            guard let host = url.host?.lowercased(), allowedHosts.contains(host),
                  !bearer.isEmpty, bearer.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw UniversityServiceError.message("The service credential or destination is invalid.")
            }
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        let (stream, result) = AsyncThrowingStream<(Data, HTTPURLResponse), Error>.makeStream()
        let delegate = UniversityResponse(allowedHosts: allowedHosts, limit: limit, result: result)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        result.onTermination = { @Sendable [weak task] _ in task?.cancel() }
        task.resume()
        for try await value in stream {
            try Task.checkCancellation()
            return value
        }
        throw CancellationError()
    }
}

/// URLSession serializes callbacks for a single request on its delegate queue.
final class UniversityResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let allowedHosts: Set<String>
    let limit: Int
    let result: AsyncThrowingStream<(Data, HTTPURLResponse), Error>.Continuation
    private var data = Data()
    private var crossedOrigin = false
    private var response: HTTPURLResponse?

    init(allowedHosts: Set<String>, limit: Int, result: AsyncThrowingStream<(Data, HTTPURLResponse), Error>.Continuation) {
        self.allowedHosts = allowedHosts
        self.limit = limit
        self.result = result
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard task.originalRequest?.httpMethod == "GET" else {
            result.finish(throwing: UniversityServiceError.message("The service redirected a folder creation request. Try again."))
            completionHandler(nil)
            return
        }
        guard let url = request.url, UniversityHTTP.allows(url, hosts: allowedHosts) else {
            result.finish(throwing: UniversityServiceError.message("The service redirected to an unsupported address."))
            completionHandler(nil)
            return
        }
        if url.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() { crossedOrigin = true }
        var next = request
        next.setValue(crossedOrigin ? nil : task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
                      forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url, UniversityHTTP.allows(url, hosts: allowedHosts) else {
            result.finish(throwing: UniversityServiceError.message("The service returned an invalid response."))
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            result.finish(throwing: UniversityServiceError.http(http.statusCode))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= Int64(limit) else {
            result.finish(throwing: UniversityServiceError.message("This item exceeds the import size limit."))
            completionHandler(.cancel)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= limit - data.count else {
            result.finish(throwing: UniversityServiceError.message("This item exceeds the import size limit."))
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // A failing URL can contain a private query or signed download address.
            result.finish(throwing: UniversityServiceError.message("Could not reach the service. Check the network and try again. (\((error as NSError).code))"))
        } else if let response {
            result.yield((data, response))
            result.finish()
        } else {
            result.finish(throwing: UniversityServiceError.message("The service returned an incomplete response."))
        }
    }
}

/// Streams bounded POST response chunks without buffering provider output.
final class UniversityStreamingRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let limit: Int
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let onResponse: @Sendable (HTTPURLResponse) -> Void
    private var received = 0

    init(allowedHosts: Set<String>, limit: Int, continuation: AsyncThrowingStream<Data, Error>.Continuation,
         onResponse: @escaping @Sendable (HTTPURLResponse) -> Void) {
        self.allowedHosts = allowedHosts
        self.limit = limit
        self.continuation = continuation
        self.onResponse = onResponse
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        continuation.finish(throwing: URLError(.redirectToNonExistentLocation))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              UniversityHTTP.allows(url, hosts: allowedHosts) else {
            continuation.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        onResponse(http)
        guard (200..<300).contains(http.statusCode) else {
            continuation.finish(throwing: UniversityServiceError.http(http.statusCode))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(limit) else {
            continuation.finish(throwing: URLError(.dataLengthExceedsMaximum))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard received <= limit - chunk.count else {
            continuation.finish(throwing: URLError(.dataLengthExceedsMaximum))
            dataTask.cancel()
            return
        }
        received += chunk.count
        continuation.yield(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}

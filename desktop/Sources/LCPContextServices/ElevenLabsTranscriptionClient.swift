import CryptoKit
import Foundation
import LCPContextCore

/// A transcript returned by ElevenLabs before it is attached to a local
/// lecture record. The caller owns persistence and source identity.
public struct ElevenLabsTranscriptionResult: Equatable, Sendable {
    public let languageCode: String
    public let duration: Double
    public let cues: [TranscriptCue]
    public let audioEvents: [TranscriptAudioEvent]

    public init(languageCode: String, duration: Double, cues: [TranscriptCue],
                audioEvents: [TranscriptAudioEvent] = []) {
        self.languageCode = languageCode
        self.duration = duration
        self.cues = cues
        self.audioEvents = audioEvents
    }
}

public enum ElevenLabsTranscriptionError: LocalizedError, Equatable, Sendable {
    case invalidAPIKey
    case invalidAudio
    case responseTooLarge
    case invalidResponse
    case emptyTranscript
    case http(Int)
    case network(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Enter an ElevenLabs API key without spaces or line breaks."
        case .invalidAudio:
            return "The selected lecture audio is unavailable or exceeds the local transcription limit."
        case .responseTooLarge:
            return "ElevenLabs returned a response that was too large for LCP to store safely."
        case .invalidResponse:
            return "ElevenLabs returned an invalid or incomplete transcript."
        case .emptyTranscript:
            return "ElevenLabs returned no spoken transcript for this recording."
        case .http(401):
            return "ElevenLabs rejected the API key. Check the key and reconnect."
        case .http(403):
            return "ElevenLabs denied this request. Check the key permissions and account access."
        case .http(429):
            return "ElevenLabs is rate limiting requests. Try again later."
        case .http(let status):
            return "ElevenLabs returned HTTP \(status). Try again later."
        case .network:
            return "LCP could not reach ElevenLabs. Check the network and try again."
        }
    }
}

/// Bounded ElevenLabs Scribe access for a user-owned local library.
///
/// The key is supplied by the caller and is never written to a request body,
/// transcript payload, diagnostic, or library state. Audio is sent to
/// ElevenLabs for this operation and the parsed result is returned to LCP.
public struct ElevenLabsTranscriptionClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    public static let maximumAudioBytes: UInt64 = 512 * 1_024 * 1_024
    public static let maximumResponseBytes = 64 * 1_024 * 1_024

    private let apiKey: String
    private let endpoint: URL
    private let configuration: URLSessionConfiguration

    public init(apiKey: String, endpoint: URL = Self.defaultEndpoint,
                configuration: URLSessionConfiguration = .ephemeral) throws {
        self.apiKey = try Self.validateAPIKey(apiKey)
        guard Self.isSupportedEndpoint(endpoint) else {
            throw ElevenLabsTranscriptionError.invalidResponse
        }
        self.endpoint = endpoint
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpShouldSetCookies = false
        copy.httpCookieStorage = nil
        copy.urlCredentialStorage = nil
        copy.urlCache = nil
        copy.httpAdditionalHeaders = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.timeoutIntervalForRequest = 60
        copy.timeoutIntervalForResource = 900
        self.configuration = copy
    }

    public static func validateAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 16_384,
              key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw ElevenLabsTranscriptionError.invalidAPIKey
        }
        return key
    }

    /// Performs a credential-only request. No audio or class context is sent.
    public func checkConnection() async throws {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user") else {
            throw ElevenLabsTranscriptionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (body, response) = try await requestData(request)
        try Self.validateResponse(response, body: body)
    }

    public func transcribe(audioURL: URL, expectedSize: UInt64? = nil,
                           expectedSHA256: String? = nil) async throws -> ElevenLabsTranscriptionResult {
        let size = try Self.audioSize(audioURL)
        if let expectedSize, expectedSize != size { throw ElevenLabsTranscriptionError.invalidAudio }
        if let expectedSHA256, try Self.digest(audioURL, size: size) != expectedSHA256 {
            throw ElevenLabsTranscriptionError.invalidAudio
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCP-ElevenLabs-\(UUID().uuidString)", isDirectory: true)
        let multipart = directory.appendingPathComponent("request.multipart", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let boundary = "lcp-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try Self.writeMultipart(audioURL: audioURL, size: size, boundary: boundary, to: multipart)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(try FileManager.default.attributesOfItem(atPath: multipart.path)[.size] as? NSNumber ?? 0)",
                         forHTTPHeaderField: "Content-Length")

        let body: Data
        let response: HTTPURLResponse
        do {
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let result = try await session.upload(for: request, fromFile: multipart)
            guard let http = result.1 as? HTTPURLResponse else {
                throw ElevenLabsTranscriptionError.invalidResponse
            }
            body = result.0
            response = http
        } catch let error as ElevenLabsTranscriptionError {
            throw error
        } catch let error as URLError {
            throw ElevenLabsTranscriptionError.network(error.errorCode)
        } catch {
            throw ElevenLabsTranscriptionError.network((error as NSError).code)
        }
        if try Self.audioSize(audioURL) != size ||
            (expectedSHA256 != nil && (try Self.digest(audioURL, size: size)) != expectedSHA256) {
            throw ElevenLabsTranscriptionError.invalidAudio
        }
        try Self.validateResponse(response, body: body)
        return try Self.parse(body)
    }

    private func requestData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ElevenLabsTranscriptionError.invalidResponse
            }
            return (body, http)
        } catch let error as ElevenLabsTranscriptionError {
            throw error
        } catch let error as URLError {
            throw ElevenLabsTranscriptionError.network(error.errorCode)
        } catch {
            throw ElevenLabsTranscriptionError.network((error as NSError).code)
        }
    }

    private static func validateResponse(_ response: HTTPURLResponse, body: Data) throws {
        guard body.count <= maximumResponseBytes else { throw ElevenLabsTranscriptionError.responseTooLarge }
        guard (200..<300).contains(response.statusCode) else {
            throw ElevenLabsTranscriptionError.http(response.statusCode)
        }
    }

    private static func isSupportedEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "api.elevenlabs.io",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil else { return false }
        return components.path == "/v1/speech-to-text"
    }

    private static func audioSize(_ url: URL) throws -> UInt64 {
        guard url.isFileURL, !url.path.isEmpty, !url.path.contains("\0") else {
            throw ElevenLabsTranscriptionError.invalidAudio
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0,
              UInt64(fileSize) <= maximumAudioBytes else {
            throw ElevenLabsTranscriptionError.invalidAudio
        }
        return UInt64(fileSize)
    }

    private static func digest(_ url: URL, size: UInt64) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var read: UInt64 = 0
        while read < size {
            let chunk = try input.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty, read + UInt64(chunk.count) <= size else {
                throw ElevenLabsTranscriptionError.invalidAudio
            }
            hasher.update(data: chunk)
            read += UInt64(chunk.count)
        }
        guard read == size else { throw ElevenLabsTranscriptionError.invalidAudio }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeMultipart(audioURL: URL, size: UInt64, boundary: String, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        func append(_ value: Data) throws { try output.write(contentsOf: value) }
        func field(_ name: String, _ value: String) throws {
            try append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        try field("model_id", "scribe_v2")
        try field("diarize", "true")
        try field("timestamps_granularity", "word")
        let filename = audioURL.lastPathComponent.replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        try append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }
        var copied: UInt64 = 0
        while copied < size {
            let chunk = try input.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty, copied + UInt64(chunk.count) <= size else {
                throw ElevenLabsTranscriptionError.invalidAudio
            }
            try append(chunk)
            copied += UInt64(chunk.count)
        }
        try append(Data("\r\n--\(boundary)--\r\n".utf8))
    }

    private static func parse(_ data: Data) throws -> ElevenLabsTranscriptionResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElevenLabsTranscriptionError.invalidResponse
        }
        let language = (object["language_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? (object["language_code"] as! String) : "en"
        let declaredDuration = number(object["audio_duration_secs"]) ?? number(object["duration"])

        let rawWords = object["words"] as? [[String: Any]]
        var events: [TranscriptAudioEvent] = []
        var words: [TranscriptCue] = []
        var wordsValid = rawWords != nil
        if let rawWords {
            for item in rawWords {
                let type = item["type"] as? String
                // Scribe includes formatting-only spacing entries between
                // spoken words. They do not participate in speech ordering or
                // transcript cues. Older responses may omit `type`, which is
                // treated as a spoken word for compatibility.
                if type == "spacing" { continue }
                guard type == nil || type == "word" || type == "audio_event" else {
                    wordsValid = false
                    continue
                }
                guard let start = number(item["start"]), let end = number(item["end"]),
                      start.isFinite, end.isFinite, start >= 0, end > start else {
                    wordsValid = false
                    continue
                }
                let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if type == "audio_event" {
                    guard !text.isEmpty, text.utf8.count <= 65_536 else { wordsValid = false; continue }
                    events.append(TranscriptAudioEvent(start: start, end: end, text: text))
                } else {
                    guard !text.isEmpty, text.utf8.count <= 65_536 else { wordsValid = false; continue }
                    let speaker = (item["speaker_id"] as? String) ?? (item["speaker"] as? String)
                    words.append(TranscriptCue(start: start, end: end, text: text, speaker: speaker))
                }
            }
            wordsValid = wordsValid && isOrdered(words)
        }
        if let rawEvents = object["audio_events"] as? [[String: Any]] {
            for item in rawEvents {
                guard let start = number(item["start"]), let end = number(item["end"]),
                      start.isFinite, end.isFinite, start >= 0, end > start,
                      let rawText = item["text"] as? String else {
                    throw ElevenLabsTranscriptionError.invalidResponse
                }
                let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.utf8.count <= 65_536 else {
                    throw ElevenLabsTranscriptionError.invalidResponse
                }
                events.append(TranscriptAudioEvent(start: start, end: end, text: text))
            }
        }

        if !wordsValid || words.isEmpty {
            words = try parseSegments(object["segments"] as? [[String: Any]])
        }
        guard !words.isEmpty else { throw ElevenLabsTranscriptionError.emptyTranscript }
        let maximumEnd = max(words.map(\.end).max() ?? 0, events.map(\.end).max() ?? 0)
        let duration = max(declaredDuration ?? 0, maximumEnd)
        guard duration.isFinite, duration > 0 else { throw ElevenLabsTranscriptionError.invalidResponse }
        guard words.allSatisfy({ $0.end <= duration + 0.001 }), events.allSatisfy({ $0.end <= duration + 0.001 }) else {
            throw ElevenLabsTranscriptionError.invalidResponse
        }
        return ElevenLabsTranscriptionResult(languageCode: language, duration: duration, cues: words,
                                             audioEvents: events.sorted { $0.start < $1.start })
    }

    private static func parseSegments(_ segments: [[String: Any]]?) throws -> [TranscriptCue] {
        guard let segments, !segments.isEmpty else { throw ElevenLabsTranscriptionError.invalidResponse }
        var cues: [TranscriptCue] = []
        for item in segments {
            guard let start = number(item["start"]), let end = number(item["end"]),
                  start.isFinite, end.isFinite, start >= 0, end > start,
                  let rawText = item["text"] as? String else { throw ElevenLabsTranscriptionError.invalidResponse }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 65_536 else { throw ElevenLabsTranscriptionError.invalidResponse }
            let speaker = (item["speaker_id"] as? String) ?? (item["speaker"] as? String)
            cues.append(TranscriptCue(start: start, end: end, text: text, speaker: speaker))
        }
        guard isOrdered(cues) else { throw ElevenLabsTranscriptionError.invalidResponse }
        return cues
    }

    private static func isOrdered(_ cues: [TranscriptCue]) -> Bool {
        var previousStart = -1.0
        for cue in cues {
            guard cue.start >= previousStart else { return false }
            previousStart = cue.start
        }
        return true
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

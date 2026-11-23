import Foundation
import LCPContextCore

/// Decodes the Responses API's SSE wire format, or one JSON response from
/// gateways that ignore stream=true. Only SSE data fields belong to the JSON.
struct ProviderStreamParser {
    enum Format: String { case undecided, sse, json }
    // Only these locally defined event names can reach the diagnostic log.
    enum Event: String {
        case none, other, done, json, error
        case created = "response.created", inProgress = "response.in_progress"
        case textDelta = "response.output_text.delta", textDone = "response.output_text.done"
        case refusalDelta = "response.refusal.delta", refusalDone = "response.refusal.done"
        case itemAdded = "response.output_item.added", itemDone = "response.output_item.done"
        case argumentsDelta = "response.function_call_arguments.delta", argumentsDone = "response.function_call_arguments.done"
        case completed = "response.completed", incomplete = "response.incomplete", failed = "response.failed"
    }

    static let byteLimit = 3_500_000
    private static let unsupportedControls = CharacterSet.controlCharacters.subtracting(.newlines)
    private(set) var format = Format.undecided
    private(set) var received = 0
    private(set) var events = 0
    private(set) var lastEvent = Event.none
    private var line: [UInt8] = []
    private var firstLine = true
    private var previousCR = false
    private var dataFields: [String] = []
    private var eventName = Event.none
    private var jsonBody = Data()
    private var completed = false
    private var text = ""
    private var finalParts: [String] = []
    private var displays = ProviderDisplayCalls()
    private var requestID: String?
    private var usage: TokenUsage?
    let onUpdate: @Sendable (AgentProviderStreamUpdate) -> Void

    init(onUpdate: @escaping @Sendable (AgentProviderStreamUpdate) -> Void) { self.onUpdate = onUpdate }

    mutating func consume(_ chunk: Data) throws {
        guard chunk.count <= Self.byteLimit - received else { throw AgentProviderError.response(.outputTooLarge) }
        received += chunk.count
        // CR, LF and CRLF are all SSE line endings. Network chunks may split a
        // CRLF pair or a multibyte character anywhere.
        for byte in chunk {
            switch byte {
            case 13: try consumeLine(); previousCR = true
            case 10:
                if !previousCR { try consumeLine() }
                previousCR = false
            default: line.append(byte); previousCR = false
            }
        }
    }

    private mutating func consumeLine() throws {
        guard var value = String(bytes: line, encoding: .utf8) else { throw AgentProviderError.response(.invalidEncoding) }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if value.first == "\u{FEFF}" { value.removeFirst() }
        }
        if format == .undecided {
            let start = value.drop(while: { $0 == " " || $0 == "\t" })
            guard !start.isEmpty else { return }
            guard start.first != "<" else { throw AgentProviderError.response(.unexpectedFormat) }
            format = start.first == "{" ? .json : .sse
        }
        if format == .json {
            jsonBody.append(contentsOf: value.utf8)
            jsonBody.append(10)
            return
        }
        if value.isEmpty { try dispatchEvent(); return }
        let fields = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let field = fields.first, field == "data" || field == "event" else { return }
        var payload = fields.count == 2 ? fields[1] : Substring()
        if payload.first == " " { payload = payload.dropFirst() }
        if field == "data" { dataFields.append(String(payload)) }
        else { eventName = Event(rawValue: String(payload)) ?? .other }
    }

    private mutating func dispatchEvent() throws {
        let name = eventName
        eventName = .none
        guard !dataFields.isEmpty else { return }
        let raw = dataFields.joined(separator: "\n")
        dataFields.removeAll(keepingCapacity: true)
        events += 1
        lastEvent = name
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            completed = true
            lastEvent = .done
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw AgentProviderError.response(.malformedEvent)
        }
        let type = (object["type"] as? String).map { Event(rawValue: $0) ?? .other } ?? name
        try accept(object, type: type)
    }

    private mutating func accept(_ object: [String: Any], type: Event) throws {
        lastEvent = type
        let response = object["response"] as? [String: Any] ?? object
        if let id = response["id"] as? String { requestID = id }
        if let counts = OpenAICompatibleAgentClient.usage(from: response["usage"] as? [String: Any]) { usage = counts }
        try OpenAICompatibleAgentClient.checkStatus(response)
        switch type {
        case .itemAdded, .itemDone:
            if let item = object["item"] as? [String: Any], let index = object["output_index"] as? Int {
                displays.item(item, index: index, complete: type == .itemDone)
            }
        case .argumentsDelta, .argumentsDone:
            displays.arguments(object, complete: type == .argumentsDone)
        case .error, .failed: throw AgentProviderError.response(.providerFailure)
        case .incomplete: throw OpenAICompatibleAgentClient.incompleteResponse(response)
        case .textDelta, .refusalDelta:
            guard let delta = object["delta"] as? String else { throw AgentProviderError.response(.malformedEvent) }
            try append(delta)
        case .textDone, .refusalDone:
            if let value = (object["text"] ?? object["refusal"]) as? String { finalParts.append(value) }
        case .completed, .json:
            completed = true
            displays.response(response)
            if text.isEmpty, let final = OpenAICompatibleAgentClient.responseText(from: response) { try append(final) }
        case .none:
            // Some compatible gateways emit data-only chat-completion chunks.
            if let choice = (object["choices"] as? [[String: Any]])?.first {
                if let part = (choice["delta"] as? [String: Any])?["content"] as? String { try append(part) }
                if let reason = choice["finish_reason"] as? String {
                    if reason == "length" { throw AgentProviderError.response(.tokenLimit) }
                    completed = true
                }
            } else if let delta = object["delta"] as? String {
                try append(delta)
            } else if let final = OpenAICompatibleAgentClient.responseText(from: response) {
                completed = true
                if text.isEmpty { try append(final) }
            }
        default: break
        }
    }

    mutating func finish() throws -> AgentProviderGenerationResult {
        if !line.isEmpty { try consumeLine() }
        if format == .json {
            guard let object = try? JSONSerialization.jsonObject(with: jsonBody) as? [String: Any] else {
                throw AgentProviderError.response(.malformedJSON)
            }
            try accept(object, type: .json)
        } else { try dispatchEvent() }
        guard completed else {
            throw AgentProviderError.response(events == 0 ? .unexpectedFormat : .incomplete)
        }
        if text.isEmpty, !finalParts.isEmpty { try append(finalParts.joined(separator: "\n\n")) }
        let graphics = displays.markdown()
        if !graphics.isEmpty { try append((text.isEmpty ? "" : "\n\n") + graphics) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentProviderError.response(.noText) }
        onUpdate(AgentProviderStreamUpdate(text: text, requestID: requestID, usage: usage, finished: true))
        return AgentProviderGenerationResult(text: text, requestID: requestID, usage: usage)
    }

    private mutating func append(_ delta: String) throws {
        guard !delta.isEmpty else { return }
        guard delta.utf8.count <= Self.byteLimit - text.utf8.count else { throw AgentProviderError.response(.outputTooLarge) }
        guard delta.rangeOfCharacter(from: Self.unsupportedControls) == nil else { throw AgentProviderError.response(.invalidText) }
        text.append(delta)
        onUpdate(AgentProviderStreamUpdate(delta: delta, text: text, requestID: requestID, usage: usage))
    }
}

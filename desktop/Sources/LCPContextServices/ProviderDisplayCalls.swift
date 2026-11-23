import Foundation
import LCPContextCore

/// Responses repeats function calls in item events and in its terminal response.
struct ProviderDisplayCalls {
    private struct Call {
        var itemID: String?
        var callID: String?
        var name: String?
        var arguments = ""
        var invalid = false
    }

    private var calls: [Int: Call] = [:]
    private var reasoning: [Int: Data] = [:]
    private var overflow = false
    private static let limit = 4
    private static let unavailable = "LCP could not display one of the requested visuals."

    mutating func item(_ item: [String: Any], index: Int, complete: Bool) {
        if complete, item["type"] as? String == "reasoning", reasoning.count < 8,
           let data = try? JSONSerialization.data(withJSONObject: item), data.count <= 262_144 {
            reasoning[index] = data
        }
        guard item["type"] as? String == "function_call" else { return }
        let itemID = item["id"] as? String ?? item["call_id"] as? String
        guard let slot = slot(index: index, itemID: itemID) else { return }
        var call = calls[slot] ?? Call()
        call.itemID = itemID ?? call.itemID
        if let id = item["call_id"] as? String, !id.isEmpty, id.utf8.count <= 256 { call.callID = id }
        if let name = item["name"] as? String { call.name = name }
        if let arguments = item["arguments"] as? String, complete || !arguments.isEmpty {
            setArguments(arguments, on: &call)
        }
        calls[slot] = call
    }

    mutating func arguments(_ event: [String: Any], complete: Bool) {
        let itemID = event["item_id"] as? String
        guard let slot = slot(index: event["output_index"] as? Int, itemID: itemID) else { return }
        var call = calls[slot] ?? Call()
        call.itemID = itemID ?? call.itemID
        if let name = event["name"] as? String { call.name = name }
        if let part = event[complete ? "arguments" : "delta"] as? String {
            if complete { setArguments(part, on: &call) }
            else if part.utf8.count <= AgentVisual.byteLimit - call.arguments.utf8.count, !call.invalid {
                call.arguments.append(part)
            } else { call.invalid = true }
        }
        calls[slot] = call
    }

    mutating func response(_ object: [String: Any]) {
        for (index, item) in (object["output"] as? [[String: Any]] ?? []).enumerated() {
            self.item(item, index: index, complete: true)
        }
    }

    private mutating func slot(index: Int?, itemID: String?) -> Int? {
        if let itemID, let found = calls.first(where: { $0.value.itemID == itemID }) { return found.key }
        guard let index, index >= 0, calls[index] != nil || calls.count < Self.limit else {
            overflow = true
            return nil
        }
        return index
    }

    private func setArguments(_ value: String, on call: inout Call) {
        guard value.utf8.count <= AgentVisual.byteLimit else { call.invalid = true; return }
        call.arguments = value
    }

    var continuation: ProviderFileContinuation? {
        guard calls.values.contains(where: { $0.name == ChatFilingTool.name }) else { return nil }
        let entries = calls.keys.sorted().compactMap { index -> ProviderFileContinuation.Call? in
            guard let call = calls[index], let name = call.name, !call.invalid else { return nil }
            return .init(id: call.callID, name: name, arguments: call.arguments)
        }
        return .init(calls: entries, reasoning: reasoning.keys.sorted().compactMap { reasoning[$0] })
    }

    var filingSuggestions: [ChatFilingSuggestion] {
        calls.keys.sorted().compactMap { index in
            guard let call = calls[index], !call.invalid, call.name == ChatFilingTool.name else { return nil }
            return try? ChatFilingTool.suggestion(arguments: Data(call.arguments.utf8))
        }
    }

    func markdown() -> String {
        var blocks: [String] = []
        var omitted = overflow
        for index in calls.keys.sorted() {
            if calls[index]?.name == ChatFilingTool.name { continue }
            guard let call = calls[index], !call.invalid, let name = call.name,
                  let tool = AgentDisplayTool(rawValue: name),
                  let block = try? tool.render(arguments: Data(call.arguments.utf8)).markdown() else {
                omitted = true
                continue
            }
            blocks.append(block)
        }
        if omitted { blocks.append(Self.unavailable) }
        return blocks.joined(separator: "\n\n")
    }
}

import Foundation

/// Responses repeats function calls in item events and in its terminal response.
struct ProviderDisplayCalls {
    private struct Call {
        var itemID: String?
        var name: String?
        var arguments = ""
        var invalid = false
    }

    private var calls: [Int: Call] = [:]
    private var overflow = false
    private static let limit = 4
    private static let unavailable = "LCP could not display one of the requested visuals."

    mutating func item(_ item: [String: Any], index: Int, complete: Bool) {
        guard item["type"] as? String == "function_call" else { return }
        let itemID = item["id"] as? String ?? item["call_id"] as? String
        guard let slot = slot(index: index, itemID: itemID) else { return }
        var call = calls[slot] ?? Call()
        call.itemID = itemID ?? call.itemID
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

    func markdown() -> String {
        var blocks: [String] = []
        var omitted = overflow
        for index in calls.keys.sorted() {
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

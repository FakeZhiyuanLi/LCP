import Foundation
import LCPContextCore

/// Transient Responses items for the next round at the same provider. Never written to chat history.
struct ProviderFileContinuation: Equatable, Sendable {
    struct Call: Equatable, Sendable {
        let id: String?
        let name: String
        let arguments: String
    }

    let calls: [Call]
    let reasoning: [Data]

    func input(files: [ChatFileInput]) throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var outputs: [[String: Any]] = []
        for data in reasoning {
            if let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] { items.append(item) }
        }
        var receipts: [[String: String]] = []
        for call in calls {
            let result: [String: String]
            if call.name == ChatFilingTool.name,
               let suggestion = try? ChatFilingTool.suggestion(arguments: Data(call.arguments.utf8)),
               files.contains(where: { $0.file.id == suggestion.attachmentID && $0.file.savedMaterialID == nil && $0.destinations.contains(suggestion.classID) }) {
                result = ["status": "filing_suggestion_prepared", "attachment_id": suggestion.attachmentID.uuidString,
                          "class_id": suggestion.classID.uuidString, "title": suggestion.title]
            } else if let display = AgentDisplayTool(rawValue: call.name),
                      (try? display.render(arguments: Data(call.arguments.utf8))) != nil {
                result = ["status": "visual_prepared"]
            } else { result = ["status": "rejected"] }
            receipts.append(result)
            if let id = call.id {
                items.append(["type": "function_call", "call_id": id, "name": call.name, "arguments": call.arguments])
                outputs.append(["type": "function_call_output", "call_id": id,
                                "output": String(decoding: try JSONEncoder().encode(result), as: UTF8.self)])
            }
        }
        // In a stateless request, opaque reasoning or visual arguments can dwarf the filing receipt.
        // A standalone receipt also works with gateways that omit call IDs.
        let replayBytes = reasoning.reduce(0) { $0 + $1.count } + calls.reduce(0) { $0 + $1.arguments.utf8.count }
        if outputs.count != calls.count || replayBytes > 8_192 {
            let results = String(decoding: try JSONEncoder().encode(receipts), as: UTF8.self)
            return [["role": "developer", "content": "Local LCP tool results: " + results]]
        }
        return items + outputs
    }
}

extension AgentProviderGenerationResult {
    func appending(_ answer: AgentProviderGenerationResult) -> Self {
        func sum(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        let counts = TokenUsage(inputTokens: sum(usage?.inputTokens, answer.usage?.inputTokens),
                                outputTokens: sum(usage?.outputTokens, answer.usage?.outputTokens),
                                totalTokens: sum(usage?.totalTokens, answer.usage?.totalTokens))
        let prefix = text == ChatFilingTool.reply ? "" : text
        let combined = [prefix, answer.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Self(text: combined, requestID: answer.requestID ?? requestID,
                    usage: usage == nil && answer.usage == nil ? nil : counts, filingSuggestions: filingSuggestions)
    }
}

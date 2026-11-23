import CoreFoundation
import Foundation

/// The provider and the local MCP server advertise and execute the same display tools.
public enum AgentDisplayTool: String, CaseIterable, Sendable {
    case barChart = "render_bar_chart"
    case timeline = "render_timeline"

    public var guidance: String {
        switch self {
        case .barChart: return "Compare supplied, non-negative quantities in the same unit. Use only known values."
        case .timeline: return "Display an ordered study plan or sequence of milestones. Identify suggested steps and use only confirmed deadlines."
        }
    }

    private static let maxRows = 16
    private static let maxValue = 1_000_000_000_000.0

    public var inputSchema: [String: Any] {
        func string(_ length: Int) -> [String: Any] { ["type": "string", "minLength": 1, "maxLength": length] }
        var item: [String: Any] = ["label": string(120)]
        var fields: [String: Any] = ["title": string(160)]
        switch self {
        case .barChart:
            fields["unit"] = string(40)
            item["value"] = ["type": "number", "minimum": 0, "maximum": Self.maxValue]
        case .timeline:
            item["detail"] = string(400)
        }
        fields["items"] = ["type": "array", "minItems": 1, "maxItems": Self.maxRows, "items": [
            "type": "object", "properties": item, "required": item.keys.sorted(), "additionalProperties": false
        ]] as [String: Any]
        return ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]
    }

    public func render(arguments: Data) throws -> AgentVisual {
        guard arguments.count <= AgentVisual.byteLimit,
              let fields = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw AgentDisplayError.invalidArguments
        }
        return try render(fields)
    }

    fileprivate func render(_ fields: [String: Any]) throws -> AgentVisual {
        func label(_ raw: Any?, limit: Int) throws -> String {
            guard let text = raw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.unicodeScalars.count <= limit,
                  text.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil else {
                throw AgentDisplayError.invalidArguments
            }
            return text
        }
        let required = self == .barChart ? ["title", "unit", "items"] : ["title", "items"]
        guard Set(fields.keys) == Set(required), let rawItems = fields["items"] as? [[String: Any]],
              (1...Self.maxRows).contains(rawItems.count) else { throw AgentDisplayError.invalidArguments }
        let title = try label(fields["title"], limit: 160)
        let unit = self == .barChart ? try label(fields["unit"], limit: 40) : nil
        let items: [AgentVisual.Item] = try rawItems.map { row in
            let name = try label(row["label"], limit: 120)
            switch self {
            case .barChart:
                guard Set(row.keys) == ["label", "value"], let number = row["value"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), (0...Self.maxValue).contains(number.doubleValue) else {
                    throw AgentDisplayError.invalidArguments
                }
                return .init(label: name, value: number.doubleValue, detail: nil)
            case .timeline:
                guard Set(row.keys) == ["label", "detail"] else { throw AgentDisplayError.invalidArguments }
                return .init(label: name, value: nil, detail: try label(row["detail"], limit: 400))
            }
        }
        return AgentVisual(tool: self, title: title, unit: unit, items: items)
    }
}

public enum AgentDisplayError: LocalizedError {
    case invalidArguments
    public var errorDescription: String? { "The visual does not match its tool schema or exceeds its size limit." }
}

public struct AgentVisual: Equatable, Encodable, Sendable {
    public struct Item: Equatable, Encodable, Sendable {
        public let label: String
        public let value: Double?
        public let detail: String?
    }

    public static let fence = "lcp-visual"
    public static let byteLimit = 48 * 1024
    public let version = 1
    public let tool: AgentDisplayTool
    public let title: String
    public let unit: String?
    public let items: [Item]

    public func markdown() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.byteLimit else { throw AgentDisplayError.invalidArguments }
        return "```\(Self.fence)\n" + String(decoding: data, as: UTF8.self) + "\n```"
    }

    public static func decodeBlock(_ raw: String) throws -> Self {
        let data = Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard data.count <= byteLimit, var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object.removeValue(forKey: "version") as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let name = object.removeValue(forKey: "tool") as? String, let tool = AgentDisplayTool(rawValue: name) else {
            throw AgentDisplayError.invalidArguments
        }
        return try tool.render(object)
    }
}

extension AgentDisplayTool: Codable {}

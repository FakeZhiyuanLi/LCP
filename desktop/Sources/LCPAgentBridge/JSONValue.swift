import Foundation

/// JSON-RPC data. Source text is always data, never executable configuration.
enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode(Double.self) { self = .number(v) }
        else if let v = try? container.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v,
              v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }

    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}

struct BridgeFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String, maximum: Int = 4096) throws -> String {
        guard let value = self[key]?.string, !value.isEmpty, value.utf8.count <= maximum else {
            throw BridgeFailure("Invalid or missing \(key).")
        }
        return value
    }

    func requiredUUID(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try requiredString(key, maximum: 36)) else {
            throw BridgeFailure("Invalid \(key).")
        }
        return id
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let raw = self[key], raw != .null else { return nil }
        guard let text = raw.string, let id = UUID(uuidString: text) else {
            throw BridgeFailure("Invalid \(key).")
        }
        return id
    }

    func optionalInteger(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = self[key] else { return fallback }
        guard let n = raw.integer, range.contains(n) else { throw BridgeFailure("Invalid \(key).") }
        return n
    }
}

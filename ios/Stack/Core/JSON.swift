import Foundation

/// A dynamic JSON value. The Stack API returns loosely shaped documents (and prep sessions carry
/// fields this app does not own), so models read from `JSON` and unknown keys survive a round trip.
enum JSON: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSON {
        get { if case .object(let object) = self { return object[key] ?? .null }; return .null }
        set {
            var object: [String: JSON] = [:]
            if case .object(let existing) = self { object = existing }
            if newValue == .null { object.removeValue(forKey: key) } else { object[key] = newValue }
            self = .object(object)
        }
    }

    subscript(index: Int) -> JSON {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    var isNull: Bool { self == .null }
    var string: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return ""
        }
    }
    var double: Double {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value) ?? 0
        case .bool(let value): return value ? 1 : 0
        default: return 0
        }
    }
    var int: Int { Int(double) }
    var bool: Bool {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return value == "true"
        default: return false
        }
    }
    var array: [JSON] { if case .array(let items) = self { return items }; return [] }
    var object: [String: JSON] { if case .object(let items) = self { return items }; return [:] }
    var strings: [String] { array.map(\.string).filter { !$0.isEmpty } }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(nilLiteral: ()) { self = .null }
}

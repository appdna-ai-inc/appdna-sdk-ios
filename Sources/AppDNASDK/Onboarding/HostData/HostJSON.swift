import Foundation

/// The RAW step JSON, kept beside the typed model.
///
/// 🔴 NOT `AnyCodable`. `AnyCodable.encode` checks `as Bool` FIRST, and an `NSNumber` 0 or 1 passes
/// that cast — so a raw block round-tripped through it comes back with `"max": true` where the
/// author wrote `1`, and the typed decode of a `Double` slot then fails the whole step. This enum
/// keeps the four JSON scalar kinds apart (string, integer, fractional number, boolean), which is
/// what the cache round trip and the type-strict fixture comparison both depend on.
indirect enum HostJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([HostJSON])
    case object([String: HostJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool first is safe HERE (unlike AnyCodable's encode): JSONDecoder only decodes a Bool
        // from a JSON `true`/`false` literal, never from the number 1.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([HostJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: HostJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Foundation graph → HostJSON. Booleans are told apart from numbers by `CFBoolean` TYPE
    /// IDENTITY ("Stringification": an `NSNumber` 1 is the integer 1, never `true`).
    init(any: Any?) {
        guard let v = any else { self = .null; return }
        switch v {
        case is NSNull: self = .null
        case let h as HostJSON: self = h
        case let a as AnyCodable: self.init(any: a.value)
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                // A fractional-typed NSNumber holding an integral value is still a JSON number; keep
                // it a double so its kind survives, stringification renders both the same way.
                self = .double(d)
            } else {
                self = .int(n.int64Value)
            }
        case let a as [Any]: self = .array(a.map { HostJSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { HostJSON(any: $0) })
        default: self = .null
        }
    }

    /// HostJSON → the Foundation graph the rest of the SDK reads (`[String: Any]`, `[Any]`).
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return Int(truncatingIfNeeded: i)
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundation }
        case .object(let o): return o.mapValues { $0.foundation }
        }
    }

    var objectValue: [String: HostJSON]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [HostJSON]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    /// Encode to JSON data (for the typed decoders).
    func jsonData() throws -> Data { try JSONEncoder().encode(self) }
}

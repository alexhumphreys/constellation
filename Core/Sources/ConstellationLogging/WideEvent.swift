import Foundation

// A canonical wide event: one structured emission per logical unit of
// work, produced at completion (never on start) with every relevant
// field populated on a single line. Events from the same logical
// operation are tied together by `correlationId`.
//
// Convention: prefer wide events to inline log statements for business
// logic — every field that explains *what happened* lives on the same
// event, so log-aggregation queries don't need to join across lines.
// Inline log statements are reserved for failures of infrastructure that
// can't easily be encoded as a field (e.g. "failed to open SQLite file"
// before the store exists).
public struct WideEvent: Sendable, Hashable {
    public var op: String
    public var timestamp: Date
    public var correlationId: String?
    public var durationMs: Double?
    public var outcome: Outcome
    public var fields: [String: WideValue]

    public init(
        op: String,
        timestamp: Date = Date(),
        correlationId: String? = nil,
        outcome: Outcome = .ok,
        durationMs: Double? = nil,
        fields: [String: WideValue] = [:]
    ) {
        self.op = op
        self.timestamp = timestamp
        self.correlationId = correlationId
        self.outcome = outcome
        self.durationMs = durationMs
        self.fields = fields
    }

    public enum Outcome: String, Sendable, Hashable, Codable {
        case ok
        case error
        case skipped
        case conflict
    }

    public subscript(key: String) -> WideValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }
}

// Encodes to / decodes from plain JSON scalars (`"hi"`, `42`, `3.14`,
// `true`) rather than the default tagged enum form (`{"string":{"_0":...}}`).
// The journal CLI surfaces the wide-event `fieldsJson` directly to the
// user, so the on-disk shape is also the on-screen shape — needs to be
// readable. On decode the ordering matters: try bool before int, and int
// before double, so JSONDecoder doesn't widen `true` into `1` or `1`
// into `1.0`.
public enum WideValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int64.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "WideValue: expected string/int/double/bool scalar"
        )
    }
}

extension WideValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension WideValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension WideValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension WideValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public extension WideValue {
    var stringValue: String? {
        if case .string(let s) = self { s } else { nil }
    }
    var intValue: Int64? {
        if case .int(let i) = self { i } else { nil }
    }
    var doubleValue: Double? {
        if case .double(let d) = self { d } else { nil }
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { b } else { nil }
    }
}

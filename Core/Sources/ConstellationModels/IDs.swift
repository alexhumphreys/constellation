import Foundation

// Typed identifier wrappers — each entity gets its own type so the
// compiler catches mix-ups (passing a SkillID where an AreaID is wanted,
// etc.). All are String-backed for sync portability across SQLite/JSON
// and easy debugging from the CLI.

public protocol StringID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible where RawValue == String
{
    init(_ value: String)
}

public extension StringID {
    init(_ value: String) { self.init(rawValue: value)! }
    var description: String { rawValue }
}

public struct AreaID: StringID {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

public struct SkillID: StringID {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

public struct ChainID: StringID {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

public struct SessionID: StringID {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    public static func generate() -> SessionID {
        SessionID(UUID().uuidString.lowercased())
    }
}

public struct NoteID: StringID {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    public static func generate() -> NoteID {
        NoteID(UUID().uuidString.lowercased())
    }
}

public struct ClipID: StringID {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    public static func generate() -> ClipID {
        ClipID(UUID().uuidString.lowercased())
    }
}

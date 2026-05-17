import Foundation

// A practice log entry — "May 10: Clean 2x right, sloppy left". Append-only
// per skill, identified by UUID so two devices logging concurrently
// converge without conflict (the union of both logs is the merged state).
// `date` is the practice date (user-supplied), distinct from any system
// timestamp on the event — you can backfill a session you forgot to log.
public struct Session: Hashable, Sendable, Codable {
    public let id: SessionID
    public var skillId: SkillID
    public var date: Date
    public var text: String
    public var tombstonedAt: Date?

    public init(
        id: SessionID = .generate(),
        skillId: SkillID,
        date: Date = Date(),
        text: String,
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.skillId = skillId
        self.date = date
        self.text = text
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

import Foundation

// A freeform note attached to a skill — coach cues, mental notes, "scary
// on left side", reminders. Append-only with UUID identity for CRDT
// convergence, same pattern as Session. Notes don't have a separate
// `date` field because their meaning is timeless ("watch elbow on entry"
// applies the day you write it and a year later); only `addedAt` exists,
// for sort order and journal reconstruction.
public struct Note: Hashable, Sendable, Codable {
    public let id: NoteID
    public var skillId: SkillID
    public var text: String
    public var addedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: NoteID = .generate(),
        skillId: SkillID,
        text: String,
        addedAt: Date = Date(),
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.skillId = skillId
        self.text = text
        self.addedAt = addedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

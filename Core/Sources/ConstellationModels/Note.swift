import Foundation

// A freeform note attached to a skill — coach cues, mental notes, "scary
// on left side", reminders. UUID identity for CRDT convergence (same
// pattern as Session and Clip). `addedAt` stays frozen at creation so
// timelines remain stable when a note is edited later; `updatedAt` is
// the LWW merge clock that bumps on each edit so the latest text wins
// across replicas.
public struct Note: Hashable, Sendable, Codable {
    public let id: NoteID
    public var skillId: SkillID
    public var text: String
    public var addedAt: Date
    public var updatedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: NoteID = .generate(),
        skillId: SkillID,
        text: String,
        addedAt: Date = Date(),
        updatedAt: Date? = nil,
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.skillId = skillId
        self.text = text
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

import Foundation

// A saved resource attached to a skill: an Instagram reel, YouTube clip,
// blog post, or the user's own camera-roll video. `source` is a freeform
// human-readable provenance string ("IG · @silks_tutor", "YouTube · 6:42",
// "my video") because the design doesn't enforce a typed-source enum —
// the user can paste whatever fits. `url` is optional so notes-only clips
// (text-only references) are representable.
public struct Clip: Hashable, Sendable, Codable {
    public let id: ClipID
    public var skillId: SkillID
    public var source: String
    public var title: String
    public var url: URL?
    public var duration: String?
    public var note: String?
    public var addedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: ClipID = .generate(),
        skillId: SkillID,
        source: String,
        title: String,
        url: URL? = nil,
        duration: String? = nil,
        note: String? = nil,
        addedAt: Date = Date(),
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.skillId = skillId
        self.source = source
        self.title = title
        self.url = url
        self.duration = duration
        self.note = note
        self.addedAt = addedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

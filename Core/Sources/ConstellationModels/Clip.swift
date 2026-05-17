import Foundation

// A saved resource attached to a skill: an Instagram reel, YouTube clip,
// blog post, or the user's own camera-roll video. `platform` is a coarse
// provenance bucket ("Instagram", "YouTube", "TikTok", "Note", or a host
// like "medium.com" for unrecognized URLs) — iOS auto-derives it from the
// URL host on save; the CLI takes it explicitly. `handle` is an optional
// @-style creator label ("@silks_tutor") the user attaches by hand —
// can't be inferred from IG reel URLs without fetching the page. `url`
// is optional so notes-only clips are representable.
public struct Clip: Hashable, Sendable, Codable {
    public let id: ClipID
    public var skillId: SkillID
    public var platform: String
    public var handle: String?
    public var title: String
    public var url: URL?
    public var duration: String?
    public var note: String?
    public var addedAt: Date
    // `updatedAt` is the merge clock for LWW on the mutable body
    // (platform / handle / title / url / duration / note). `addedAt`
    // stays frozen at creation so timelines remain stable when a clip
    // is edited later. New clips default to `addedAt` so the two
    // initial values agree and the first save doesn't look "edited".
    public var updatedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: ClipID = .generate(),
        skillId: SkillID,
        platform: String,
        handle: String? = nil,
        title: String,
        url: URL? = nil,
        duration: String? = nil,
        note: String? = nil,
        addedAt: Date = Date(),
        updatedAt: Date? = nil,
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.skillId = skillId
        self.platform = platform
        self.handle = handle
        self.title = title
        self.url = url
        self.duration = duration
        self.note = note
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

import Foundation

// A photo or video captured by the user on this device (PhotoKit picker
// or in-app capture). Distinct from `Clip` because Clip references
// remote, platform-hosted media (IG reel URL, YouTube link) whose bytes
// Constellation never owns — Attachment owns the bytes and the storage,
// sync, and GC mechanics that come with that.
//
// `contentHash` is sha256-hex of the file bytes. It doubles as the file
// locator on disk (`Documents/assets/<contentHash>.<ext>`) and as the
// sync-dedupe key — two attachments referencing the same hash share one
// file, and the MC blob-reconciliation phase asks peers for hashes it
// doesn't have rather than per-attachment ids.
//
// Most fields are immutable after capture (you can't retroactively
// change the byte size of a photo you took). Only `caption` mutates,
// which is why this entity uses LWW-with-tombstones — same hybrid as
// Clip — rather than strict append-only.
public struct Attachment: Hashable, Sendable, Codable {
    public let id: AttachmentID
    public var skillId: SkillID
    public var contentHash: String
    public var mediaType: MediaType
    public var mimeType: String
    public var byteSize: Int64
    public var width: Int
    public var height: Int
    public var durationMs: Int?
    public var capturedAt: Date?
    public var caption: String?
    public var addedAt: Date
    // LWW clock — bumps when `caption` changes. The rest of the body is
    // immutable in practice but the clock still serves to settle ties if
    // a future version ever needs to edit anything else.
    public var updatedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: AttachmentID = .generate(),
        skillId: SkillID,
        contentHash: String,
        mediaType: MediaType,
        mimeType: String,
        byteSize: Int64,
        width: Int,
        height: Int,
        durationMs: Int? = nil,
        capturedAt: Date? = nil,
        caption: String? = nil,
        addedAt: Date = Date(),
        updatedAt: Date? = nil,
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.skillId = skillId
        self.contentHash = contentHash
        self.mediaType = mediaType
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.capturedAt = capturedAt
        self.caption = caption
        self.addedAt = addedAt
        self.updatedAt = updatedAt ?? addedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

public enum MediaType: String, Hashable, Sendable, Codable {
    case photo
    case video
}

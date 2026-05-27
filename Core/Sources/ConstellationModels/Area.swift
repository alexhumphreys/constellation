import Foundation

// A constellation — one named domain ("Aerial Silks", "Springboard Diving").
// Holds a tint color and a cluster center in the shared virtual sky so the
// canvas can lay multiple areas out side-by-side without overlap. All
// scalar fields are last-write-wins on `updatedAt`; soft deletion via
// `tombstonedAt` so a deletion on one device propagates without erasing
// changes another device made after the delete.
public struct Area: Hashable, Sendable, Codable {
    public let id: AreaID
    public var name: String
    // 6-digit hex, no alpha, e.g. "#e88a7a". Validated at construction
    // time so storage never holds garbage that would break the canvas.
    public var tint: String
    // Center of this area's cluster in the shared 2400x1600 virtual sky.
    public var centerX: Double
    public var centerY: Double
    public var radius: Double
    // How fresh skills are placed inside this cluster. `.manual` (the
    // historical behavior) drops them at the area's live centroid and
    // spirals out for clearance. Algorithms like `.concentric` compute
    // a position from the skill's relationship to the rest of the
    // graph — depth from foundation = ring number, etc. — so a hobby
    // can opt in to auto-layout without affecting the others. Pinned
    // skills (anything the user has dragged) stay put either way; the
    // strategy only runs at the new-skill drop call site.
    public var layoutKind: LayoutKind
    public var updatedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: AreaID,
        name: String,
        tint: String = "#888888",
        centerX: Double = 1200,
        centerY: Double = 800,
        radius: Double = 400,
        layoutKind: LayoutKind = .manual,
        updatedAt: Date = Date(),
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.tint = Self.normalizeTint(tint)
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.layoutKind = layoutKind
        self.updatedAt = updatedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }

    // Where this hobby currently "lives" in the sky — the centroid of
    // its live (non-tombstoned) skills, falling back to the stored
    // centerX/centerY when the area has no skills yet. Callers that
    // want a stable anchor (new-skill drop spot, focus pan target) use
    // this instead of the raw stored fields so the anchor follows the
    // cluster as the user drags skills around. Pass the full skill
    // list; filtering by areaId happens here.
    public func liveCenter(in skills: [Skill]) -> (x: Double, y: Double) {
        let live = skills.filter { $0.areaId == id && !$0.isDeleted }
        guard !live.isEmpty else { return (centerX, centerY) }
        let n = Double(live.count)
        let cx = live.reduce(0.0) { $0 + $1.x } / n
        let cy = live.reduce(0.0) { $0 + $1.y } / n
        return (cx, cy)
    }

    // Lowercase the hex and prepend "#" if the caller passed it bare.
    // Returns the input unchanged if it doesn't look like hex — the model
    // doesn't reject bad colors, it just normalizes the shape it understands.
    public static func normalizeTint(_ tint: String) -> String {
        let trimmed = tint.trimmingCharacters(in: .whitespacesAndNewlines)
        let withHash = trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
        return withHash.lowercased()
    }
}

// How fresh-skill drop coords are picked for an area. Unknown raw values
// decode as `.manual` so a future algorithm coming over MC sync from a
// newer build degrades gracefully on an older one (the only cost: new
// skills drop manually until the older device is updated).
public enum LayoutKind: String, Hashable, Sendable, Codable, CaseIterable {
    case manual
    case concentric

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LayoutKind(rawValue: raw) ?? .manual
    }

    public var displayLabel: String {
        switch self {
        case .manual: "Manual"
        case .concentric: "Concentric"
        }
    }
}

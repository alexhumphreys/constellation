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
    public var updatedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: AreaID,
        name: String,
        tint: String = "#888888",
        centerX: Double = 1200,
        centerY: Double = 800,
        radius: Double = 400,
        updatedAt: Date = Date(),
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.tint = Self.normalizeTint(tint)
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.updatedAt = updatedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }

    // Lowercase the hex and prepend "#" if the caller passed it bare.
    // Returns the input unchanged if it doesn't look like hex — the model
    // doesn't reject bad colors, it just normalizes the shape it understands.
    public static func normalizeTint(_ tint: String) -> String {
        let trimmed = tint.trimmingCharacters(in: .whitespacesAndNewlines)
        let withHash = trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
        return withHash.lowercased()
    }
}

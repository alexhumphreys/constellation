import Foundation

// A single skill — a star in the constellation. The position (x, y) sits
// in the shared 2400x1600 virtual sky; by convention the angular axis
// around the area center encodes "ordering / progression family" and the
// radial distance encodes difficulty (further from center = harder).
// Prerequisites are split into hard (`prereqIds`) and soft (`softPrereqIds`,
// rendered with a dashed edge — "recommended but not required").
public struct Skill: Hashable, Sendable, Codable {
    public let id: SkillID
    public var areaId: AreaID
    public var name: String
    public var status: SkillStatus
    public var x: Double
    public var y: Double
    public var prereqIds: [SkillID]
    public var softPrereqIds: [SkillID]
    public var isFoundation: Bool
    // Cross-area "also helps" tags (e.g. core conditioning → diving entries).
    // Kept as freeform area IDs so the constellation can show provenance
    // labels without modelling explicit cross-graph edges.
    public var helpsAreas: [AreaID]
    public var updatedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: SkillID,
        areaId: AreaID,
        name: String,
        status: SkillStatus = .locked,
        x: Double = 0,
        y: Double = 0,
        prereqIds: [SkillID] = [],
        softPrereqIds: [SkillID] = [],
        isFoundation: Bool = false,
        helpsAreas: [AreaID] = [],
        updatedAt: Date = Date(),
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.areaId = areaId
        self.name = name
        self.status = status
        self.x = x
        self.y = y
        self.prereqIds = prereqIds
        self.softPrereqIds = softPrereqIds
        self.isFoundation = isFoundation
        self.helpsAreas = helpsAreas
        self.updatedAt = updatedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

// Status drives both the visual treatment in the constellation canvas
// (brightness, glow, ring style) and the "what should I work on?" filters
// in the CLI/iPad UI. Order is intentional — it matches the design's
// status progression and is used for filtering ranges.
public enum SkillStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case master   // fully solid, big diffraction-spike star
    case got      // got it, mid star
    case drill    // actively drilling, pulsing ring
    case next     // next up, dashed ring
    case wish     // wishlist, dim star
    case locked   // prereqs not met, outlined dashed circle

    public var displayLabel: String {
        switch self {
        case .master: "solid"
        case .got: "got it"
        case .drill: "drilling"
        case .next: "next up"
        case .wish: "wishlist"
        case .locked: "locked"
        }
    }
}

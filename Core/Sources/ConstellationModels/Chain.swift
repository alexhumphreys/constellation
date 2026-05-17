import Foundation

// A named sequence of skills you can flow through — silks transitions
// ("hip key → thigh hitch → cross-back straddle → bird's nest → aerial chair"),
// a calisthenics progression ladder, a dive line. The constellation canvas
// renders these as glowing arcs when "trace chain" is toggled on.
//
// The order in `skillIds` is meaningful — it's the rendered stroke order.
// A skill can appear in multiple chains (e.g. "hip key" is on several silks
// transition lines), so this is a join, not an owning relationship.
public struct Chain: Hashable, Sendable, Codable {
    public let id: ChainID
    public var areaId: AreaID
    public var name: String
    public var skillIds: [SkillID]
    public var updatedAt: Date
    public var tombstonedAt: Date?

    public init(
        id: ChainID,
        areaId: AreaID,
        name: String,
        skillIds: [SkillID] = [],
        updatedAt: Date = Date(),
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.areaId = areaId
        self.name = name
        self.skillIds = skillIds
        self.updatedAt = updatedAt
        self.tombstonedAt = tombstonedAt
    }

    public var isDeleted: Bool { tombstonedAt != nil }
}

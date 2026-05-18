import ConstellationModels
import Foundation
import Testing

@Suite("Model basics")
struct ModelTests {

    @Test("Area normalizes tint to lowercase with leading #")
    func areaTintNormalization() {
        let bareUpper = Area(id: AreaID("silks"), name: "Silks", tint: "E88A7A")
        #expect(bareUpper.tint == "#e88a7a")
        let mixed = Area(id: AreaID("d"), name: "Diving", tint: "#7FB3FF")
        #expect(mixed.tint == "#7fb3ff")
    }

    @Test("Status enumerates the design's six tiers")
    func statusCases() {
        let cases = SkillStatus.allCases.map(\.rawValue)
        #expect(cases.contains("master"))
        #expect(cases.contains("got"))
        #expect(cases.contains("drill"))
        #expect(cases.contains("next"))
        #expect(cases.contains("wish"))
        #expect(cases.contains("locked"))
        #expect(SkillStatus.drill.displayLabel == "drilling")
    }

    @Test("Tombstoning sets isDeleted")
    func tombstoning() {
        var skill = Skill(id: SkillID("hip-key"), areaId: AreaID("silks"),
                          name: "Hip Key")
        #expect(!skill.isDeleted)
        skill.tombstonedAt = Date()
        #expect(skill.isDeleted)
    }

    @Test("Session and Note generate distinct UUIDs")
    func uuidIdsAreUnique() {
        let a = Session(skillId: SkillID("hip-key"), text: "x")
        let b = Session(skillId: SkillID("hip-key"), text: "x")
        #expect(a.id != b.id)
        let na = Note(skillId: SkillID("hip-key"), text: "x")
        let nb = Note(skillId: SkillID("hip-key"), text: "x")
        #expect(na.id != nb.id)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundtrip() throws {
        let skill = Skill(
            id: SkillID("crochet"), areaId: AreaID("silks"),
            name: "Crochet", status: .drill,
            x: 840, y: 500,
            prereqIds: [SkillID("hip-key"), SkillID("gazelle")],
            softPrereqIds: [SkillID("invert")],
            isFoundation: false,
            helpsAreas: [AreaID("cali")],
            aliases: ["Hook", "Croché"]
        )
        let data = try JSONEncoder().encode(skill)
        let decoded = try JSONDecoder().decode(Skill.self, from: data)
        #expect(decoded == skill)
    }
}

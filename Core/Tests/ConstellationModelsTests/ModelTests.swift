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

    @Test("Area.liveCenter centroids live skills, falls back to stored center when empty")
    func areaLiveCenter() {
        let area = Area(id: AreaID("silks"), name: "Silks",
                        centerX: 100, centerY: 200)
        // No skills → fallback to stored center.
        #expect(area.liveCenter(in: []) == (100, 200))
        let s1 = Skill(id: SkillID("a"), areaId: AreaID("silks"),
                       name: "A", x: 300, y: 400)
        let s2 = Skill(id: SkillID("b"), areaId: AreaID("silks"),
                       name: "B", x: 500, y: 600)
        // Two live skills → centroid.
        let c = area.liveCenter(in: [s1, s2])
        #expect(c.x == 400 && c.y == 500)
        // Tombstoned skills are excluded.
        var s3 = Skill(id: SkillID("c"), areaId: AreaID("silks"),
                       name: "C", x: 9999, y: 9999)
        s3.tombstonedAt = Date()
        let c2 = area.liveCenter(in: [s1, s2, s3])
        #expect(c2.x == 400 && c2.y == 500)
        // Skills from other areas don't count.
        let s4 = Skill(id: SkillID("d"), areaId: AreaID("other"),
                       name: "D", x: 9999, y: 9999)
        let c3 = area.liveCenter(in: [s1, s2, s4])
        #expect(c3.x == 400 && c3.y == 500)
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

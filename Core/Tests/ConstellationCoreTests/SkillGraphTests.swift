import ConstellationCore
import Foundation
import Testing

@Suite("SkillGraph traversals")
struct SkillGraphTests {

    @Test("Neighbours returns prereqs, soft prereqs, and unlocks")
    func neighbours() {
        let skills = [
            Skill(id: SkillID("climb"), areaId: AreaID("silks"), name: "Climb"),
            Skill(id: SkillID("invert"), areaId: AreaID("silks"),
                  name: "Invert", prereqIds: [SkillID("climb")]),
            Skill(id: SkillID("hip-key"), areaId: AreaID("silks"),
                  name: "Hip Key", prereqIds: [SkillID("invert")],
                  softPrereqIds: [SkillID("climb")]),
            Skill(id: SkillID("thigh-hitch"), areaId: AreaID("silks"),
                  name: "Thigh Hitch", prereqIds: [SkillID("hip-key")]),
        ]
        let graph = SkillGraph(skills)
        let n = graph.neighbours(of: SkillID("hip-key"))!
        #expect(n.prereqs.map(\.id) == [SkillID("invert")])
        #expect(n.softPrereqs.map(\.id) == [SkillID("climb")])
        #expect(n.unlocks.map(\.id) == [SkillID("thigh-hitch")])
    }

    @Test("forwardChain walks descendants bounded by depth")
    func forwardChainBounded() {
        let skills = (0..<6).map { i in
            Skill(
                id: SkillID("s\(i)"), areaId: AreaID("a"), name: "s\(i)",
                prereqIds: i == 0 ? [] : [SkillID("s\(i-1)")]
            )
        }
        let graph = SkillGraph(skills)
        let depth3 = graph.forwardChain(from: SkillID("s0"), depth: 3)
        #expect(depth3 == [SkillID("s0"), SkillID("s1"),
                           SkillID("s2"), SkillID("s3")])
    }

    @Test("ready: only skills with all prereqs ≥ got")
    func readyFilter() {
        let skills = [
            Skill(id: SkillID("a"), areaId: AreaID("x"), name: "A", status: .got),
            Skill(id: SkillID("b"), areaId: AreaID("x"), name: "B", status: .next),
            Skill(id: SkillID("c"), areaId: AreaID("x"), name: "C", status: .next,
                  prereqIds: [SkillID("a")]),
            Skill(id: SkillID("d"), areaId: AreaID("x"), name: "D", status: .next,
                  prereqIds: [SkillID("b")]),
        ]
        let graph = SkillGraph(skills)
        let ready = graph.ready().map(\.id).sorted { $0.rawValue < $1.rawValue }
        // B is .next (not ≥ got), so D is gated by B and excluded.
        // C's prereq A is .got, so C is ready. B itself is .next with no
        // prereqs so it's also ready.
        #expect(ready == [SkillID("b"), SkillID("c")])
    }

    @Test("Seed data loads with no duplicate ids")
    func seedDataIntegrity() {
        let snapshot = SeedData.snapshot()
        let skillIds = snapshot.skills.map(\.id)
        #expect(Set(skillIds).count == skillIds.count)
        let areaIds = Set(snapshot.areas.map(\.id))
        for skill in snapshot.skills {
            #expect(areaIds.contains(skill.areaId),
                    "skill \(skill.id) references unknown area \(skill.areaId)")
        }
    }
}

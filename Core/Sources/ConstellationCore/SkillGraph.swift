import ConstellationModels
import Foundation

// Pure-functional helpers over a snapshot of skills. The constellation
// canvas calls these to compute prereq chains, neighbour sets, and
// "what's unlocked now?" filters. Kept here (rather than on Skill
// itself) because they need a graph context — a single skill doesn't
// know its own successors.
public struct SkillGraph: Sendable {
    public let skills: [Skill]
    private let byId: [SkillID: Skill]
    private let successorsByPredecessor: [SkillID: [SkillID]]
    private let softSuccessorsByPredecessor: [SkillID: [SkillID]]

    public init(_ skills: [Skill]) {
        let live = skills.filter { !$0.isDeleted }
        self.skills = live
        var byId: [SkillID: Skill] = [:]
        var successors: [SkillID: [SkillID]] = [:]
        var softSuccessors: [SkillID: [SkillID]] = [:]
        for skill in live {
            byId[skill.id] = skill
            for prereq in skill.prereqIds {
                successors[prereq, default: []].append(skill.id)
            }
            for prereq in skill.softPrereqIds {
                softSuccessors[prereq, default: []].append(skill.id)
            }
        }
        self.byId = byId
        self.successorsByPredecessor = successors
        self.softSuccessorsByPredecessor = softSuccessors
    }

    public func skill(_ id: SkillID) -> Skill? { byId[id] }

    public struct Neighbours: Sendable, Hashable {
        public let me: Skill
        public let prereqs: [Skill]
        public let softPrereqs: [Skill]
        public let unlocks: [Skill]
    }

    public func neighbours(of id: SkillID) -> Neighbours? {
        guard let me = byId[id] else { return nil }
        let prereqs = me.prereqIds.compactMap { byId[$0] }
        let softPrereqs = me.softPrereqIds.compactMap { byId[$0] }
        let unlocks = (successorsByPredecessor[id] ?? [])
            .compactMap { byId[$0] }
        return Neighbours(
            me: me, prereqs: prereqs, softPrereqs: softPrereqs,
            unlocks: unlocks
        )
    }

    // Breadth-first descendant traversal — "everything this skill
    // unlocks, transitively". Bounded by `depth` so the constellation
    // canvas doesn't trace an entire connected component just because
    // someone tapped a foundation star. Walks both hard and soft
    // prereq edges so a chain doesn't dead-end at a soft link.
    public func forwardChain(from id: SkillID, depth: Int = 4) -> [SkillID] {
        var seen: Set<SkillID> = [id]
        var ordered: [SkillID] = [id]
        var frontier: [(SkillID, Int)] = [(id, 0)]
        while let (current, d) = frontier.first {
            frontier.removeFirst()
            if d >= depth { continue }
            let hard = successorsByPredecessor[current] ?? []
            let soft = softSuccessorsByPredecessor[current] ?? []
            for next in hard + soft {
                if seen.insert(next).inserted {
                    ordered.append(next)
                    frontier.append((next, d + 1))
                }
            }
        }
        return ordered
    }

    public func backwardChain(from id: SkillID, depth: Int = 4) -> [SkillID] {
        var seen: Set<SkillID> = [id]
        var ordered: [SkillID] = [id]
        var frontier: [(SkillID, Int)] = [(id, 0)]
        while let (current, d) = frontier.first {
            frontier.removeFirst()
            if d >= depth { continue }
            guard let skill = byId[current] else { continue }
            for prereq in skill.prereqIds + skill.softPrereqIds {
                if seen.insert(prereq).inserted {
                    ordered.append(prereq)
                    frontier.append((prereq, d + 1))
                }
            }
        }
        return ordered
    }

    // A skill is "ready to drill" when every hard prereq is at least
    // `got` (you've done it, even if not solid yet) and the skill
    // itself is currently `next` or `wish`. Drives the iPad "what
    // should I work on?" suggestion ribbon.
    public func ready(in areaId: AreaID? = nil) -> [Skill] {
        skills
            .filter { areaId == nil || $0.areaId == areaId }
            .filter { $0.status == .next || $0.status == .wish }
            .filter { skill in
                skill.prereqIds.allSatisfy { prereqId in
                    guard let prereq = byId[prereqId] else { return true }
                    switch prereq.status {
                    case .master, .got, .drill: return true
                    case .next, .wish, .locked: return false
                    }
                }
            }
    }
}

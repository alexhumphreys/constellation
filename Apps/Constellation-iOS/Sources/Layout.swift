import ConstellationCore
import Foundation

// Where to drop a fresh skill on the canvas. The strategy is per-area
// (Area.layoutKind, default `.manual`) so a hobby can opt in to an
// auto-placement algorithm without affecting the others. Pinned skills
// — anything the user has dragged — never move; the strategy only runs
// at the new-skill drop call site.
//
// `seedNear` is a picker-context hint ("the user was just editing this
// skill, drop the new one nearby"). Manual placement honors it; concentric
// ignores it because the ring is determined by graph topology.
func dropSpot(
    for newSkill: Skill,
    in area: Area,
    among skills: [Skill],
    seedNear: Skill? = nil
) -> (Double, Double) {
    let inArea = skills.filter { $0.areaId == area.id && !$0.isDeleted }
    switch area.layoutKind {
    case .manual:
        let center = area.liveCenter(in: skills)
        let seedX = seedNear?.x ?? center.x
        let seedY = seedNear?.y ?? center.y
        return openSpot(near: seedX, near: seedY, avoiding: inArea)
    case .concentric:
        return concentricSpot(for: newSkill, in: area, among: skills)
    }
}

// Concentric: foundations on the innermost ring at the area's live
// centroid, each in-area hard-prereq hop pushes the new star out one
// ring. Stable under graph edits because we recompute depth each time,
// never persist a derived ring index. Cycles in the prereq graph are
// safe — we break them by seeding the depth cache with 0 before
// recursing, so the worst case is "saw this skill mid-recursion, treat
// it as a foundation."
//
// Why not snap-by-seed-point: that would let the user manually drag a
// foundation to the cluster's edge and then have its children snap to
// rings further out. Topology-driven keeps the layout legible across
// devices ("this looks like a constellation, not a scatter plot").
func concentricSpot(
    for newSkill: Skill,
    in area: Area,
    among skills: [Skill]
) -> (Double, Double) {
    let inArea = skills.filter { $0.areaId == area.id && !$0.isDeleted }
    let byId = Dictionary(uniqueKeysWithValues: inArea.map { ($0.id, $0) })
    let center = area.liveCenter(in: skills)
    let ringStep: Double = 110

    // Depth from foundation = 1 + max(in-area hard prereq depths). A
    // skill with no in-area hard prereqs is depth 0 (a foundation).
    // Memoized + cycle-safe (seed each entry with 0 before recursing
    // so a back-edge collapses rather than blowing the stack).
    var depthCache: [SkillID: Int] = [:]
    func depth(of s: Skill) -> Int {
        if let d = depthCache[s.id] { return d }
        depthCache[s.id] = 0
        let parents = s.prereqIds.compactMap { byId[$0] }
        let d = parents.isEmpty ? 0 : 1 + parents.map(depth(of:)).max()!
        depthCache[s.id] = d
        return d
    }

    let myDepth: Int
    let parents = newSkill.prereqIds.compactMap { byId[$0] }
    if parents.isEmpty {
        myDepth = 0
    } else {
        myDepth = 1 + parents.map(depth(of:)).max()!
    }

    if myDepth == 0 {
        // Foundation — sit at the cluster center, spiral out for
        // clearance via the same helper manual placement uses.
        return openSpot(near: center.x, near: center.y, avoiding: inArea)
    }

    // Pick the first clear angle around the ring. Slots scale with
    // ring radius so outer rings get more breathing room. Rotated
    // half-a-slot from the previous ring (matches openSpot's spiral)
    // so radially-adjacent stars don't line up into spokes.
    let radius = Double(myDepth) * ringStep
    let slotsPerRing = max(8, 4 * myDepth)
    let rotation = Double(myDepth) * (.pi / Double(slotsPerRing))
    let minSeparation: Double = 55
    for slot in 0..<slotsPerRing {
        let angle = rotation + 2 * .pi * Double(slot) / Double(slotsPerRing)
        let x = center.x + radius * cos(angle)
        let y = center.y + radius * sin(angle)
        let clear = inArea.allSatisfy { s in
            let dx = s.x - x
            let dy = s.y - y
            return (dx * dx + dy * dy).squareRoot() >= minSeparation
        }
        if clear { return (x, y) }
    }
    // Ring fully packed — fall back to the canonical 0° point. Better
    // than infinite spiraling; the user can drag-to-move from there.
    return (center.x + radius, center.y)
}

import ConstellationModels
import Foundation

// Ported from the design's `data.js` — same 4 hobbies, ~45 stars, same
// positions in the 2400x1600 virtual sky, so the CLI and the iPad app
// can demo against the exact constellation the design renders. Used by
// `constellation seed` and by integration tests that need a populated
// store.
public enum SeedData {
    public static func snapshot(now: Date = Date()) -> ConstellationSnapshot {
        ConstellationSnapshot(
            generatedAt: now,
            areas: areas(now: now),
            skills: skills(now: now),
            chains: chains(now: now)
        )
    }

    public static func areas(now: Date = Date()) -> [Area] {
        [
            Area(id: AreaID("silks"), name: "Aerial Silks",
                 tint: "#e88a7a", centerX: 580, centerY: 580, radius: 480,
                 updatedAt: now),
            Area(id: AreaID("diving"), name: "Springboard Diving",
                 tint: "#7fb3ff", centerX: 1950, centerY: 460, radius: 420,
                 updatedAt: now),
            Area(id: AreaID("cali"), name: "Calisthenics",
                 tint: "#8bd6a4", centerX: 1840, centerY: 1180, radius: 480,
                 updatedAt: now),
            Area(id: AreaID("dance"), name: "Dancing",
                 tint: "#d29ce8", centerX: 580, centerY: 1140, radius: 320,
                 updatedAt: now),
        ]
    }

    public static func skills(now: Date = Date()) -> [Skill] {
        let s = SeedBuilder(now: now)
        return [
            // ── SILKS ─────────────────────────────────────
            s.skill("climb", "Climb", area: "silks", status: .master,
                    x: 540, y: 900, foundation: true),
            s.skill("invert", "Invert", area: "silks", status: .master,
                    x: 700, y: 820, prereqs: ["climb"]),
            s.skill("straddle-up", "Straddle-up", area: "silks", status: .master,
                    x: 460, y: 720, prereqs: ["climb", "invert"]),
            s.skill("hip-key", "Hip Key", area: "silks", status: .master,
                    x: 740, y: 680, prereqs: ["invert"]),
            s.skill("thigh-hitch", "Thigh Hitch", area: "silks", status: .master,
                    x: 900, y: 640, prereqs: ["hip-key"]),
            s.skill("gazelle", "Gazelle", area: "silks", status: .got,
                    x: 640, y: 560, prereqs: ["invert", "hip-key"]),
            s.skill("crochet", "Crochet", area: "silks", status: .drill,
                    x: 840, y: 500, prereqs: ["hip-key", "thigh-hitch", "gazelle"]),
            s.skill("cross-back", "Cross-back Straddle", area: "silks", status: .next,
                    x: 1020, y: 540, prereqs: ["thigh-hitch"]),
            s.skill("foot-lock-s", "Foot Lock (single)", area: "silks", status: .got,
                    x: 420, y: 600, prereqs: ["climb"]),
            s.skill("foot-lock-d", "Foot Lock (double)", area: "silks", status: .got,
                    x: 320, y: 500, prereqs: ["foot-lock-s"]),
            s.skill("star-wrap", "Star Wrap", area: "silks", status: .drill,
                    x: 240, y: 640, prereqs: ["foot-lock-d"], soft: ["hip-key"]),
            s.skill("meathook", "Meathook", area: "silks", status: .locked,
                    x: 1000, y: 400, prereqs: ["crochet", "cross-back"]),
            s.skill("crochet-drop", "Crochet Drop", area: "silks", status: .next,
                    x: 860, y: 380, prereqs: ["crochet"]),
            s.skill("gazelle-drop", "Gazelle Drop", area: "silks", status: .wish,
                    x: 600, y: 420, prereqs: ["gazelle", "thigh-hitch"]),
            s.skill("star-drop", "Star Drop", area: "silks", status: .wish,
                    x: 780, y: 280, prereqs: ["cross-back", "crochet"]),
            s.skill("wheel-down", "Wheel Down", area: "silks", status: .locked,
                    x: 140, y: 500, prereqs: ["star-wrap", "foot-lock-d"]),
            s.skill("angel-drop", "Angel Drop", area: "silks", status: .locked,
                    x: 200, y: 340, prereqs: ["star-wrap"]),
            s.skill("corkscrew", "Corkscrew", area: "silks", status: .locked,
                    x: 940, y: 180, prereqs: ["star-drop"]),

            // ── DIVING ────────────────────────────────────
            s.skill("front-1m", "Front Dive 1m", area: "diving", status: .master,
                    x: 1700, y: 640, foundation: true),
            s.skill("back-dive", "Back Dive", area: "diving", status: .master,
                    x: 1880, y: 680),
            s.skill("inward-dive", "Inward Dive", area: "diving", status: .got,
                    x: 2060, y: 640),
            s.skill("reverse-dive", "Reverse Dive", area: "diving", status: .got,
                    x: 2200, y: 680),
            s.skill("front-15", "Front 1½", area: "diving", status: .drill,
                    x: 1700, y: 500, prereqs: ["front-1m"]),
            s.skill("back-15", "Back 1½", area: "diving", status: .next,
                    x: 1880, y: 540, prereqs: ["back-dive"]),
            s.skill("reverse-15", "Reverse 1½", area: "diving", status: .drill,
                    x: 2200, y: 540, prereqs: ["reverse-dive"]),
            s.skill("inward-15", "Inward 1½", area: "diving", status: .next,
                    x: 2060, y: 500, prereqs: ["inward-dive"]),
            s.skill("front-25", "Front 2½", area: "diving", status: .locked,
                    x: 1700, y: 360, prereqs: ["front-15"]),
            s.skill("twist-combo", "Front w/ Twist", area: "diving", status: .wish,
                    x: 1820, y: 320, prereqs: ["front-15"]),
            s.skill("back-twist", "Back w/ Twist", area: "diving", status: .locked,
                    x: 1960, y: 360, prereqs: ["back-15"]),
            s.skill("reverse-25", "Reverse 2½", area: "diving", status: .locked,
                    x: 2200, y: 360, prereqs: ["reverse-15"]),

            // ── CALISTHENICS ──────────────────────────────
            s.skill("knee-pu", "Knee Push-up", area: "cali", status: .master,
                    x: 1480, y: 1280, foundation: true),
            s.skill("pushup", "Push-up", area: "cali", status: .master,
                    x: 1640, y: 1240, prereqs: ["knee-pu"]),
            s.skill("feet-elev", "Feet-elevated PU", area: "cali", status: .got,
                    x: 1800, y: 1280, prereqs: ["pushup"]),
            s.skill("diamond", "Diamond PU", area: "cali", status: .drill,
                    x: 1700, y: 1140, prereqs: ["pushup"]),
            s.skill("archer", "Archer PU", area: "cali", status: .next,
                    x: 1900, y: 1140, prereqs: ["feet-elev", "diamond"]),
            s.skill("one-arm", "One-arm PU", area: "cali", status: .wish,
                    x: 2080, y: 1080, prereqs: ["archer"]),
            s.skill("plank", "Plank", area: "cali", status: .master,
                    x: 2240, y: 1280, foundation: true),
            s.skill("hollow-body", "Hollow Body", area: "cali", status: .drill,
                    x: 2380, y: 1180, prereqs: ["plank"],
                    helpsAreas: ["diving"]),
            s.skill("pull-up", "Pull-up", area: "cali", status: .got,
                    x: 1480, y: 1080),
            s.skill("pistol-squat", "Pistol Squat", area: "cali", status: .drill,
                    x: 1380, y: 1180),
            s.skill("handstand", "Handstand", area: "cali", status: .next,
                    x: 2240, y: 1080, prereqs: ["plank", "pull-up"]),

            // ── DANCE ─────────────────────────────────────
            s.skill("box-step", "Box Step", area: "dance", status: .master,
                    x: 480, y: 1280, foundation: true),
            s.skill("cha-basic", "Cha-cha basic", area: "dance", status: .got,
                    x: 640, y: 1240, prereqs: ["box-step"]),
            s.skill("new-yorker", "New Yorker", area: "dance", status: .drill,
                    x: 760, y: 1140, prereqs: ["cha-basic"]),
            s.skill("swivels", "Cuban Swivels", area: "dance", status: .next,
                    x: 600, y: 1080, prereqs: ["cha-basic"]),
            s.skill("spot-turn", "Spot Turn", area: "dance", status: .got,
                    x: 420, y: 1140),
            s.skill("cross-body", "Cross-body Lead", area: "dance", status: .wish,
                    x: 780, y: 1020, prereqs: ["new-yorker", "spot-turn"]),
        ]
    }

    public static func chains(now: Date = Date()) -> [Chain] {
        [
            Chain(id: ChainID("silks-drop-line"), areaId: AreaID("silks"),
                  name: "Hip key → Star drop",
                  skillIds: ["climb", "invert", "hip-key", "thigh-hitch",
                             "cross-back", "star-drop"].map(SkillID.init),
                  updatedAt: now),
            Chain(id: ChainID("silks-crochet-line"), areaId: AreaID("silks"),
                  name: "Crochet flow",
                  skillIds: ["climb", "invert", "hip-key", "gazelle",
                             "crochet", "crochet-drop"].map(SkillID.init),
                  updatedAt: now),
            Chain(id: ChainID("silks-wrap-line"), areaId: AreaID("silks"),
                  name: "Foot lock → Wheel down",
                  skillIds: ["climb", "foot-lock-s", "foot-lock-d",
                             "star-wrap", "wheel-down"].map(SkillID.init),
                  updatedAt: now),
            Chain(id: ChainID("cali-pu-line"), areaId: AreaID("cali"),
                  name: "Push-up ladder",
                  skillIds: ["knee-pu", "pushup", "feet-elev", "archer",
                             "one-arm"].map(SkillID.init),
                  updatedAt: now),
            Chain(id: ChainID("dive-front-line"), areaId: AreaID("diving"),
                  name: "Front line",
                  skillIds: ["front-1m", "front-15", "front-25"]
                    .map(SkillID.init),
                  updatedAt: now),
        ]
    }
}

private struct SeedBuilder {
    let now: Date
    func skill(
        _ id: String, _ name: String, area: String,
        status: SkillStatus, x: Double, y: Double,
        prereqs: [String] = [], soft: [String] = [],
        foundation: Bool = false, helpsAreas: [String] = []
    ) -> Skill {
        Skill(
            id: SkillID(id),
            areaId: AreaID(area),
            name: name,
            status: status,
            x: x, y: y,
            prereqIds: prereqs.map(SkillID.init),
            softPrereqIds: soft.map(SkillID.init),
            isFoundation: foundation,
            helpsAreas: helpsAreas.map(AreaID.init),
            updatedAt: now
        )
    }
}

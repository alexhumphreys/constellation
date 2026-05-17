import ArgumentParser
import ConstellationCore
import Foundation

struct SkillCommands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Add, list, and update skills (stars in the constellation).",
        subcommands: [
            Add.self, List.self, Show.self, Status.self,
            Prereqs.self, Move.self, Delete.self,
        ]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a new skill to an area."
        )

        @Argument(help: "Stable id, e.g. 'hip-key'.") var id: String
        @Argument(help: "Display name.") var name: String

        @Option(name: .long, help: "Area id this skill belongs to.")
        var area: String

        @Option(name: .long)
        var status: SkillStatus = .locked

        @Option(name: .long, parsing: .upToNextOption,
                help: "Hard prereq skill IDs.")
        var prereqs: [String] = []

        @Option(name: .long, parsing: .upToNextOption,
                help: "Soft (recommended) prereq skill IDs.")
        var soft: [String] = []

        @Option(name: .long, help: "Virtual-sky x position.")
        var x: Double = 0

        @Option(name: .long, help: "Virtual-sky y position.")
        var y: Double = 0

        @Flag(name: .long, help: "Mark as a foundation skill (entry point).")
        var foundation: Bool = false

        func run() async throws {
            let ctx = try await AppContext.standard()
            let skill = Skill(
                id: SkillID(id),
                areaId: AreaID(area),
                name: name,
                status: status,
                x: x, y: y,
                prereqIds: prereqs.map(SkillID.init),
                softPrereqIds: soft.map(SkillID.init),
                isFoundation: foundation
            )
            try await ctx.store.upsertSkill(skill)
            print("added skill \(id) (\(name)) → \(area), status=\(status.rawValue)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List skills, optionally filtered by area and/or status."
        )

        @Option(name: .long, help: "Restrict to one area.")
        var area: String?

        @Option(name: .long, help: "Restrict to one status.")
        var status: SkillStatus?

        func run() async throws {
            let ctx = try await AppContext.standard()
            let areaId = area.map { AreaID($0) }
            var skills = try await ctx.store.skills(in: areaId)
            if let status {
                skills = skills.filter { $0.status == status }
            }
            skills.sort { ($0.areaId.rawValue, $0.name) < ($1.areaId.rawValue, $1.name) }
            if skills.isEmpty {
                print("no skills match.")
                return
            }
            for skill in skills {
                let marker = skill.isFoundation ? "★" : " "
                print("\(marker) \(skill.id.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(skill.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) [\(skill.areaId.rawValue)]  \(skill.name)")
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print all details for one skill including neighbours."
        )

        @Argument var id: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard let skill = try await ctx.store.skill(SkillID(id)) else {
                throw ValidationError("no skill '\(id)'")
            }
            let allSkills = try await ctx.store.skills()
            let graph = SkillGraph(allSkills)
            let neighbours = graph.neighbours(of: SkillID(id))
            let notes = try await ctx.store.notes(for: SkillID(id))
            let sessions = try await ctx.store.sessions(for: SkillID(id))
            let clips = try await ctx.store.clips(for: SkillID(id))

            print("\(skill.name)  (\(skill.id.rawValue))")
            print("  area:   \(skill.areaId.rawValue)")
            print("  status: \(skill.status.rawValue)  [\(skill.status.displayLabel)]")
            print("  pos:    (\(skill.x), \(skill.y))")
            if skill.isFoundation { print("  ★ foundation") }
            if !skill.helpsAreas.isEmpty {
                print("  helps:  \(skill.helpsAreas.map(\.rawValue).joined(separator: ", "))")
            }
            if let n = neighbours {
                if !n.prereqs.isEmpty {
                    print("  prereqs (\(n.prereqs.count)):")
                    for p in n.prereqs {
                        print("    - \(p.id.rawValue) (\(p.status.rawValue))  \(p.name)")
                    }
                }
                if !n.softPrereqs.isEmpty {
                    print("  recommended:")
                    for p in n.softPrereqs {
                        print("    - \(p.id.rawValue)  \(p.name)")
                    }
                }
                if !n.unlocks.isEmpty {
                    print("  unlocks (\(n.unlocks.count)):")
                    for u in n.unlocks {
                        print("    → \(u.id.rawValue) (\(u.status.rawValue))  \(u.name)")
                    }
                }
            }
            if !notes.isEmpty {
                print("  notes (\(notes.count)):")
                for note in notes.prefix(5) {
                    print("    · \(note.text)")
                }
            }
            if !sessions.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                print("  sessions (\(sessions.count)):")
                for s in sessions.prefix(5) {
                    print("    \(formatter.string(from: s.date))  \(s.text)")
                }
            }
            if !clips.isEmpty {
                print("  clips (\(clips.count)):")
                for c in clips.prefix(5) {
                    let byline = c.handle.map { " · \($0)" } ?? ""
                    print("    [\(c.platform)\(byline)]  \(c.title)")
                }
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a skill's status (master/got/drill/next/wish/locked)."
        )

        @Argument var id: String
        @Argument(help: "One of: master, got, drill, next, wish, locked.")
        var status: SkillStatus

        func run() async throws {
            let ctx = try await AppContext.standard()
            try await ctx.store.setStatus(status, for: SkillID(id))
            print("\(id) status → \(status.rawValue)")
        }
    }

    struct Prereqs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace the hard prereq list for a skill."
        )

        @Argument var id: String
        @Argument(parsing: .remaining, help: "Prereq skill IDs.")
        var prereqs: [String]

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard var skill = try await ctx.store.skill(SkillID(id)) else {
                throw ValidationError("no skill '\(id)'")
            }
            skill.prereqIds = prereqs.map(SkillID.init)
            skill.updatedAt = Date()
            try await ctx.store.upsertSkill(skill)
            print("\(id) prereqs → \(prereqs.joined(separator: ", "))")
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a skill's star to a new (x, y) in the virtual sky."
        )

        @Argument var id: String
        @Argument var x: Double
        @Argument var y: Double

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard var skill = try await ctx.store.skill(SkillID(id)) else {
                throw ValidationError("no skill '\(id)'")
            }
            skill.x = x
            skill.y = y
            skill.updatedAt = Date()
            try await ctx.store.upsertSkill(skill)
            print("\(id) → (\(x), \(y))")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Tombstone a skill (soft delete)."
        )

        @Argument var id: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            try await ctx.store.tombstoneSkill(SkillID(id))
            print("tombstoned skill \(id)")
        }
    }
}

extension SkillStatus: ExpressibleByArgument {}

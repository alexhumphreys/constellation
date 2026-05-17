import ArgumentParser
import ConstellationCore
import Foundation

struct ChainCommands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chain",
        abstract: "Add or inspect skill chains (transition sequences).",
        subcommands: [Add.self, List.self, Show.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a named chain of skills."
        )

        @Argument(help: "Stable id, e.g. 'silks-drop-line'.") var id: String
        @Argument(help: "Display name.") var name: String

        @Option(name: .long, help: "Area id.")
        var area: String

        @Argument(parsing: .remaining, help: "Skill IDs in stroke order.")
        var skills: [String]

        func run() async throws {
            guard !skills.isEmpty else {
                throw ValidationError("a chain needs at least one skill")
            }
            let ctx = try await AppContext.standard()
            let chain = Chain(
                id: ChainID(id),
                areaId: AreaID(area),
                name: name,
                skillIds: skills.map(SkillID.init)
            )
            try await ctx.store.upsertChain(chain)
            print("added chain \(id): \(name) (\(skills.count) skills)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List chains, optionally filtered by area."
        )

        @Option(name: .long) var area: String?

        func run() async throws {
            let ctx = try await AppContext.standard()
            let areaId = area.map { AreaID($0) }
            let chains = try await ctx.store.chains(in: areaId)
            if chains.isEmpty {
                print("no chains.")
                return
            }
            for chain in chains {
                print("\(chain.id.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) [\(chain.areaId.rawValue)] \(chain.skillIds.count)  \(chain.name)")
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one chain with each skill's current status."
        )

        @Argument var id: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard let chain = try await ctx.store.chain(ChainID(id)) else {
                throw ValidationError("no chain '\(id)'")
            }
            print("\(chain.name)  [\(chain.areaId.rawValue)]")
            for (i, sid) in chain.skillIds.enumerated() {
                let skill = try await ctx.store.skill(sid)
                let arrow = i == chain.skillIds.count - 1 ? "  " : "→"
                if let skill {
                    print("  \(skill.id.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) \(skill.status.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(skill.name)  \(arrow)")
                } else {
                    print("  \(sid.rawValue) (missing) \(arrow)")
                }
            }
        }
    }
}

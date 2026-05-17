import ArgumentParser
import ConstellationCore
import Foundation

struct ReadyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ready",
        abstract: """
            Skills you can start drilling now (all prereqs ≥ got, currently
            marked next or wish).
            """
    )

    @Option(name: .long, help: "Restrict to one area.")
    var area: String?

    func run() async throws {
        let ctx = try await AppContext.standard()
        let allSkills = try await ctx.store.skills()
        let graph = SkillGraph(allSkills)
        let ready = graph.ready(in: area.map { AreaID($0) })
        if ready.isEmpty {
            print("nothing ready right now — mark some prereqs `got` first.")
            return
        }
        for skill in ready {
            print("\(skill.id.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) [\(skill.areaId.rawValue)] \(skill.status.rawValue)  \(skill.name)")
        }
    }
}

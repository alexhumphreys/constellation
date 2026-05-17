import ArgumentParser
import ConstellationCore
import Foundation

struct SeedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed",
        abstract: """
            Populate the store with the design's demo data (4 areas, ~45
            skills, 5 chains). Idempotent — re-running merges via LWW.
            """
    )

    func run() async throws {
        let ctx = try await AppContext.standard()
        let snapshot = SeedData.snapshot()
        let stats = try await ctx.store.merge(snapshot)
        print("""
            seeded:
              areas=\(stats.areas) skills=\(stats.skills) chains=\(stats.chains)
            try `constellation area list` or `constellation skill list --area silks`.
            """)
    }
}

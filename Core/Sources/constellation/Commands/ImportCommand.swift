import ArgumentParser
import ConstellationCore
import Foundation

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Merge a JSON snapshot into the local store (CRDT-safe)."
    )

    @Argument(help: "Path to a snapshot JSON file (use '-' for stdin).")
    var file: String

    func run() async throws {
        let data: Data
        if file == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: file))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ConstellationSnapshot.self, from: data)

        let ctx = try await AppContext.standard()
        let stats = try await ctx.store.merge(snapshot)
        print("""
            merged snapshot (schema v\(snapshot.schemaVersion)):
              areas=\(stats.areas) skills=\(stats.skills) chains=\(stats.chains)
              sessions=\(stats.sessions) notes=\(stats.notes) clips=\(stats.clips)
              attachments=\(stats.attachments)
            """)
    }
}

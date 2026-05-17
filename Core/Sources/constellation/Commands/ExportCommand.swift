import ArgumentParser
import ConstellationCore
import Foundation

// Exports the entire store as a single pretty-printed JSON document.
// Pretty-printing is deliberate — the export doubles as the
// "vaguely human readable" Dropbox backup format the user wants. The
// schema is the canonical CRDT snapshot, so the same file can later be
// imported on another device to merge.
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export the entire store as JSON (for sync, AirDrop, Dropbox)."
    )

    @Option(name: .shortAndLong, help: "Output file. Default: stdout.")
    var output: String?

    func run() async throws {
        let ctx = try await AppContext.standard()
        let snapshot = try await ctx.store.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        if let output {
            try data.write(to: URL(fileURLWithPath: output))
            FileHandle.standardError.write(Data("wrote \(data.count) bytes to \(output)\n".utf8))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

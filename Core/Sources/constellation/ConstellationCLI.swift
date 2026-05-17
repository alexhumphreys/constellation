import ArgumentParser

@main
struct ConstellationCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "constellation",
        abstract: "Plot, navigate, and journal a constellation of skills.",
        subcommands: [
            AreaCommands.self,
            SkillCommands.self,
            ChainCommands.self,
            SessionCommands.self,
            NoteCommands.self,
            ClipCommands.self,
            ReadyCommand.self,
            JournalCommand.self,
            ExportCommand.self,
            ImportCommand.self,
            SeedCommand.self,
        ]
    )
}

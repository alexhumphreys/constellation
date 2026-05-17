import ArgumentParser
import ConstellationCore
import Foundation

struct NoteCommands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Add and list notes on skills.",
        subcommands: [Add.self, List.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a note to a skill."
        )

        @Argument var skill: String
        @Argument(parsing: .remaining) var text: [String]

        func run() async throws {
            let body = text.joined(separator: " ")
            guard !body.isEmpty else {
                throw ValidationError("note text is required")
            }
            let ctx = try await AppContext.standard()
            let note = Note(skillId: SkillID(skill), text: body)
            try await ctx.store.upsertNote(note)
            print("added note for \(skill)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List notes for a skill."
        )

        @Argument var skill: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            let notes = try await ctx.store.notes(for: SkillID(skill))
            if notes.isEmpty {
                print("no notes for \(skill).")
                return
            }
            for note in notes {
                print("· \(note.text)")
            }
        }
    }
}

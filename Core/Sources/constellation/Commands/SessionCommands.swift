import ArgumentParser
import ConstellationCore
import Foundation

struct SessionCommands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Log and list practice sessions per skill.",
        subcommands: [Log.self, List.self]
    )

    struct Log: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Log a practice session against a skill."
        )

        @Argument var skill: String
        @Argument(parsing: .remaining, help: "Free-text session notes.")
        var text: [String]

        @Option(name: .long, help: "Backdate the session (YYYY-MM-DD).")
        var date: String?

        func run() async throws {
            let body = text.joined(separator: " ")
            guard !body.isEmpty else {
                throw ValidationError("session text is required")
            }
            let when = try parseDate(date) ?? Date()
            let ctx = try await AppContext.standard()
            let session = Session(skillId: SkillID(skill), date: when, text: body)
            try await ctx.store.upsertSession(session)
            print("logged session \(session.id.rawValue.prefix(8))… for \(skill)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show recent sessions for a skill."
        )

        @Argument var skill: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            let sessions = try await ctx.store.sessions(for: SkillID(skill))
            if sessions.isEmpty {
                print("no sessions logged for \(skill).")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            for s in sessions {
                print("\(formatter.string(from: s.date))  \(s.text)")
            }
        }
    }
}

// Accepts YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS (ISO8601 subset). Local
// timezone for the date-only form — practice happens in wall time, not
// UTC, so backdating "yesterday" should mean "yesterday where I am".
func parseDate(_ raw: String?) throws -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let formatters: [DateFormatter] = [
        {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f
        }(),
        {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            f.timeZone = .current
            return f
        }(),
    ]
    for formatter in formatters {
        if let date = formatter.date(from: raw) { return date }
    }
    throw ValidationError("could not parse date '\(raw)' (try YYYY-MM-DD)")
}

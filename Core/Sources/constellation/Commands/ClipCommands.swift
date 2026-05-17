import ArgumentParser
import ConstellationCore
import Foundation

struct ClipCommands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip",
        abstract: "Attach saved video/article clips to a skill.",
        subcommands: [Add.self, List.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a clip (IG reel, YouTube, blog post) to a skill."
        )

        @Argument var skill: String

        @Option(name: .long, help: "Coarse platform bucket: 'Instagram', 'YouTube', 'Note', etc.")
        var platform: String

        @Option(name: .long, help: "Optional @-style creator handle, e.g. '@silks_tutor'.")
        var handle: String?

        @Option(name: .long) var title: String
        @Option(name: .long) var url: String?
        @Option(name: .long) var duration: String?
        @Option(name: .long) var note: String?

        func run() async throws {
            let ctx = try await AppContext.standard()
            let clip = Clip(
                skillId: SkillID(skill),
                platform: platform,
                handle: handle,
                title: title,
                url: url.flatMap(URL.init(string:)),
                duration: duration,
                note: note
            )
            try await ctx.store.upsertClip(clip)
            print("saved clip \(clip.id.rawValue.prefix(8))… for \(skill)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show clips saved on a skill."
        )

        @Argument var skill: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            let clips = try await ctx.store.clips(for: SkillID(skill))
            if clips.isEmpty {
                print("no clips for \(skill).")
                return
            }
            for clip in clips {
                let dur = clip.duration.map { " (\($0))" } ?? ""
                let byline = clip.handle.map { " · \($0)" } ?? ""
                print("[\(clip.platform)\(byline)] \(clip.title)\(dur)")
                if let url = clip.url { print("    \(url)") }
                if let note = clip.note { print("    note: \(note)") }
            }
        }
    }
}

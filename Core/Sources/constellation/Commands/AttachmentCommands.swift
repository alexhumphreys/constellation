import ArgumentParser
import ConstellationCore
import Foundation

struct AttachmentCommands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachment",
        abstract: "Attach device-captured photos/videos to a skill.",
        subcommands: [Add.self, List.self, Gc.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import a local file as an attachment on a skill."
        )

        @Argument var skill: String

        @Option(name: .long, help: "Path to a local image/video file.")
        var file: String

        @Option(name: .long) var caption: String?
        @Option(name: .long, help: "Pixel width (optional; iOS captures this automatically).")
        var width: Int = 0
        @Option(name: .long, help: "Pixel height (optional).")
        var height: Int = 0
        @Option(name: .long, help: "Duration in milliseconds (videos only).")
        var durationMs: Int?

        func run() async throws {
            let ctx = try await AppContext.standard()
            let url = URL(fileURLWithPath: file)
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let (mediaType, mimeType) = mediaInfo(for: ext)
            let hash = try await ctx.assets.write(data, fileExtension: ext)
            let attachment = Attachment(
                skillId: SkillID(skill),
                contentHash: hash,
                mediaType: mediaType,
                mimeType: mimeType,
                byteSize: Int64(data.count),
                width: width,
                height: height,
                durationMs: durationMs,
                caption: caption
            )
            try await ctx.store.upsertAttachment(attachment)
            print("""
                saved \(mediaType.rawValue) attachment for \(skill)
                  id: \(attachment.id.rawValue.prefix(8))…
                  hash: \(hash.prefix(12))…
                  bytes: \(data.count)
                """)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show attachments saved on a skill."
        )

        @Argument var skill: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            let atts = try await ctx.store.attachments(for: SkillID(skill))
            if atts.isEmpty {
                print("no attachments for \(skill).")
                return
            }
            for a in atts {
                let kb = a.byteSize / 1024
                let dim = (a.width > 0 && a.height > 0) ? " \(a.width)×\(a.height)" : ""
                let dur = a.durationMs.map { " \($0)ms" } ?? ""
                print("[\(a.mediaType.rawValue)\(dim) \(kb)KB\(dur)] \(a.contentHash.prefix(12))…")
                if let cap = a.caption { print("    \(cap)") }
            }
        }
    }

    struct Gc: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gc",
            abstract: "Delete on-disk asset files no longer referenced by a live attachment."
        )

        func run() async throws {
            let ctx = try await AppContext.standard()
            let referenced = try await ctx.store.liveContentHashes()
            let removed = try await ctx.assets.collectGarbage(referenced: referenced)
            print("removed \(removed) orphaned asset\(removed == 1 ? "" : "s").")
        }
    }
}

// Coarse extension → (media kind, MIME) mapping. Mirrors what the iOS
// PhotoKit pick path will derive at capture time; centralised here so
// the CLI and the eventual iOS importer agree on labelling.
private func mediaInfo(for ext: String) -> (MediaType, String) {
    switch ext {
    case "jpg", "jpeg": return (.photo, "image/jpeg")
    case "png":         return (.photo, "image/png")
    case "heic":        return (.photo, "image/heic")
    case "gif":         return (.photo, "image/gif")
    case "mov":         return (.video, "video/quicktime")
    case "mp4", "m4v":  return (.video, "video/mp4")
    default:            return (.photo, "application/octet-stream")
    }
}

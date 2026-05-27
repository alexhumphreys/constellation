import ArgumentParser
import ConstellationCore
import Foundation

struct AreaCommands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "area",
        abstract: "Manage constellations (silks, diving, dance…).",
        subcommands: [Add.self, List.self, Show.self, Tint.self, Layout.self, Delete.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a new area / constellation."
        )

        @Argument(help: "Stable id (e.g. 'silks').")
        var id: String

        @Argument(help: "Human-readable name.")
        var name: String

        @Option(name: .shortAndLong, help: "Hex tint, e.g. #e88a7a.")
        var tint: String = "#888888"

        @Option(name: .long, help: "Cluster center X in virtual sky.")
        var x: Double = 1200

        @Option(name: .long, help: "Cluster center Y in virtual sky.")
        var y: Double = 800

        @Option(name: .long, help: "Cluster radius.")
        var radius: Double = 400

        @Option(name: .long, help: "Layout strategy for new skills (manual|concentric).")
        var layout: String = LayoutKind.manual.rawValue

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard let kind = LayoutKind(rawValue: layout) else {
                throw ValidationError(
                    "unknown layout '\(layout)' — expected one of "
                    + LayoutKind.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            let area = Area(
                id: AreaID(id), name: name, tint: tint,
                centerX: x, centerY: y, radius: radius,
                layoutKind: kind
            )
            try await ctx.store.upsertArea(area)
            print("added area \(id) (\(name))")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all areas with their skill counts."
        )

        func run() async throws {
            let ctx = try await AppContext.standard()
            let areas = try await ctx.store.allAreas()
            if areas.isEmpty {
                print("no areas yet. add one with `constellation area add <id> <name>`.")
                return
            }
            for area in areas {
                let skills = try await ctx.store.skills(in: area.id)
                print("\(area.id.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(area.tint)  \(skills.count) skills  \(area.name)")
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one area's stats and skill list."
        )

        @Argument var id: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard let area = try await ctx.store.area(AreaID(id)) else {
                throw ValidationError("no area '\(id)'")
            }
            let skills = try await ctx.store.skills(in: area.id)
            print("\(area.name)  (\(area.id.rawValue))")
            print("  tint:   \(area.tint)")
            print("  center: (\(area.centerX), \(area.centerY))  r=\(area.radius)")
            print("  layout: \(area.layoutKind.rawValue)")
            print("  skills: \(skills.count)")
            let byStatus = Dictionary(grouping: skills, by: \.status)
            for status in SkillStatus.allCases {
                let count = byStatus[status]?.count ?? 0
                if count > 0 {
                    print("    \(status.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(count)")
                }
            }
        }
    }

    struct Tint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change an area's tint color."
        )

        @Argument var id: String
        @Argument(help: "New hex tint, e.g. #e88a7a.")
        var hex: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard var area = try await ctx.store.area(AreaID(id)) else {
                throw ValidationError("no area '\(id)'")
            }
            area.tint = Area.normalizeTint(hex)
            area.updatedAt = Date()
            try await ctx.store.upsertArea(area)
            print("\(id) tint → \(area.tint)")
        }
    }

    struct Layout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the auto-layout strategy for new skills in an area."
        )

        @Argument var id: String
        @Argument(help: "Strategy: manual or concentric.")
        var kind: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            guard let parsed = LayoutKind(rawValue: kind) else {
                throw ValidationError(
                    "unknown layout '\(kind)' — expected one of "
                    + LayoutKind.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            guard var area = try await ctx.store.area(AreaID(id)) else {
                throw ValidationError("no area '\(id)'")
            }
            area.layoutKind = parsed
            area.updatedAt = Date()
            try await ctx.store.upsertArea(area)
            print("\(id) layout → \(parsed.rawValue)")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Tombstone an area (soft delete, syncs across devices)."
        )

        @Argument var id: String

        func run() async throws {
            let ctx = try await AppContext.standard()
            try await ctx.store.tombstoneArea(AreaID(id))
            print("tombstoned area \(id)")
        }
    }
}

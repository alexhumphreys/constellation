import ArgumentParser
import ConstellationCore
import Foundation

// The journal view derives history from the wide-events log: every
// mutation is recorded, so "what did I do on May 10" is a single time
// range scan. This is the CLI surface for the "Maybe a journal, plus a
// history derived from the CRDTs" requirement — same data drives both.
struct JournalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal",
        abstract: "Show all events from the wide-events log for a day or range."
    )

    @Option(name: .long, help: "Date to inspect (YYYY-MM-DD). Default: today.")
    var date: String?

    @Option(name: .long, help: "Number of days back from --date to include.")
    var days: Int = 1

    @Option(name: .long, help: "Filter by op name (e.g. session.log).")
    var op: String?

    @Option(name: .long, help: "Filter by skill id.")
    var skill: String?

    func run() async throws {
        let ctx = try await AppContext.standard()
        let calendar = Calendar.current
        let endDay = (try parseDate(date)) ?? Date()
        let startOfEnd = calendar.startOfDay(for: endDay)
        let to = calendar.date(byAdding: .day, value: 1, to: startOfEnd) ?? endDay
        let from = calendar.date(byAdding: .day, value: -(days - 1),
                                 to: startOfEnd) ?? startOfEnd

        let events = try await ctx.store.events(
            from: from, to: to, op: op,
            skillId: skill.map { SkillID($0) }
        )
        if events.isEmpty {
            print("no events in window.")
            return
        }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "MM-dd HH:mm:ss"
        for event in events {
            var line = "\(timeFmt.string(from: event.timestamp))  \(event.op)  [\(event.outcome)]"
            if let sid = event.skillId { line += "  skill=\(sid)" }
            if let aid = event.areaId { line += "  area=\(aid)" }
            if let dur = event.durationMs {
                line += String(format: "  %.1fms", dur)
            }
            print(line)
            if let json = event.fieldsJSON, !json.isEmpty, json != "{}" {
                print("    \(json)")
            }
        }
    }
}

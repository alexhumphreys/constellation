import ArgumentParser
import ConstellationCore
import Foundation

// Dump the wide-events log as JSON for off-device forensics. The
// `journal` subcommand prints a human-readable view; this one writes
// machine-readable rows so two devices' logs can be diffed (jq, Splunk,
// a script), zipped, or ferried in a smaller file than the full SQLite.
// One JSON object per event with the same well-known dimensional fields
// the store persists, plus the overflow `fields` blob already
// represented as JSON.
struct ExportJournalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-journal",
        abstract: "Export the wide-events log as JSON (for off-device forensics)."
    )

    @Option(name: .long, help: "Lower bound (YYYY-MM-DD or ISO8601). Default: 30 days ago.")
    var since: String?

    @Option(name: .long, help: "Upper bound, exclusive. Default: tomorrow.")
    var until: String?

    @Option(name: .long, help: "Filter by op name (e.g. peer.snapshot.receive).")
    var op: String?

    @Option(name: .long, help: "Filter by skill id.")
    var skill: String?

    @Option(name: .shortAndLong, help: "Output file. Default: stdout.")
    var output: String?

    func run() async throws {
        let ctx = try await AppContext.standard()
        let calendar = Calendar.current
        let now = Date()
        let from = try parseDate(since)
            ?? calendar.date(byAdding: .day, value: -30, to: now)
            ?? now
        let to = try parseDate(until)
            ?? calendar.date(byAdding: .day, value: 1, to: now)
            ?? now

        let events = try await ctx.store.events(
            from: from, to: to, op: op,
            skillId: skill.map { SkillID($0) }
        )

        let rows = events.map(ExportedEvent.init(event:))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rows)

        if let output {
            try data.write(to: URL(fileURLWithPath: output))
            FileHandle.standardError.write(
                Data("wrote \(rows.count) events (\(data.count) bytes) to \(output)\n".utf8)
            )
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

// Mirror of PersistedEvent shaped for JSON output. `fields` is decoded
// from its stored string back into a free-form JSON object so the
// exported file is one nested document rather than rows with embedded
// JSON strings — friendlier for jq / Splunk parsing.
private struct ExportedEvent: Encodable {
    let timestamp: Date
    let op: String
    let outcome: String
    let correlationId: String?
    let durationMs: Double?
    let areaId: String?
    let skillId: String?
    let fields: AnyJSON?

    init(event: PersistedEvent) {
        self.timestamp = event.timestamp
        self.op = event.op
        self.outcome = event.outcome
        self.correlationId = event.correlationId
        self.durationMs = event.durationMs
        self.areaId = event.areaId
        self.skillId = event.skillId
        if let raw = event.fieldsJSON,
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data)
        {
            self.fields = AnyJSON(parsed)
        } else {
            self.fields = nil
        }
    }
}

// Tiny shim that re-encodes an arbitrary JSON-derived value (Dictionary,
// Array, String, Number, Bool, NSNull) back into JSON via JSONEncoder.
// JSONSerialization output isn't Encodable directly — wrap it once so
// the outer pretty-print pass can emit it without a separate code path.
private struct AnyJSON: Encodable {
    let value: Any

    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try encode(value, into: &container)
    }

    private func encode(_ value: Any, into container: inout SingleValueEncodingContainer) throws {
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyJSON.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyJSON.init))
        default:
            try container.encode(String(describing: value))
        }
    }
}

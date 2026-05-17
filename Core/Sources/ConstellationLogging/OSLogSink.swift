import Foundation
import OSLog

// Renders WideEvents to OSLog as one structured line per event. Each
// field is rendered as `key=value` in alphabetical order so a Console.app
// search for `op=skill.add` lands on every skill addition regardless of
// emission order. Quoting is minimal — only strings with whitespace or
// `=` get wrapped; everything else stays bare for readability.
public final class OSLogSink: EventSink, Sendable {
    private let logger: Logger

    public init(subsystem: String = "com.constellation.app", category: String = "wide") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func emit(_ event: WideEvent) {
        var parts: [String] = []
        parts.append("op=\(event.op)")
        parts.append("outcome=\(event.outcome.rawValue)")
        if let cid = event.correlationId { parts.append("cid=\(cid)") }
        if let dur = event.durationMs {
            parts.append("dur_ms=\(String(format: "%.1f", dur))")
        }
        for key in event.fields.keys.sorted() {
            guard let value = event.fields[key] else { continue }
            parts.append("\(key)=\(format(value))")
        }
        let line = parts.joined(separator: " ")
        // OSLog %{public}@ — these events are local-machine telemetry, no
        // PII (skill names, area names) we need to redact in field logs.
        logger.info("\(line, privacy: .public)")
    }

    private func format(_ value: WideValue) -> String {
        switch value {
        case .string(let s):
            if s.contains(where: { $0 == " " || $0 == "=" || $0 == "\"" }) {
                let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            return s
        case .int(let i): return String(i)
        case .double(let d): return String(format: "%.4g", d)
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

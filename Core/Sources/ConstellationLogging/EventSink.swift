import Foundation
import Synchronization

public protocol EventSink: Sendable {
    func emit(_ event: WideEvent)
}

// Fan-out sink — emits to multiple downstream sinks. Used by the app
// context to send each event to OSLog *and* the database sink in one
// call. Errors in one sink don't affect the others (each sink is
// responsible for its own swallowing).
public final class CompositeSink: EventSink, Sendable {
    private let sinks: [EventSink]
    public init(_ sinks: [EventSink]) { self.sinks = sinks }
    public func emit(_ event: WideEvent) {
        for sink in sinks { sink.emit(event) }
    }
}

// In-memory sink for tests. Lock-backed so concurrent emit() calls from
// TaskGroup-style fan-out don't lose events.
public final class RecordingSink: EventSink, Sendable {
    private let storage: Mutex<[WideEvent]> = Mutex([])

    public init() {}

    public func emit(_ event: WideEvent) {
        storage.withLock { $0.append(event) }
    }

    public var events: [WideEvent] {
        storage.withLock { $0 }
    }

    public func reset() {
        storage.withLock { $0.removeAll() }
    }
}

// Drops every event. Useful as a "real" default in throwaway contexts
// (e.g. one-shot CLI commands where you don't care about the audit log)
// and as the parent type in tests that don't need to inspect events.
public final class NoopSink: EventSink, Sendable {
    public init() {}
    public func emit(_ event: WideEvent) {}
}

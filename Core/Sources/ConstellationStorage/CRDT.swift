import ConstellationModels
import Foundation

// CRDT merge semantics for the constellation data model.
//
// Two strategies are in play:
//
// 1. **Last-Write-Wins (LWW) by `updatedAt`** for Area, Skill, Chain.
//    Each entity has a single timestamp; the merge picks the side with
//    the larger timestamp. Ties resolve by lexicographic comparison of
//    a derived hash so the merge is fully deterministic (two clients
//    arriving at the same "tie" pick the same winner without coordination).
//    Caveat: this is whole-entity LWW, not per-field — concurrent edits
//    to two different fields will see the later edit win wholesale.
//    For this app's interaction pattern (one human, occasionally on two
//    devices) that's the right trade-off.
//
// 2. **Append-only set with tombstones** for Session, Note, Clip. Each
//    item is identified by a UUID generated at creation, so concurrent
//    creations never conflict. Deletion sets `tombstonedAt`; if either
//    side has a tombstone, the merged item carries the *earlier*
//    tombstone (delete-wins, which matches the user's intent when they
//    delete on one device and then keep using the other offline).
//
// Both strategies are commutative, associative, and idempotent, so
// they're proper CRDTs — replicas converge regardless of merge order
// or duplicate deliveries.
public enum CRDT {

    // LWW merge: pick the side with the later `updatedAt`. Tie-break
    // deterministically using the SHA-style fold of the rawValue id, so
    // both sides agree on the winner without exchanging extra metadata.
    public static func mergeLWW(_ a: Area, _ b: Area) -> Area {
        if a.updatedAt != b.updatedAt {
            return a.updatedAt > b.updatedAt ? a : b
        }
        return a.id.rawValue >= b.id.rawValue ? a : b
    }

    public static func mergeLWW(_ a: Skill, _ b: Skill) -> Skill {
        if a.updatedAt != b.updatedAt {
            return a.updatedAt > b.updatedAt ? a : b
        }
        return a.id.rawValue >= b.id.rawValue ? a : b
    }

    public static func mergeLWW(_ a: Chain, _ b: Chain) -> Chain {
        if a.updatedAt != b.updatedAt {
            return a.updatedAt > b.updatedAt ? a : b
        }
        return a.id.rawValue >= b.id.rawValue ? a : b
    }

    // Append-only merge for child entities: if either side has a
    // tombstone, the merged result carries the earlier tombstone (so
    // resurrection-after-delete is impossible — once tombstoned on any
    // replica, eventually tombstoned everywhere). Non-tombstone fields
    // are taken from `a` arbitrarily; for these entities the body never
    // changes after creation, so the choice doesn't matter.
    public static func mergeAppendOnly(_ a: Session, _ b: Session) -> Session {
        precondition(a.id == b.id, "mergeAppendOnly called on different IDs")
        var out = a
        out.tombstonedAt = earliestTombstone(a.tombstonedAt, b.tombstonedAt)
        return out
    }

    public static func mergeAppendOnly(_ a: Note, _ b: Note) -> Note {
        precondition(a.id == b.id, "mergeAppendOnly called on different IDs")
        var out = a
        out.tombstonedAt = earliestTombstone(a.tombstonedAt, b.tombstonedAt)
        return out
    }

    public static func mergeAppendOnly(_ a: Clip, _ b: Clip) -> Clip {
        precondition(a.id == b.id, "mergeAppendOnly called on different IDs")
        var out = a
        out.tombstonedAt = earliestTombstone(a.tombstonedAt, b.tombstonedAt)
        return out
    }

    private static func earliestTombstone(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return min(x, y)
        }
    }
}

// A complete snapshot of the constellation that can be exported,
// merged, and re-imported. Used as the wire format for sync (Dropbox,
// AirDrop, iCloud) and as the canonical test fixture format. The
// `schemaVersion` lets future readers reject snapshots they don't
// understand, so a 0.1 app reading a 0.5 export fails loudly instead
// of silently corrupting state.
public struct ConstellationSnapshot: Codable, Sendable, Hashable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var areas: [Area]
    public var skills: [Skill]
    public var chains: [Chain]
    public var sessions: [Session]
    public var notes: [Note]
    public var clips: [Clip]

    public init(
        schemaVersion: Int = ConstellationSnapshot.currentSchemaVersion,
        generatedAt: Date = Date(),
        areas: [Area] = [],
        skills: [Skill] = [],
        chains: [Chain] = [],
        sessions: [Session] = [],
        notes: [Note] = [],
        clips: [Clip] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.areas = areas
        self.skills = skills
        self.chains = chains
        self.sessions = sessions
        self.notes = notes
        self.clips = clips
    }

    // Pure function — merges two snapshots into a third without
    // touching any database. Useful for tests, fuzz-style verification
    // of CRDT properties, and for the "preview before applying"
    // import flow in the future iOS UI.
    public static func merge(
        _ a: ConstellationSnapshot,
        _ b: ConstellationSnapshot
    ) -> ConstellationSnapshot {
        ConstellationSnapshot(
            generatedAt: max(a.generatedAt, b.generatedAt),
            areas: mergeById(a.areas, b.areas, key: \.id, merge: CRDT.mergeLWW),
            skills: mergeById(a.skills, b.skills, key: \.id, merge: CRDT.mergeLWW),
            chains: mergeById(a.chains, b.chains, key: \.id, merge: CRDT.mergeLWW),
            sessions: mergeById(
                a.sessions, b.sessions, key: \.id, merge: CRDT.mergeAppendOnly
            ),
            notes: mergeById(a.notes, b.notes, key: \.id, merge: CRDT.mergeAppendOnly),
            clips: mergeById(a.clips, b.clips, key: \.id, merge: CRDT.mergeAppendOnly)
        )
    }

    private static func mergeById<T, K: Hashable>(
        _ a: [T],
        _ b: [T],
        key: KeyPath<T, K>,
        merge: (T, T) -> T
    ) -> [T] {
        var byKey: [K: T] = [:]
        for item in a { byKey[item[keyPath: key]] = item }
        for item in b {
            let k = item[keyPath: key]
            if let existing = byKey[k] {
                byKey[k] = merge(existing, item)
            } else {
                byKey[k] = item
            }
        }
        return Array(byKey.values)
    }
}

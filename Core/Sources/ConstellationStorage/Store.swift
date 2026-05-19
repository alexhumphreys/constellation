import ConstellationLogging
import ConstellationModels
import Foundation
import GRDB

// The store is the only thing that talks to GRDB. Every public method
// emits exactly one WideEvent at completion (no start markers — a
// missing rollup with orphaned correlation IDs is itself a useful signal
// for partially-completed work). The CRDT-friendly upsert variants
// (`upsertArea`, `upsertSkill`, etc.) are the canonical write paths for
// sync — they apply LWW semantics atomically so concurrent applies of
// an inbound snapshot can't end up with a half-merged row.
public actor Store {
    private let writer: any DatabaseWriter
    private let sink: any EventSink
    private let now: @Sendable () -> Date

    public init(
        url: URL,
        sink: any EventSink = NoopSink(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.writer = try DatabasePool(path: url.path, configuration: config)
        self.sink = sink
        self.now = now
        try Migrations.migrator.migrate(self.writer)
    }

    // In-memory variant for tests — no file is created, the database
    // dies with the actor. Same migrator runs so test schemas stay
    // honest with production schemas.
    public init(
        inMemory: Bool,
        sink: any EventSink = NoopSink(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        precondition(inMemory, "use init(url:) for on-disk stores")
        self.writer = try DatabaseQueue()
        self.sink = sink
        self.now = now
        try Migrations.migrator.migrate(self.writer)
    }

    // MARK: - Area

    public func upsertArea(_ area: Area) throws {
        let start = now()
        let existing = try writer.read { db in
            try AreaRow.fetchOne(db, key: area.id.rawValue)?.toModel()
        }
        let merged = existing.map { CRDT.mergeLWW($0, area) } ?? area
        try writer.write { db in
            try AreaRow(merged).save(db)
            try insertEvent(
                db,
                WideEvent(
                    op: "area.upsert",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "area_id": .string(area.id.rawValue),
                        "name": .string(merged.name),
                        "was_existing": .bool(existing != nil),
                        "lww_winner": .string(
                            existing == nil ? "new" :
                                (merged.updatedAt == area.updatedAt ? "incoming" : "local")
                        ),
                    ]
                )
            )
        }
    }

    public func allAreas(includeTombstoned: Bool = false) throws -> [Area] {
        let areas: [Area] = try writer.read { db in
            let rows = try AreaRow.fetchAll(db)
            let models = rows.map { $0.toModel() }
            return includeTombstoned ? models : models.filter { !$0.isDeleted }
        }
        return areas.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func area(_ id: AreaID) throws -> Area? {
        try writer.read { db in
            try AreaRow.fetchOne(db, key: id.rawValue)?.toModel()
        }
    }

    public func tombstoneArea(_ id: AreaID) throws {
        guard var area = try self.area(id) else { return }
        area.tombstonedAt = now()
        area.updatedAt = now()
        try upsertArea(area)
    }

    // MARK: - Skill

    public func upsertSkill(_ skill: Skill) throws {
        let start = now()
        let existing = try writer.read { db in
            try SkillRow.fetchOne(db, key: skill.id.rawValue)?.toModel()
        }
        let merged = existing.map { CRDT.mergeLWW($0, skill) } ?? skill
        try writer.write { db in
            try SkillRow(merged).save(db)
            try insertEvent(
                db,
                WideEvent(
                    op: "skill.upsert",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "skill_id": .string(skill.id.rawValue),
                        "area_id": .string(merged.areaId.rawValue),
                        "name": .string(merged.name),
                        "status": .string(merged.status.rawValue),
                        "was_existing": .bool(existing != nil),
                        "prereq_count": .int(Int64(merged.prereqIds.count)),
                    ]
                )
            )
        }
    }

    public func skills(
        in areaId: AreaID? = nil,
        includeTombstoned: Bool = false
    ) throws -> [Skill] {
        try writer.read { db in
            let rows: [SkillRow]
            if let areaId {
                rows = try SkillRow
                    .filter(Column("area_id") == areaId.rawValue)
                    .fetchAll(db)
            } else {
                rows = try SkillRow.fetchAll(db)
            }
            let models = rows.map { $0.toModel() }
            return includeTombstoned ? models : models.filter { !$0.isDeleted }
        }
    }

    public func skill(_ id: SkillID) throws -> Skill? {
        try writer.read { db in
            try SkillRow.fetchOne(db, key: id.rawValue)?.toModel()
        }
    }

    public func setStatus(_ status: SkillStatus, for id: SkillID) throws {
        guard var skill = try self.skill(id) else { return }
        skill.status = status
        skill.updatedAt = now()
        try upsertSkill(skill)
    }

    public func tombstoneSkill(_ id: SkillID) throws {
        guard var skill = try self.skill(id) else { return }
        skill.tombstonedAt = now()
        skill.updatedAt = now()
        try upsertSkill(skill)
    }

    // MARK: - Chain

    public func upsertChain(_ chain: Chain) throws {
        let start = now()
        let existing = try writer.read { db in
            try ChainRow.fetchOne(db, key: chain.id.rawValue)?.toModel()
        }
        let merged = existing.map { CRDT.mergeLWW($0, chain) } ?? chain
        try writer.write { db in
            try ChainRow(merged).save(db)
            try insertEvent(
                db,
                WideEvent(
                    op: "chain.upsert",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "area_id": .string(merged.areaId.rawValue),
                        "name": .string(merged.name),
                        "skill_count": .int(Int64(merged.skillIds.count)),
                        "was_existing": .bool(existing != nil),
                    ]
                )
            )
        }
    }

    public func chains(in areaId: AreaID? = nil) throws -> [Chain] {
        try writer.read { db in
            let rows: [ChainRow]
            if let areaId {
                rows = try ChainRow
                    .filter(Column("area_id") == areaId.rawValue)
                    .fetchAll(db)
            } else {
                rows = try ChainRow.fetchAll(db)
            }
            return rows.map { $0.toModel() }.filter { !$0.isDeleted }
        }
    }

    public func chain(_ id: ChainID) throws -> Chain? {
        try writer.read { db in
            try ChainRow.fetchOne(db, key: id.rawValue)?.toModel()
        }
    }

    // MARK: - Session

    public func upsertSession(_ session: Session) throws {
        let start = now()
        let existing = try writer.read { db in
            try SessionRow.fetchOne(db, key: session.id.rawValue)?.toModel()
        }
        let merged = existing.map { CRDT.mergeAppendOnly($0, session) } ?? session
        try writer.write { db in
            try SessionRow(merged).save(db)
            try insertEvent(
                db,
                WideEvent(
                    op: "session.log",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "skill_id": .string(session.skillId.rawValue),
                        "session_id": .string(session.id.rawValue),
                        "text_len": .int(Int64(session.text.count)),
                    ]
                )
            )
        }
    }

    public func sessions(for skillId: SkillID) throws -> [Session] {
        try writer.read { db in
            try SessionRow
                .filter(Column("skill_id") == skillId.rawValue)
                .order(Column("date").desc)
                .fetchAll(db)
                .map { $0.toModel() }
                .filter { !$0.isDeleted }
        }
    }

    // MARK: - Note

    public func upsertNote(_ note: Note) throws {
        let start = now()
        let existing = try writer.read { db in
            try NoteRow.fetchOne(db, key: note.id.rawValue)?.toModel()
        }
        let merged = existing.map { CRDT.mergeAppendOnly($0, note) } ?? note
        try writer.write { db in
            try NoteRow(merged).save(db)
            try insertEvent(
                db,
                WideEvent(
                    op: "note.add",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "skill_id": .string(note.skillId.rawValue),
                        "note_id": .string(note.id.rawValue),
                        "text_len": .int(Int64(note.text.count)),
                    ]
                )
            )
        }
    }

    public func notes(for skillId: SkillID) throws -> [Note] {
        try writer.read { db in
            try NoteRow
                .filter(Column("skill_id") == skillId.rawValue)
                .order(Column("added_at").desc)
                .fetchAll(db)
                .map { $0.toModel() }
                .filter { !$0.isDeleted }
        }
    }

    // MARK: - Clip

    public func upsertClip(_ clip: Clip) throws {
        let start = now()
        let existing = try writer.read { db in
            try ClipRow.fetchOne(db, key: clip.id.rawValue)?.toModel()
        }
        let merged = existing.map { CRDT.mergeMutableAppendOnly($0, clip) } ?? clip
        try writer.write { db in
            try ClipRow(merged).save(db)
            try insertEvent(
                db,
                WideEvent(
                    op: "clip.add",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "skill_id": .string(clip.skillId.rawValue),
                        "clip_id": .string(clip.id.rawValue),
                        "platform": .string(clip.platform),
                        "has_handle": .bool(clip.handle != nil),
                        "has_url": .bool(clip.url != nil),
                        "was_existing": .bool(existing != nil),
                    ]
                )
            )
        }
    }

    public func clips(for skillId: SkillID) throws -> [Clip] {
        try writer.read { db in
            try ClipRow
                .filter(Column("skill_id") == skillId.rawValue)
                .order(Column("added_at").desc)
                .fetchAll(db)
                .map { $0.toModel() }
                .filter { !$0.isDeleted }
        }
    }

    // MARK: - Attachment

    public func upsertAttachment(_ attachment: Attachment) throws {
        let start = now()
        let existing = try writer.read { db in
            try AttachmentRow.fetchOne(db, key: attachment.id.rawValue)?.toModel()
        }
        let merged = existing.map { CRDT.mergeMutableAppendOnly($0, attachment) } ?? attachment
        try writer.write { db in
            try AttachmentRow(merged).save(db)
            try insertEvent(
                db,
                WideEvent(
                    op: "attachment.add",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "skill_id": .string(attachment.skillId.rawValue),
                        "attachment_id": .string(attachment.id.rawValue),
                        "content_hash": .string(attachment.contentHash),
                        "media_type": .string(attachment.mediaType.rawValue),
                        "byte_size": .int(attachment.byteSize),
                        "was_existing": .bool(existing != nil),
                    ]
                )
            )
        }
    }

    public func attachments(for skillId: SkillID) throws -> [Attachment] {
        try writer.read { db in
            try AttachmentRow
                .filter(Column("skill_id") == skillId.rawValue)
                .order(Column("added_at").desc)
                .fetchAll(db)
                .map { $0.toModel() }
                .filter { !$0.isDeleted }
        }
    }

    public func attachment(_ id: AttachmentID) throws -> Attachment? {
        try writer.read { db in
            try AttachmentRow.fetchOne(db, key: id.rawValue)?.toModel()
        }
    }

    public func tombstoneAttachment(_ id: AttachmentID) throws {
        guard var a = try self.attachment(id) else { return }
        a.tombstonedAt = now()
        a.updatedAt = now()
        try upsertAttachment(a)
    }

    // Set of `contentHash`es referenced by at least one live (non-
    // tombstoned) attachment. The MC blob-reconciliation phase compares
    // this against the on-disk asset set to decide what to request from
    // a peer; the GC path compares it against the on-disk set to decide
    // what to delete. Tombstoned rows are excluded — they keep ids alive
    // for sync convergence but their bytes are eligible for collection
    // once no other live row references the same hash.
    public func liveContentHashes() throws -> Set<String> {
        try writer.read { db in
            let rows = try AttachmentRow
                .filter(Column("tombstoned_at") == nil)
                .fetchAll(db)
            return Set(rows.map { $0.contentHash })
        }
    }

    // MARK: - Snapshot (export/import)

    public func snapshot() throws -> ConstellationSnapshot {
        try writer.read { db in
            ConstellationSnapshot(
                areas: try AreaRow.fetchAll(db).map { $0.toModel() },
                skills: try SkillRow.fetchAll(db).map { $0.toModel() },
                chains: try ChainRow.fetchAll(db).map { $0.toModel() },
                sessions: try SessionRow.fetchAll(db).map { $0.toModel() },
                notes: try NoteRow.fetchAll(db).map { $0.toModel() },
                clips: try ClipRow.fetchAll(db).map { $0.toModel() },
                attachments: try AttachmentRow.fetchAll(db).map { $0.toModel() }
            )
        }
    }

    // Apply an incoming snapshot. Each entity goes through the same
    // upsert path that interactive writes use, so CRDT semantics
    // (LWW for entities, tombstone-wins for append-only logs) apply
    // uniformly. Returns counts for the caller to surface in the
    // import command output.
    @discardableResult
    public func merge(_ snapshot: ConstellationSnapshot) throws -> MergeStats {
        let start = now()
        guard snapshot.schemaVersion == ConstellationSnapshot.currentSchemaVersion else {
            throw StoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        for area in snapshot.areas { try upsertArea(area) }
        for skill in snapshot.skills { try upsertSkill(skill) }
        for chain in snapshot.chains { try upsertChain(chain) }
        for session in snapshot.sessions { try upsertSession(session) }
        for note in snapshot.notes { try upsertNote(note) }
        for clip in snapshot.clips { try upsertClip(clip) }
        for attachment in snapshot.attachments { try upsertAttachment(attachment) }
        let stats = MergeStats(
            areas: snapshot.areas.count,
            skills: snapshot.skills.count,
            chains: snapshot.chains.count,
            sessions: snapshot.sessions.count,
            notes: snapshot.notes.count,
            clips: snapshot.clips.count,
            attachments: snapshot.attachments.count
        )
        try writer.write { db in
            try insertEvent(
                db,
                WideEvent(
                    op: "store.merge",
                    timestamp: start,
                    outcome: .ok,
                    durationMs: ms(since: start),
                    fields: [
                        "areas": .int(Int64(stats.areas)),
                        "skills": .int(Int64(stats.skills)),
                        "chains": .int(Int64(stats.chains)),
                        "sessions": .int(Int64(stats.sessions)),
                        "notes": .int(Int64(stats.notes)),
                        "clips": .int(Int64(stats.clips)),
                        "attachments": .int(Int64(stats.attachments)),
                    ]
                )
            )
        }
        return stats
    }

    public struct MergeStats: Sendable, Hashable {
        public let areas: Int
        public let skills: Int
        public let chains: Int
        public let sessions: Int
        public let notes: Int
        public let clips: Int
        public let attachments: Int
    }

    // MARK: - Wide events / journal

    // Public emit path for callers outside the Store that still want
    // their business-logic observability to land in the same
    // wide_events table the journal CLI reads. Used by the iOS app's
    // PeerSync (peer.connect, peer.snapshot.send, etc.) so MC sync
    // shows up in the journal alongside store mutations. The sink
    // fan-out is the same as internal events.
    public func emit(_ event: WideEvent) throws {
        try writer.write { db in
            try insertEvent(db, event)
        }
    }

    // Range query for the journal view. Returns events between
    // [from, to) in chronological order so reconstructing "what I did
    // on May 10" is one scan, not a join.
    public func events(
        from: Date,
        to: Date,
        op: String? = nil,
        skillId: SkillID? = nil
    ) throws -> [PersistedEvent] {
        try writer.read { db in
            var query = WideEventRow
                .filter(Column("ts") >= from)
                .filter(Column("ts") < to)
            if let op {
                query = query.filter(Column("op") == op)
            }
            if let skillId {
                query = query.filter(Column("skill_id") == skillId.rawValue)
            }
            return try query
                .order(Column("ts"))
                .fetchAll(db)
                .map(PersistedEvent.init(row:))
        }
    }

    // MARK: - Private helpers

    private func insertEvent(_ db: Database, _ event: WideEvent) throws {
        // Persist to wide_events table AND fan out to the configured sink
        // so observability targets (OSLog, future ClickHouse, etc.) see
        // the same events the journal does.
        try WideEventRow.from(event).insert(db)
        sink.emit(event)
    }

    private func ms(since start: Date) -> Double {
        now().timeIntervalSince(start) * 1000.0
    }
}

public enum StoreError: Error, Sendable, Equatable {
    case unsupportedSchema(Int)
}

// User-facing projection of a persisted WideEventRow. Avoids exposing
// GRDB internals to higher layers.
public struct PersistedEvent: Sendable, Hashable {
    public let timestamp: Date
    public let op: String
    public let outcome: String
    public let correlationId: String?
    public let durationMs: Double?
    public let areaId: String?
    public let skillId: String?
    public let fieldsJSON: String?

    init(row: WideEventRow) {
        self.timestamp = row.ts
        self.op = row.op
        self.outcome = row.outcome
        self.correlationId = row.correlationId
        self.durationMs = row.durationMs
        self.areaId = row.areaId
        self.skillId = row.skillId
        self.fieldsJSON = row.fieldsJson
    }
}

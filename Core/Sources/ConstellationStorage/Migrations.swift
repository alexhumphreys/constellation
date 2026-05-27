import ConstellationModels
import Foundation
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial_schema") { db in
            try createAreasTable(db)
            try createSkillsTable(db)
            try createChainsTable(db)
            try createSessionsTable(db)
            try createNotesTable(db)
            try createClipsTable(db)
            try createWideEventsTable(db)
        }

        // The freeform `source` field was confusing on iOS — auto-derived
        // platform + optional @handle reads cleaner and pairs with future
        // IG/YT API integration (handle/embed pulled from URL). Existing
        // v0.1 dbs at this version contain only test data, so we keep the
        // migration simple: copy `source` into `platform` verbatim, leave
        // `handle` null, then drop the old column.
        m.registerMigration("v2_split_clip_source") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "platform", .text).notNull().defaults(to: "Other")
                t.add(column: "handle", .text)
            }
            try db.execute(sql: "UPDATE clips SET platform = source")
            try db.alter(table: "clips") { t in
                t.drop(column: "source")
            }
        }

        // Promote Clip from strict-append-only to LWW-with-tombstones so
        // edits on a saved clip (most commonly: add a note after the
        // fact, fix a wrong URL) can actually propagate through the CRDT
        // merge. Backfill `updated_at = added_at` so existing rows have a
        // sane clock — the next user-driven edit bumps it forward.
        m.registerMigration("v3_clip_updated_at") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "updated_at", .datetime)
            }
            try db.execute(sql: "UPDATE clips SET updated_at = added_at")
            // Tighten the schema so future inserts can't skip the clock.
            // SQLite can't add NOT NULL post-hoc, so we mirror the rest
            // of the codebase's pattern (a defensive `coalesce` in the
            // model layer would also work; this is cleaner).
            try db.execute(sql: """
                CREATE TABLE clips_new (
                    id TEXT PRIMARY KEY,
                    skill_id TEXT NOT NULL REFERENCES skills(id) ON DELETE RESTRICT,
                    platform TEXT NOT NULL DEFAULT 'Other',
                    handle TEXT,
                    title TEXT NOT NULL,
                    url TEXT,
                    duration TEXT,
                    note TEXT,
                    added_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    tombstoned_at DATETIME
                )
            """)
            try db.execute(sql: """
                INSERT INTO clips_new SELECT
                    id, skill_id, platform, handle, title, url, duration,
                    note, added_at, updated_at, tombstoned_at
                FROM clips
            """)
            try db.execute(sql: "DROP TABLE clips")
            try db.execute(sql: "ALTER TABLE clips_new RENAME TO clips")
            try db.create(
                index: "idx_clips_skill_added", on: "clips",
                columns: ["skill_id", "added_at"]
            )
        }

        // Skills gained an `aliases` JSON column so search can match
        // alternate names without splitting equivalent moves across
        // separate rows. Existing rows backfill to the empty array.
        m.registerMigration("v4_skill_aliases") { db in
            try db.alter(table: "skills") { t in
                t.add(column: "aliases", .text).notNull().defaults(to: "[]")
            }
        }

        // New `attachments` table for device-captured photos and videos.
        // Distinct from `clips` (which holds streamable platform-hosted
        // refs) because Attachment owns its bytes and the storage, sync,
        // and GC mechanics that come with that. `content_hash` is the
        // sha256-hex of the file bytes and doubles as the on-disk
        // filename stem (`Documents/assets/<content_hash>.<ext>`) and
        // the MC blob-reconciliation key. Indexed because the GC path
        // and the sync request-set both pivot on it.
        m.registerMigration("v5_attachments") { db in
            try createAttachmentsTable(db)
        }

        // Promote Note from strict-append-only to LWW-with-tombstones so
        // users can edit a note in place (fix a typo, refine a coach cue)
        // and have the edit propagate through the CRDT merge. Same shape
        // as the Clip v3 migration: backfill `updated_at = added_at` and
        // recreate the table to enforce NOT NULL.
        m.registerMigration("v6_note_updated_at") { db in
            try db.alter(table: "notes") { t in
                t.add(column: "updated_at", .datetime)
            }
            try db.execute(sql: "UPDATE notes SET updated_at = added_at")
            try db.execute(sql: """
                CREATE TABLE notes_new (
                    id TEXT PRIMARY KEY,
                    skill_id TEXT NOT NULL REFERENCES skills(id) ON DELETE RESTRICT,
                    text TEXT NOT NULL,
                    added_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    tombstoned_at DATETIME
                )
            """)
            try db.execute(sql: """
                INSERT INTO notes_new SELECT
                    id, skill_id, text, added_at, updated_at, tombstoned_at
                FROM notes
            """)
            try db.execute(sql: "DROP TABLE notes")
            try db.execute(sql: "ALTER TABLE notes_new RENAME TO notes")
            try db.create(
                index: "idx_notes_skill_added", on: "notes",
                columns: ["skill_id", "added_at"]
            )
        }

        // Per-area placement strategy for fresh skills. `.manual` matches
        // the historical drop-at-center spiral-out behaviour; algorithms
        // (`.concentric` initially) compute a position from the new
        // skill's relationship to its prereqs. Backfill = `"manual"` so
        // existing hobbies stay opt-out by default.
        m.registerMigration("v7_area_layout_kind") { db in
            try db.alter(table: "areas") { t in
                t.add(column: "layout_kind", .text)
                    .notNull()
                    .defaults(to: "manual")
            }
        }

        return m
    }

    private static func createAreasTable(_ db: Database) throws {
        try db.create(table: "areas") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("tint", .text).notNull().defaults(to: "#888888")
            t.column("center_x", .double).notNull().defaults(to: 0)
            t.column("center_y", .double).notNull().defaults(to: 0)
            t.column("radius", .double).notNull().defaults(to: 400)
            t.column("updated_at", .datetime).notNull()
            t.column("tombstoned_at", .datetime)
        }
        try db.create(
            index: "idx_areas_updated", on: "areas", columns: ["updated_at"]
        )
    }

    private static func createSkillsTable(_ db: Database) throws {
        try db.create(table: "skills") { t in
            t.primaryKey("id", .text)
            t.column("area_id", .text)
                .notNull()
                .references("areas", onDelete: .restrict)
            t.column("name", .text).notNull()
            t.column("status", .text).notNull().defaults(to: "locked")
            t.column("x", .double).notNull().defaults(to: 0)
            t.column("y", .double).notNull().defaults(to: 0)
            // JSON arrays — kept whole-blob so CRDT-LWW merges atomically.
            // Reads pay a small JSON parse cost per row; if that becomes
            // hot for the constellation canvas we can materialize an
            // edges/adjacency table off the side without changing the
            // canonical schema.
            t.column("prereq_ids", .text).notNull().defaults(to: "[]")
            t.column("soft_prereq_ids", .text).notNull().defaults(to: "[]")
            t.column("helps_areas", .text).notNull().defaults(to: "[]")
            t.column("is_foundation", .boolean).notNull().defaults(to: false)
            t.column("updated_at", .datetime).notNull()
            t.column("tombstoned_at", .datetime)
        }
        try db.create(
            index: "idx_skills_area", on: "skills", columns: ["area_id"]
        )
        try db.create(
            index: "idx_skills_status", on: "skills", columns: ["status"]
        )
    }

    private static func createChainsTable(_ db: Database) throws {
        try db.create(table: "chains") { t in
            t.primaryKey("id", .text)
            t.column("area_id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("skill_ids", .text).notNull().defaults(to: "[]")
            t.column("updated_at", .datetime).notNull()
            t.column("tombstoned_at", .datetime)
        }
        try db.create(
            index: "idx_chains_area", on: "chains", columns: ["area_id"]
        )
    }

    private static func createSessionsTable(_ db: Database) throws {
        try db.create(table: "sessions") { t in
            t.primaryKey("id", .text)
            t.column("skill_id", .text)
                .notNull()
                .references("skills", onDelete: .restrict)
            t.column("date", .datetime).notNull()
            t.column("text", .text).notNull()
            t.column("tombstoned_at", .datetime)
        }
        try db.create(
            index: "idx_sessions_skill_date", on: "sessions",
            columns: ["skill_id", "date"]
        )
    }

    private static func createNotesTable(_ db: Database) throws {
        try db.create(table: "notes") { t in
            t.primaryKey("id", .text)
            t.column("skill_id", .text)
                .notNull()
                .references("skills", onDelete: .restrict)
            t.column("text", .text).notNull()
            t.column("added_at", .datetime).notNull()
            t.column("tombstoned_at", .datetime)
        }
        try db.create(
            index: "idx_notes_skill_added", on: "notes",
            columns: ["skill_id", "added_at"]
        )
    }

    private static func createClipsTable(_ db: Database) throws {
        try db.create(table: "clips") { t in
            t.primaryKey("id", .text)
            t.column("skill_id", .text)
                .notNull()
                .references("skills", onDelete: .restrict)
            t.column("source", .text).notNull()
            t.column("title", .text).notNull()
            t.column("url", .text)
            t.column("duration", .text)
            t.column("note", .text)
            t.column("added_at", .datetime).notNull()
            t.column("tombstoned_at", .datetime)
        }
        try db.create(
            index: "idx_clips_skill_added", on: "clips",
            columns: ["skill_id", "added_at"]
        )
    }

    private static func createAttachmentsTable(_ db: Database) throws {
        try db.create(table: "attachments") { t in
            t.primaryKey("id", .text)
            t.column("skill_id", .text)
                .notNull()
                .references("skills", onDelete: .restrict)
            t.column("content_hash", .text).notNull()
            t.column("media_type", .text).notNull()
            t.column("mime_type", .text).notNull()
            t.column("byte_size", .integer).notNull()
            t.column("width", .integer).notNull()
            t.column("height", .integer).notNull()
            t.column("duration_ms", .integer)
            t.column("captured_at", .datetime)
            t.column("caption", .text)
            t.column("added_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("tombstoned_at", .datetime)
        }
        try db.create(
            index: "idx_attachments_skill_added", on: "attachments",
            columns: ["skill_id", "added_at"]
        )
        try db.create(
            index: "idx_attachments_content_hash", on: "attachments",
            columns: ["content_hash"]
        )
    }

    // The wide-events log: immutable append-only audit trail of every
    // mutation that went through the store. The same data feeds the
    // "journal / history derived from CRDT" feature — render a day by
    // scrolling the events for that day; reconstruct a state at time T
    // by replaying everything up to T.
    private static func createWideEventsTable(_ db: Database) throws {
        try db.create(table: "wide_events") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("ts", .datetime).notNull()
            t.column("op", .text).notNull()
            t.column("outcome", .text).notNull()
            t.column("correlation_id", .text)
            t.column("duration_ms", .double)
            t.column("area_id", .text)
            t.column("skill_id", .text)
            t.column("fields_json", .text)
        }
        try db.create(
            index: "idx_wide_events_ts", on: "wide_events", columns: ["ts"]
        )
        try db.create(
            index: "idx_wide_events_skill_ts", on: "wide_events",
            columns: ["skill_id", "ts"]
        )
        try db.create(
            index: "idx_wide_events_op_ts", on: "wide_events",
            columns: ["op", "ts"]
        )
    }
}

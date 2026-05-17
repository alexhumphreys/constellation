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

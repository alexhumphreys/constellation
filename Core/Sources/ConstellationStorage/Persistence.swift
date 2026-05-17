import ConstellationLogging
import ConstellationModels
import Foundation
import GRDB

// Row mirrors for the SQLite schema. These keep the model types free of
// GRDB-specific conformances (so ConstellationModels stays a pure data
// package) and absorb the JSON-array conversion for prereq/skill lists,
// which would otherwise leak into the public API via custom Codable.

struct AreaRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "areas"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy =
        .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy =
        .convertToSnakeCase

    var id: String
    var name: String
    var tint: String
    var centerX: Double
    var centerY: Double
    var radius: Double
    var updatedAt: Date
    var tombstonedAt: Date?

    init(_ area: Area) {
        self.id = area.id.rawValue
        self.name = area.name
        self.tint = area.tint
        self.centerX = area.centerX
        self.centerY = area.centerY
        self.radius = area.radius
        self.updatedAt = area.updatedAt
        self.tombstonedAt = area.tombstonedAt
    }

    func toModel() -> Area {
        Area(
            id: AreaID(id),
            name: name,
            tint: tint,
            centerX: centerX,
            centerY: centerY,
            radius: radius,
            updatedAt: updatedAt,
            tombstonedAt: tombstonedAt
        )
    }
}

struct SkillRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "skills"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy =
        .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy =
        .convertToSnakeCase

    var id: String
    var areaId: String
    var name: String
    var status: String
    var x: Double
    var y: Double
    var prereqIds: String       // JSON-encoded [String]
    var softPrereqIds: String   // JSON-encoded [String]
    var helpsAreas: String      // JSON-encoded [String]
    var isFoundation: Bool
    var updatedAt: Date
    var tombstonedAt: Date?

    init(_ skill: Skill) {
        self.id = skill.id.rawValue
        self.areaId = skill.areaId.rawValue
        self.name = skill.name
        self.status = skill.status.rawValue
        self.x = skill.x
        self.y = skill.y
        self.prereqIds = encodeIds(skill.prereqIds.map(\.rawValue))
        self.softPrereqIds = encodeIds(skill.softPrereqIds.map(\.rawValue))
        self.helpsAreas = encodeIds(skill.helpsAreas.map(\.rawValue))
        self.isFoundation = skill.isFoundation
        self.updatedAt = skill.updatedAt
        self.tombstonedAt = skill.tombstonedAt
    }

    func toModel() -> Skill {
        Skill(
            id: SkillID(id),
            areaId: AreaID(areaId),
            name: name,
            status: SkillStatus(rawValue: status) ?? .locked,
            x: x,
            y: y,
            prereqIds: decodeIds(prereqIds).map(SkillID.init),
            softPrereqIds: decodeIds(softPrereqIds).map(SkillID.init),
            isFoundation: isFoundation,
            helpsAreas: decodeIds(helpsAreas).map(AreaID.init),
            updatedAt: updatedAt,
            tombstonedAt: tombstonedAt
        )
    }
}

struct ChainRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chains"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy =
        .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy =
        .convertToSnakeCase

    var id: String
    var areaId: String
    var name: String
    var skillIds: String   // JSON-encoded [String]
    var updatedAt: Date
    var tombstonedAt: Date?

    init(_ chain: Chain) {
        self.id = chain.id.rawValue
        self.areaId = chain.areaId.rawValue
        self.name = chain.name
        self.skillIds = encodeIds(chain.skillIds.map(\.rawValue))
        self.updatedAt = chain.updatedAt
        self.tombstonedAt = chain.tombstonedAt
    }

    func toModel() -> Chain {
        Chain(
            id: ChainID(id),
            areaId: AreaID(areaId),
            name: name,
            skillIds: decodeIds(skillIds).map(SkillID.init),
            updatedAt: updatedAt,
            tombstonedAt: tombstonedAt
        )
    }
}

struct SessionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy =
        .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy =
        .convertToSnakeCase

    var id: String
    var skillId: String
    var date: Date
    var text: String
    var tombstonedAt: Date?

    init(_ session: Session) {
        self.id = session.id.rawValue
        self.skillId = session.skillId.rawValue
        self.date = session.date
        self.text = session.text
        self.tombstonedAt = session.tombstonedAt
    }

    func toModel() -> Session {
        Session(
            id: SessionID(id),
            skillId: SkillID(skillId),
            date: date,
            text: text,
            tombstonedAt: tombstonedAt
        )
    }
}

struct NoteRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy =
        .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy =
        .convertToSnakeCase

    var id: String
    var skillId: String
    var text: String
    var addedAt: Date
    var tombstonedAt: Date?

    init(_ note: Note) {
        self.id = note.id.rawValue
        self.skillId = note.skillId.rawValue
        self.text = note.text
        self.addedAt = note.addedAt
        self.tombstonedAt = note.tombstonedAt
    }

    func toModel() -> Note {
        Note(
            id: NoteID(id),
            skillId: SkillID(skillId),
            text: text,
            addedAt: addedAt,
            tombstonedAt: tombstonedAt
        )
    }
}

struct ClipRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clips"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy =
        .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy =
        .convertToSnakeCase

    var id: String
    var skillId: String
    var platform: String
    var handle: String?
    var title: String
    var url: String?
    var duration: String?
    var note: String?
    var addedAt: Date
    var updatedAt: Date
    var tombstonedAt: Date?

    init(_ clip: Clip) {
        self.id = clip.id.rawValue
        self.skillId = clip.skillId.rawValue
        self.platform = clip.platform
        self.handle = clip.handle
        self.title = clip.title
        self.url = clip.url?.absoluteString
        self.duration = clip.duration
        self.note = clip.note
        self.addedAt = clip.addedAt
        self.updatedAt = clip.updatedAt
        self.tombstonedAt = clip.tombstonedAt
    }

    func toModel() -> Clip {
        Clip(
            id: ClipID(id),
            skillId: SkillID(skillId),
            platform: platform,
            handle: handle,
            title: title,
            url: url.flatMap(URL.init(string:)),
            duration: duration,
            note: note,
            addedAt: addedAt,
            updatedAt: updatedAt,
            tombstonedAt: tombstonedAt
        )
    }
}

struct WideEventRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "wide_events"
    static let databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy =
        .convertFromSnakeCase
    static let databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy =
        .convertToSnakeCase

    var id: Int64?
    var ts: Date
    var op: String
    var outcome: String
    var correlationId: String?
    var durationMs: Double?
    var areaId: String?
    var skillId: String?
    var fieldsJson: String?

    static func from(_ event: WideEvent) -> WideEventRow {
        // Lift the well-known dimensional fields out into typed columns
        // for fast querying; everything else gets stuffed in fields_json.
        // Mirrors the pattern used by the rss-reader reference (and by
        // ClickHouse wide_events tables — same query shape works here).
        var overflow = event.fields
        let areaId = overflow.removeValue(forKey: "area_id")?.stringValue
        let skillId = overflow.removeValue(forKey: "skill_id")?.stringValue
        return WideEventRow(
            id: nil,
            ts: event.timestamp,
            op: event.op,
            outcome: event.outcome.rawValue,
            correlationId: event.correlationId,
            durationMs: event.durationMs,
            areaId: areaId,
            skillId: skillId,
            fieldsJson: encodeFields(overflow)
        )
    }
}

// MARK: - JSON helpers (intentionally local — these are only used by the
// row layer; no point exposing them in a public utility module.)

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()
private let jsonDecoder = JSONDecoder()

func encodeIds(_ ids: [String]) -> String {
    // Force-try: encoding an [String] cannot fail.
    let data = try! jsonEncoder.encode(ids)
    return String(decoding: data, as: UTF8.self)
}

func decodeIds(_ json: String) -> [String] {
    guard let data = json.data(using: .utf8) else { return [] }
    return (try? jsonDecoder.decode([String].self, from: data)) ?? []
}

func encodeFields(_ fields: [String: WideValue]) -> String? {
    guard !fields.isEmpty else { return nil }
    let data = try? jsonEncoder.encode(fields)
    return data.map { String(decoding: $0, as: UTF8.self) }
}

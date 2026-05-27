import ConstellationLogging
import ConstellationModels
import ConstellationStorage
import Foundation
import Testing

@Suite("Store + CRDT semantics")
struct StoreTests {

    @Test("Upsert + read round-trips a skill with all fields")
    func skillRoundtrip() async throws {
        let store = try Store(inMemory: true)
        let area = Area(id: AreaID("silks"), name: "Silks")
        try await store.upsertArea(area)
        let skill = Skill(
            id: SkillID("hip-key"), areaId: AreaID("silks"),
            name: "Hip Key", status: .drill,
            x: 740, y: 680,
            prereqIds: [SkillID("invert")],
            softPrereqIds: [SkillID("climb")],
            isFoundation: false,
            aliases: ["Egyptian", "Hipkey"]
        )
        try await store.upsertSkill(skill)

        let fetched = try await store.skill(SkillID("hip-key"))
        #expect(fetched?.name == "Hip Key")
        #expect(fetched?.status == .drill)
        #expect(fetched?.prereqIds == [SkillID("invert")])
        #expect(fetched?.softPrereqIds == [SkillID("climb")])
        #expect(fetched?.aliases == ["Egyptian", "Hipkey"])
    }

    @Test("setStatus updates the row and bumps updatedAt")
    func setStatusUpdates() async throws {
        let store = try Store(inMemory: true)
        try await store.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        let original = Skill(id: SkillID("invert"), areaId: AreaID("silks"),
                             name: "Invert", status: .got)
        try await store.upsertSkill(original)
        try await Task.sleep(for: .milliseconds(5))
        try await store.setStatus(.master, for: SkillID("invert"))
        let after = try await store.skill(SkillID("invert"))
        #expect(after?.status == .master)
        #expect((after?.updatedAt ?? .distantPast) > original.updatedAt)
    }

    @Test("LWW: incoming with later updatedAt wins")
    func lwwIncomingWins() async throws {
        let store = try Store(inMemory: true)
        try await store.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        let earlier = Skill(
            id: SkillID("x"), areaId: AreaID("silks"),
            name: "Old name", status: .next,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try await store.upsertSkill(earlier)
        let later = Skill(
            id: SkillID("x"), areaId: AreaID("silks"),
            name: "New name", status: .drill,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try await store.upsertSkill(later)
        let result = try await store.skill(SkillID("x"))
        #expect(result?.name == "New name")
        #expect(result?.status == .drill)
    }

    @Test("LWW: stale incoming loses to fresher local")
    func lwwLocalWins() async throws {
        let store = try Store(inMemory: true)
        try await store.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        let fresh = Skill(
            id: SkillID("x"), areaId: AreaID("silks"),
            name: "Fresh", status: .master,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try await store.upsertSkill(fresh)
        let stale = Skill(
            id: SkillID("x"), areaId: AreaID("silks"),
            name: "Stale", status: .locked,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try await store.upsertSkill(stale)
        let result = try await store.skill(SkillID("x"))
        #expect(result?.name == "Fresh")
        #expect(result?.status == .master)
    }

    @Test("Sessions append cleanly with distinct ids")
    func sessionsAppend() async throws {
        let store = try await seededStore()
        let id = SkillID("crochet")
        try await store.upsertSession(Session(skillId: id, text: "rep 1"))
        try await store.upsertSession(Session(skillId: id, text: "rep 2"))
        try await store.upsertSession(Session(skillId: id, text: "rep 3"))
        let sessions = try await store.sessions(for: id)
        #expect(sessions.count == 3)
        #expect(Set(sessions.map(\.text)) == ["rep 1", "rep 2", "rep 3"])
    }

    @Test("upsertNote edits in place and preserves addedAt")
    func noteEditInPlace() async throws {
        let store = try await seededStore()
        let id = NoteID.generate()
        let added = Date(timeIntervalSince1970: 1_000)
        try await store.upsertNote(Note(
            id: id, skillId: SkillID("crochet"), text: "watch elbow",
            addedAt: added, updatedAt: added
        ))
        try await store.upsertNote(Note(
            id: id, skillId: SkillID("crochet"),
            text: "watch elbow on entry",
            addedAt: added, updatedAt: Date(timeIntervalSince1970: 2_000)
        ))
        let notes = try await store.notes(for: SkillID("crochet"))
        #expect(notes.count == 1)
        #expect(notes.first?.text == "watch elbow on entry")
        #expect(notes.first?.addedAt == added)
    }

    @Test("tombstoneNote hides the note from default query")
    func tombstoneNoteHides() async throws {
        let store = try await seededStore()
        let id = NoteID.generate()
        try await store.upsertNote(
            Note(id: id, skillId: SkillID("crochet"), text: "scary on left")
        )
        try await store.tombstoneNote(id)
        let notes = try await store.notes(for: SkillID("crochet"))
        #expect(notes.isEmpty)
    }

    @Test("Snapshot + merge round-trips identically")
    func snapshotRoundtrip() async throws {
        let storeA = try await seededStore()
        let snapshot = try await storeA.snapshot()
        let storeB = try Store(inMemory: true)
        try await storeB.merge(snapshot)
        let snapshot2 = try await storeB.snapshot()
        #expect(snapshot.areas.count == snapshot2.areas.count)
        #expect(snapshot.skills.count == snapshot2.skills.count)
        #expect(snapshot.chains.count == snapshot2.chains.count)
    }

    @Test("Merge of disjoint sessions takes the union")
    func mergeUnionAppendOnly() async throws {
        let storeA = try Store(inMemory: true)
        try await storeA.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        try await storeA.upsertSkill(
            Skill(id: SkillID("invert"), areaId: AreaID("silks"), name: "Invert")
        )
        try await storeA.upsertSession(Session(skillId: SkillID("invert"), text: "A"))
        try await storeA.upsertSession(Session(skillId: SkillID("invert"), text: "B"))

        let storeB = try Store(inMemory: true)
        try await storeB.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        try await storeB.upsertSkill(
            Skill(id: SkillID("invert"), areaId: AreaID("silks"), name: "Invert")
        )
        try await storeB.upsertSession(Session(skillId: SkillID("invert"), text: "C"))

        let snapA = try await storeA.snapshot()
        try await storeB.merge(snapA)
        let merged = try await storeB.sessions(for: SkillID("invert"))
        #expect(Set(merged.map(\.text)) == ["A", "B", "C"])
    }

    @Test("Tombstone hides the entity from default queries")
    func tombstoneHides() async throws {
        let store = try Store(inMemory: true)
        try await store.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        try await store.upsertSkill(
            Skill(id: SkillID("invert"), areaId: AreaID("silks"), name: "Invert")
        )
        try await store.tombstoneSkill(SkillID("invert"))
        let live = try await store.skills()
        #expect(live.isEmpty)
        // Tombstoned rows still exist for sync purposes — they're
        // returned when callers pass includeTombstoned: true.
        let all = try await store.skills(includeTombstoned: true)
        #expect(all.count == 1)
        #expect(all[0].isDeleted)
    }

    @Test("Wide events log every mutation")
    func wideEventsLogged() async throws {
        let store = try Store(inMemory: true)
        try await store.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        try await store.upsertSkill(
            Skill(id: SkillID("invert"), areaId: AreaID("silks"), name: "Invert")
        )
        try await store.setStatus(.master, for: SkillID("invert"))
        let events = try await store.events(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSinceNow: 60)
        )
        let ops = events.map(\.op)
        #expect(ops.contains("area.upsert"))
        // Both the initial upsert and the setStatus produce skill.upsert.
        #expect(ops.filter { $0 == "skill.upsert" }.count == 2)
    }

    // Helper — populate a fresh in-memory store with a small fixture
    // so individual tests don't repeat the same setup boilerplate.
    private func seededStore() async throws -> Store {
        let store = try Store(inMemory: true)
        try await store.upsertArea(Area(
            id: AreaID("silks"), name: "Aerial Silks", tint: "#e88a7a"
        ))
        try await store.upsertSkill(Skill(
            id: SkillID("crochet"), areaId: AreaID("silks"),
            name: "Crochet", status: .drill
        ))
        try await store.upsertChain(Chain(
            id: ChainID("flow-1"), areaId: AreaID("silks"),
            name: "Crochet flow", skillIds: [SkillID("crochet")]
        ))
        return store
    }
}

@Suite("CRDT pure-function semantics")
struct CRDTPureTests {

    @Test("Snapshot merge is commutative")
    func commutative() {
        let date1 = Date(timeIntervalSince1970: 1_000)
        let date2 = Date(timeIntervalSince1970: 2_000)
        let a = ConstellationSnapshot(
            skills: [Skill(id: SkillID("x"), areaId: AreaID("a"),
                           name: "Old", updatedAt: date1)]
        )
        let b = ConstellationSnapshot(
            skills: [Skill(id: SkillID("x"), areaId: AreaID("a"),
                           name: "New", updatedAt: date2)]
        )
        let ab = ConstellationSnapshot.merge(a, b)
        let ba = ConstellationSnapshot.merge(b, a)
        #expect(ab.skills.first?.name == "New")
        #expect(ba.skills.first?.name == "New")
    }

    @Test("Snapshot merge is idempotent")
    func idempotent() {
        let a = ConstellationSnapshot(
            areas: [Area(id: AreaID("silks"), name: "Silks")]
        )
        let once = ConstellationSnapshot.merge(a, a)
        #expect(once.areas.count == 1)
        let twice = ConstellationSnapshot.merge(once, a)
        #expect(twice.areas.count == 1)
    }

    @Test("Tombstone wins over live in append-only merge")
    func tombstoneWins() {
        let live = Session(id: SessionID("s1"), skillId: SkillID("x"), text: "live")
        let dead = Session(id: SessionID("s1"), skillId: SkillID("x"),
                           text: "dead",
                           tombstonedAt: Date(timeIntervalSince1970: 100))
        let merged = CRDT.mergeAppendOnly(live, dead)
        #expect(merged.isDeleted)
    }

    @Test("Note edit wins by later updatedAt")
    func noteLWW() {
        let id = NoteID("n1")
        let original = Note(
            id: id, skillId: SkillID("x"), text: "first draft",
            addedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let edited = Note(
            id: id, skillId: SkillID("x"), text: "polished",
            addedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        #expect(CRDT.mergeMutableAppendOnly(original, edited).text == "polished")
        #expect(CRDT.mergeMutableAppendOnly(edited, original).text == "polished")
    }

    @Test("Note tombstone wins over later edit")
    func noteTombstoneWins() {
        let id = NoteID("n1")
        let live = Note(
            id: id, skillId: SkillID("x"), text: "alive",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let dead = Note(
            id: id, skillId: SkillID("x"), text: "dead",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            tombstonedAt: Date(timeIntervalSince1970: 1_500)
        )
        // LWW picks `live`'s text, but earliest-tombstone still applies.
        #expect(CRDT.mergeMutableAppendOnly(live, dead).isDeleted)
        #expect(CRDT.mergeMutableAppendOnly(dead, live).isDeleted)
    }
}

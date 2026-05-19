import ConstellationModels
import ConstellationStorage
import Foundation
import Testing

@Suite("Attachment store + CRDT")
struct AttachmentStoreTests {

    @Test("Round-trips through the store with all fields")
    func roundtrip() async throws {
        let store = try await seededStore()
        let a = Attachment(
            id: AttachmentID("att-1"),
            skillId: SkillID("invert"),
            contentHash: "deadbeef",
            mediaType: .photo,
            mimeType: "image/jpeg",
            byteSize: 2_048,
            width: 1024,
            height: 768,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            caption: "left-side cleanup"
        )
        try await store.upsertAttachment(a)

        let fetched = try await store.attachment(AttachmentID("att-1"))
        #expect(fetched?.contentHash == "deadbeef")
        #expect(fetched?.mediaType == .photo)
        #expect(fetched?.byteSize == 2_048)
        #expect(fetched?.caption == "left-side cleanup")
    }

    @Test("Listing returns only live attachments, newest first")
    func listLive() async throws {
        let store = try await seededStore()
        let older = Attachment(
            skillId: SkillID("invert"),
            contentHash: "aaaa", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1,
            addedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = Attachment(
            skillId: SkillID("invert"),
            contentHash: "bbbb", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1,
            addedAt: Date(timeIntervalSince1970: 2_000)
        )
        try await store.upsertAttachment(older)
        try await store.upsertAttachment(newer)
        try await store.tombstoneAttachment(older.id)

        let live = try await store.attachments(for: SkillID("invert"))
        #expect(live.count == 1)
        #expect(live.first?.contentHash == "bbbb")
    }

    @Test("LWW on caption: incoming with later updatedAt wins")
    func lwwCaption() async throws {
        let store = try await seededStore()
        let id = AttachmentID("att-2")
        let first = Attachment(
            id: id, skillId: SkillID("invert"),
            contentHash: "cafe", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1,
            caption: "first",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = Attachment(
            id: id, skillId: SkillID("invert"),
            contentHash: "cafe", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1,
            caption: "second",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try await store.upsertAttachment(first)
        try await store.upsertAttachment(second)
        let merged = try await store.attachment(id)
        #expect(merged?.caption == "second")
    }

    @Test("Stale incoming caption loses to fresher local")
    func lwwStaleLoses() async throws {
        let store = try await seededStore()
        let id = AttachmentID("att-3")
        let fresh = Attachment(
            id: id, skillId: SkillID("invert"),
            contentHash: "feed", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1,
            caption: "fresh",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let stale = Attachment(
            id: id, skillId: SkillID("invert"),
            contentHash: "feed", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1,
            caption: "stale",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try await store.upsertAttachment(fresh)
        try await store.upsertAttachment(stale)
        #expect(try await store.attachment(id)?.caption == "fresh")
    }

    @Test("liveContentHashes excludes tombstoned rows")
    func liveHashes() async throws {
        let store = try await seededStore()
        let live = Attachment(
            skillId: SkillID("invert"),
            contentHash: "live-hash", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1
        )
        let dead = Attachment(
            skillId: SkillID("invert"),
            contentHash: "dead-hash", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1
        )
        try await store.upsertAttachment(live)
        try await store.upsertAttachment(dead)
        try await store.tombstoneAttachment(dead.id)

        let hashes = try await store.liveContentHashes()
        #expect(hashes == ["live-hash"])
    }

    @Test("Snapshot round-trip carries attachments")
    func snapshotRoundtrip() async throws {
        let storeA = try await seededStore()
        let original = Attachment(
            id: AttachmentID("snap-att"),
            skillId: SkillID("invert"),
            contentHash: "snap-hash", mediaType: .video, mimeType: "video/quicktime",
            byteSize: 1_000_000, width: 1920, height: 1080,
            durationMs: 4_500
        )
        try await storeA.upsertAttachment(original)
        let snap = try await storeA.snapshot()
        #expect(snap.attachments.count == 1)

        let storeB = try await seededStore()
        try await storeB.merge(snap)
        let fetched = try await storeB.attachment(AttachmentID("snap-att"))
        #expect(fetched?.contentHash == "snap-hash")
        #expect(fetched?.mediaType == .video)
        #expect(fetched?.durationMs == 4_500)
    }

    private func seededStore() async throws -> Store {
        let store = try Store(inMemory: true)
        try await store.upsertArea(Area(id: AreaID("silks"), name: "Silks"))
        try await store.upsertSkill(
            Skill(id: SkillID("invert"), areaId: AreaID("silks"), name: "Invert")
        )
        return store
    }
}

@Suite("Attachment CRDT pure-function semantics")
struct AttachmentCRDTTests {

    @Test("Merge picks later updatedAt")
    func lwwLater() {
        let id = AttachmentID("p")
        let a = make(id: id, caption: "a", updated: 1_000)
        let b = make(id: id, caption: "b", updated: 2_000)
        #expect(CRDT.mergeMutableAppendOnly(a, b).caption == "b")
        #expect(CRDT.mergeMutableAppendOnly(b, a).caption == "b")
    }

    @Test("Tombstone wins over live")
    func tombstoneWins() {
        let id = AttachmentID("p")
        let live = make(id: id, caption: "live", updated: 1_000)
        let dead = make(id: id, caption: "dead", updated: 1_000,
                        tombstone: Date(timeIntervalSince1970: 500))
        #expect(CRDT.mergeMutableAppendOnly(live, dead).isDeleted)
        #expect(CRDT.mergeMutableAppendOnly(dead, live).isDeleted)
    }

    @Test("Snapshot merge is idempotent for attachments")
    func snapshotIdempotent() {
        let snap = ConstellationSnapshot(
            attachments: [make(id: AttachmentID("p"), caption: "x", updated: 1_000)]
        )
        let once = ConstellationSnapshot.merge(snap, snap)
        let twice = ConstellationSnapshot.merge(once, snap)
        #expect(once.attachments.count == 1)
        #expect(twice.attachments.count == 1)
    }

    private func make(
        id: AttachmentID,
        caption: String?,
        updated: TimeInterval,
        addedAt: Date = Date(timeIntervalSince1970: 0),
        tombstone: Date? = nil
    ) -> ConstellationModels.Attachment {
        Attachment(
            id: id, skillId: SkillID("x"),
            contentHash: "h", mediaType: .photo, mimeType: "image/jpeg",
            byteSize: 1, width: 1, height: 1,
            caption: caption,
            addedAt: addedAt,
            updatedAt: Date(timeIntervalSince1970: updated),
            tombstonedAt: tombstone
        )
    }
}

@Suite("AssetStore content-addressed file storage")
struct AssetStoreTests {

    @Test("Writes bytes under sha256 hash and reads back")
    func writeRead() async throws {
        let store = try makeStore()
        let payload = Data("hello world".utf8)
        let hash = try await store.write(payload, fileExtension: "txt")
        #expect(hash == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")

        let back = try await store.data(for: hash)
        #expect(back == payload)
    }

    @Test("Re-writing identical bytes is idempotent")
    func idempotentWrite() async throws {
        let store = try makeStore()
        let payload = Data("same".utf8)
        let h1 = try await store.write(payload, fileExtension: "bin")
        let h2 = try await store.write(payload, fileExtension: "bin")
        #expect(h1 == h2)
        let hashes = try await store.onDiskHashes()
        #expect(hashes == [h1])
    }

    @Test("GC removes hashes not referenced by the live set")
    func gc() async throws {
        let store = try makeStore()
        let keep = try await store.write(Data("keep".utf8), fileExtension: "bin")
        let drop = try await store.write(Data("drop".utf8), fileExtension: "bin")

        let removed = try await store.collectGarbage(referenced: [keep])
        #expect(removed == 1)
        #expect(try await store.exists(contentHash: keep))
        #expect(try await store.exists(contentHash: drop) == false)
    }

    private func makeStore() throws -> AssetStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("constellation-assetstore-\(UUID().uuidString)")
        return try AssetStore(root: tmp)
    }
}

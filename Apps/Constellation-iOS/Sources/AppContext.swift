import ConstellationCore
import Foundation
import os

// Single source of truth for the app-side Store. Lives in the
// app's Documents dir (`UIFileSharingEnabled = YES` in Info.plist) so
// the SQLite file is reachable via Files / iTunes / Finder for ad-hoc
// AirDrop sync until a proper sync extension lands.
//
// On first launch the store is empty — we seed it with the design's
// demo data so there's something to look at immediately. Subsequent
// launches are no-ops because SeedData's CRDT merge is idempotent.
@MainActor
final class AppContext {
    let store: Store
    let assets: AssetStore
    let peerSync = PeerSync()
    // App-scoped media import driver. Owns import Tasks so they survive
    // the inspector being closed mid-flight; see ImportCoordinator.
    let importer: ImportCoordinator

    init() throws {
        let url = Self.storeURL()
        Self.logger.info("opening store at \(url.path, privacy: .public)")
        let store = try Store(url: url, sink: OSLogSink())
        self.store = store
        let assetsRoot = url
            .deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
        let assets = try AssetStore(root: assetsRoot)
        self.assets = assets
        self.importer = ImportCoordinator(assets: assets, store: store)
    }

    // Returns the number of skills seeded — 0 when the store already had
    // data (so the launch event can flag a cold first-run seed and record
    // how much work it was).
    @discardableResult
    func seedIfEmpty() async throws -> Int {
        let areas = try await store.allAreas()
        guard areas.isEmpty else { return 0 }
        Self.logger.info("empty store; seeding from SeedData")
        let stats = try await store.merge(SeedData.snapshot())
        return stats.skills
    }

    // Start MultipeerConnectivity sync once the local store has been
    // seeded. Observers watch `peerSync.pullCount` to react to inbound
    // snapshot merges from peers.
    func startPeerSync() {
        peerSync.start(store: store, assets: assets)
    }

    nonisolated static func storeURL() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? URL.documentsDirectory
        return docs.appendingPathComponent("constellation.sqlite")
    }

    private static let logger = Logger(
        subsystem: "com.constellation.ios", category: "context"
    )
}

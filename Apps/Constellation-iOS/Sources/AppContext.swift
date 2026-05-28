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

    func seedIfEmpty() async throws {
        let areas = try await store.allAreas()
        guard areas.isEmpty else { return }
        Self.logger.info("empty store; seeding from SeedData")
        try await store.merge(SeedData.snapshot())
    }

    // Start MultipeerConnectivity sync once the local store has been
    // seeded. Observers watch `peerSync.pullCount` to react to inbound
    // snapshot merges from peers.
    func startPeerSync() {
        peerSync.start(store: store, assets: assets)
    }

    static func storeURL() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? URL.documentsDirectory
        return docs.appendingPathComponent("constellation.sqlite")
    }

    private static let logger = Logger(
        subsystem: "com.constellation.ios", category: "context"
    )
}

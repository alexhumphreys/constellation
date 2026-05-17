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

    init() throws {
        let url = Self.storeURL()
        Self.logger.info("opening store at \(url.path, privacy: .public)")
        self.store = try Store(url: url, sink: OSLogSink())
    }

    func seedIfEmpty() async throws {
        let areas = try await store.allAreas()
        guard areas.isEmpty else { return }
        Self.logger.info("empty store; seeding from SeedData")
        try await store.merge(SeedData.snapshot())
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

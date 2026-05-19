import SwiftUI
import os

@main
struct ConstellationApp: App {
    @State private var context: AppContext?
    @State private var loadError: String?
    @Environment(\.scenePhase) private var scenePhase

    private static let gcLogger = Logger(
        subsystem: "com.constellation.ios", category: "asset-gc"
    )

    var body: some Scene {
        WindowGroup {
            Group {
                if let context {
                    RootView(context: context)
                        .preferredColorScheme(.dark)
                } else if let loadError {
                    LoadFailureView(message: loadError)
                } else {
                    ProgressView("opening sky…")
                        .task { await bootstrap() }
                }
            }
            .background(Theme.Sky.bg1.ignoresSafeArea())
        }
        // Run asset GC each time the app comes to the foreground. The
        // canonical write paths (attachment add, tombstone, snapshot
        // merge) all converge on `liveContentHashes()`; anything on disk
        // not in that set is an orphan. .active is throttled by iOS so
        // this fires once per foreground, which is a fine cadence — GC
        // is housekeeping, not a hot path.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let ctx = context else { return }
            Task { await runAssetGC(ctx) }
        }
    }

    private func runAssetGC(_ ctx: AppContext) async {
        // Skip GC if a blob transfer is in flight — otherwise we could
        // delete bytes that just landed on disk but aren't yet
        // referenced by a merged snapshot row. Next foreground will
        // try again once pending blobs have settled.
        if ctx.peerSync.hasPendingIncomingBlobs {
            Self.gcLogger.info("asset GC skipped: pending blob transfer")
            return
        }
        do {
            let referenced = try await ctx.store.liveContentHashes()
            let removed = try await ctx.assets.collectGarbage(referenced: referenced)
            if removed > 0 {
                Self.gcLogger.info("asset GC removed \(removed) orphans")
            }
        } catch {
            Self.gcLogger.error("asset GC failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func bootstrap() async {
        do {
            let ctx = try AppContext()
            try await ctx.seedIfEmpty()
            context = ctx
            // Start MultipeerConnectivity sync after seed. First touch
            // triggers iOS's local-network permission prompt; until the
            // user grants it, MC silently fails to discover peers and
            // the sync pill stays in `SEARCHING`.
            ctx.startPeerSync()
        } catch {
            loadError = String(describing: error)
        }
    }
}

private struct LoadFailureView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Text("Couldn't open the store.")
                .font(.title3)
            Text(message)
                .font(.footnote)
                .monospaced()
                .multilineTextAlignment(.center)
                .padding()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Sky.bg1)
    }
}

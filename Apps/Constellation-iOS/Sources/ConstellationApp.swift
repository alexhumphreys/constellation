import ConstellationCore
import SwiftUI

@main
struct ConstellationApp: App {
    @State private var context: AppContext?
    @State private var loadError: String?
    @Environment(\.scenePhase) private var scenePhase

    // Captured when SwiftUI instantiates the App (≈ start of main, after
    // dyld). Process-start → here is the pre-main slice (dyld + runtime
    // load), which on a debug-on-device build dominates cold launch; the
    // `app.launch` event reports it as `app_init_ms` so it's separable
    // from our own bootstrap work.
    private let appLaunchAnchor = Date()

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
        let start = Date()
        // Skip GC if a blob transfer is in flight — otherwise we could
        // delete bytes that just landed on disk but aren't yet
        // referenced by a merged snapshot row. Next foreground will
        // try again once pending blobs have settled.
        if ctx.peerSync.hasPendingIncomingBlobs {
            try? await ctx.store.emit(WideEvent(
                op: "asset.gc",
                outcome: .skipped,
                fields: ["reason": .string("pending_transfer")]
            ))
            return
        }
        do {
            let referenced = try await ctx.store.liveContentHashes()
            let removed = try await ctx.assets.collectGarbage(referenced: referenced)
            try? await ctx.store.emit(WideEvent(
                op: "asset.gc",
                outcome: .ok,
                durationMs: Date().timeIntervalSince(start) * 1000,
                fields: [
                    "removed": .int(Int64(removed)),
                    "referenced": .int(Int64(referenced.count)),
                ]
            ))
        } catch {
            try? await ctx.store.emit(WideEvent(
                op: "asset.gc",
                outcome: .error,
                durationMs: Date().timeIntervalSince(start) * 1000,
                fields: ["error": .string(String(describing: error))]
            ))
        }
    }

    private func bootstrap() async {
        // Kernel-recorded process start (nil if the sysctl fails) lets us
        // attribute the pre-main slice of cold launch — dyld + SwiftUI
        // scene setup before our code runs.
        let processStart = LaunchMetrics.processStartDate()
        let bootStart = Date()
        do {
            let ctx = try AppContext()
            let storeOpenMs = Date().timeIntervalSince(bootStart) * 1000
            let seededSkills = try await ctx.seedIfEmpty()
            let readyMs = Date().timeIntervalSince(bootStart) * 1000
            context = ctx
            // MultipeerConnectivity sync isn't needed for first paint, so
            // keep it off the launch path: bringing MC up (session +
            // Bonjour advertise/browse) does a little main-actor work and
            // may trigger the local-network permission prompt. Spawn it in
            // a detached task so the ProgressView→RootView swap and the
            // first canvas render don't wait on it. Unstructured on
            // purpose — it must survive this bootstrap task being cancelled
            // when the ProgressView swaps out. First MC touch triggers
            // iOS's local-network prompt; until granted, discovery silently
            // no-ops and the sync pill stays `SEARCHING`.
            Task { @MainActor in ctx.startPeerSync() }
            await emitLaunchEvent(
                ctx,
                processStart: processStart,
                storeOpenMs: storeOpenMs,
                seedMs: readyMs - storeOpenMs,
                readyMs: readyMs,
                seededSkills: seededSkills
            )
        } catch {
            loadError = String(describing: error)
        }
    }

    // One canonical `app.launch` line per cold start. Timing is split so
    // the two cost centres the perf work cares about — SQLite open +
    // migrations vs. first-run seed — are separable, and it carries the
    // build/device/throttle context that explains variation between
    // launches. Counts are read *after* `readyMs` is captured so the
    // observability read can't inflate the launch timing it reports.
    private func emitLaunchEvent(
        _ ctx: AppContext,
        processStart: Date?,
        storeOpenMs: Double,
        seedMs: Double,
        readyMs: Double,
        seededSkills: Int
    ) async {
        var fields = LaunchMetrics.environmentFields()
        fields["store_open_ms"] = .double(storeOpenMs)
        fields["seed_ms"] = .double(seedMs)
        fields["cold_seed"] = .bool(seededSkills > 0)
        fields["seeded_skills"] = .int(Int64(seededSkills))
        if let processStart {
            fields["since_process_start_ms"] =
                .double(Date().timeIntervalSince(processStart) * 1000)
            // Pre-main slice: process start → App struct init. The
            // remainder (since_process_start − app_init_ms − dur_ms) is
            // SwiftUI scene setup + first ProgressView render + the hop
            // into this `.task`.
            fields["app_init_ms"] =
                .double(appLaunchAnchor.timeIntervalSince(processStart) * 1000)
        }
        if let bytes = LaunchMetrics.storeFileBytes() {
            fields["db_bytes"] = .int(bytes)
        }
        // Graph scale — bigger graphs make every read (including the
        // first canvas reload) slower, so it contextualises warm launches.
        if let areas = try? await ctx.store.allAreas(),
           let skills = try? await ctx.store.skills() {
            fields["area_count"] = .int(Int64(areas.count))
            fields["skill_count"] = .int(Int64(skills.count))
        }
        try? await ctx.store.emit(WideEvent(
            op: "app.launch",
            outcome: .ok,
            durationMs: readyMs,
            fields: fields
        ))
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

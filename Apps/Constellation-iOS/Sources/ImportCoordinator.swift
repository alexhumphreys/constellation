import ConstellationCore
import Observation
import PhotosUI

// App-scoped driver for `AttachmentImporter`. Lives on `AppContext`
// (alongside `PeerSync`) rather than inside the inspector view so an
// import survives the inspector being closed mid-flight: the owning
// Task, the per-skill spinner state, and the completion/error toast all
// outlive whichever view kicked the import off. Closing the inspector
// while a video re-encodes used to drop the spinner and swallow any
// error alert — now the work and its feedback are anchored to the app.
@MainActor
@Observable
final class ImportCoordinator {
    // Transient banner surfaced app-wide once an import batch settles.
    // RootView presents it and clears it after a short delay. `id` lets
    // the presenter restart its auto-dismiss timer when a new toast
    // replaces an in-flight one.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
        // The skill the import targeted — tapping the toast navigates to
        // it (the inspector that started the import may be long closed).
        let skillId: SkillID
    }

    private let assets: AssetStore
    private let store: Store

    // Count of items still importing per skill. Drives the inspector's
    // ADD-spinner; lives here so closing + reopening the skill mid-import
    // still shows it.
    private(set) var inFlight: [SkillID: Int] = [:]
    // Bumps once per item that finishes (success or failure). RootView
    // and the inspector watch this via .onChange to reload — the canvas
    // picks up new cover moons, the inspector grid refreshes as bytes land.
    private(set) var completedCount: Int = 0
    // Latest toast to present; the presenter clears it on dismiss.
    var toast: Toast?

    init(assets: AssetStore, store: Store) {
        self.assets = assets
        self.store = store
    }

    func isImporting(_ skillId: SkillID) -> Bool {
        (inFlight[skillId] ?? 0) > 0
    }

    // Fire-and-forget. The Task is owned here, not by any view, so it runs
    // to completion regardless of inspector lifecycle. Items import
    // sequentially so we don't saturate the device with concurrent video
    // transcodes (matches the prior in-view behaviour).
    func importPicked(_ results: [PHPickerResult], for skillId: SkillID) {
        guard !results.isEmpty else { return }
        inFlight[skillId, default: 0] += results.count
        Task {
            let importer = AttachmentImporter(assets: assets, store: store)
            var imported = 0
            var failures = 0
            var firstError: String?
            for result in results {
                do {
                    _ = try await importer.importPicked(result, for: skillId)
                    imported += 1
                } catch {
                    failures += 1
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                    // Continue with the rest — one bad item shouldn't
                    // abort the batch; partial success still attaches the
                    // good items.
                }
                let remaining = (inFlight[skillId] ?? 1) - 1
                if remaining <= 0 {
                    inFlight[skillId] = nil
                } else {
                    inFlight[skillId] = remaining
                }
                // Bump per item so the grid + canvas reveal attachments
                // incrementally as each one lands rather than waiting for
                // the slowest in the batch.
                completedCount &+= 1
            }
            present(
                imported: imported, failures: failures,
                detail: firstError, skillId: skillId
            )
        }
    }

    private func present(
        imported: Int, failures: Int, detail: String?, skillId: SkillID
    ) {
        if failures > 0 {
            let message: String
            if imported > 0 {
                message = "Added \(imported) · \(failures) failed"
            } else if failures == 1, let detail {
                message = detail
            } else {
                message = "Couldn't import \(failures) items"
            }
            toast = Toast(message: message, isError: true, skillId: skillId)
        } else if imported > 0 {
            toast = Toast(
                message: imported == 1
                    ? "Attachment added"
                    : "\(imported) attachments added",
                isError: false,
                skillId: skillId
            )
        }
    }
}

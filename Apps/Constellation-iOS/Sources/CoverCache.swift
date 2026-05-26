import ConstellationCore
import SwiftUI
import UIKit

// In-memory cache of attachment cover thumbnails, keyed by content hash.
// Powers the canvas's "show the photo for this skill when zoomed in"
// rendering — SkyView needs a synchronous lookup at 60fps during
// pan/pinch, so we can't go through .task / async on each draw.
//
// Load flow: parent calls prefetch(...) with the set of hashes it needs
// (one per skill that has a cover). Anything not already cached gets
// loaded off-main via UIImage(contentsOfFile:), then committed back on
// MainActor. SkyView reads via image(for:) inside the Canvas closure.
//
// Observable so a freshly-loaded thumbnail triggers a body re-eval and
// the Canvas redraws to pick it up — no need for the parent to bump a
// reload token whenever an asset arrives.
@Observable
@MainActor
final class CoverCache {
    private(set) var images: [String: UIImage] = [:]

    func image(for hash: String) -> UIImage? {
        images[hash]
    }

    func prefetch(hashes: Set<String>, from assets: AssetStore) async {
        let missing = hashes.subtracting(images.keys)
        guard !missing.isEmpty else { return }
        let thumbsRoot = await assets.thumbsRoot
        for hash in missing {
            let path = thumbsRoot
                .appendingPathComponent("\(hash).jpg")
                .path
            let loaded = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: path)
            }.value
            if let loaded {
                images[hash] = loaded
            }
        }
    }

    // Evict hashes no longer referenced by any skill — keeps the cache
    // from growing unbounded as the user adds/removes attachments over
    // months. Called from the parent's reload pass.
    func evict(except keep: Set<String>) {
        images = images.filter { keep.contains($0.key) }
    }
}

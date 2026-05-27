import ConstellationCore
import SwiftUI
import UIKit

// Minimal per-petal payload SkyView needs to render an attachment moon —
// id (sheet keying / future tap-to-open), contentHash (CoverCache /
// StripCache lookup), and mediaType (drives whether to look in
// StripCache for cycling frames). Total attachment counts ride alongside
// in a separate dict so this struct stays a pure per-attachment value.
struct AttachmentCover: Hashable {
    let id: AttachmentID
    let contentHash: String
    let mediaType: MediaType
}

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

// Parallel cache for video strip frames, keyed by the same content hash
// as CoverCache. Each entry is the full N-frame array (N =
// AttachmentImporter.stripFrameCount) loaded from
// `thumbs/<hash>-strip/<i>.jpg`. Powers the canvas video-petal cycling
// at high zoom (scale >= 3.0) — at that point SkyView's strip-cycle
// overlay draws the current frame on top of the static cover, so the
// video moon appears to animate.
//
// Kept separate from CoverCache because (1) photos never have a strip
// and shouldn't sit in the same dict, (2) the value type ([UIImage] vs
// UIImage) differs, and (3) eviction policy is independent — a video
// can lose its strip (missing frame) without losing its static cover.
@Observable
@MainActor
final class StripCache {
    private(set) var strips: [String: [UIImage]] = [:]

    func frames(for hash: String) -> [UIImage]? {
        strips[hash]
    }

    func prefetch(hashes: Set<String>, from assets: AssetStore) async {
        let missing = hashes.subtracting(strips.keys)
        guard !missing.isEmpty else { return }
        let thumbsRoot = await assets.thumbsRoot
        for hash in missing {
            let stripDir = thumbsRoot
                .appendingPathComponent("\(hash)-strip", isDirectory: true)
            let frameCount = AttachmentImporter.stripFrameCount
            let loaded: [UIImage] = await Task.detached(priority: .utility) { () -> [UIImage] in
                var out: [UIImage] = []
                for i in 0..<frameCount {
                    let p = stripDir.appendingPathComponent("\(i).jpg").path
                    if let frame = UIImage(contentsOfFile: p) {
                        out.append(frame)
                    } else {
                        // Missing frame breaks the cycle invariant —
                        // mirror AttachmentThumbnail's bail-out so the
                        // canvas falls back to the static cover.
                        return []
                    }
                }
                return out
            }.value
            if !loaded.isEmpty {
                strips[hash] = loaded
            }
        }
    }

    func evict(except keep: Set<String>) {
        strips = strips.filter { keep.contains($0.key) }
    }
}

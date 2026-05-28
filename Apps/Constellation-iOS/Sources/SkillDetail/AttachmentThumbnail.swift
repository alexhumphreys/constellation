import ConstellationCore
import SwiftUI

// Tile shown in `SkillDetailView`'s ATTACHMENTS grid. Loads
// `assets/thumbs/<contentHash>.jpg` (locally generated at import time,
// never synced) and renders it square-cropped. Videos get a play-badge
// overlay so the user can tell at a glance which tiles will open AVKit
// vs which will open a still.
//
// Thumbnails are tiny (200pt long edge, ~10–40KB JPEGs) — synchronous
// UIImage(contentsOfFile:) is fine here. We still load inside `.task`
// so the main thread doesn't block on every tile during initial
// rendering of a heavily-attached skill.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    let assets: AssetStore
    // Bumped by the parent after a video-strip backfill completes —
    // included in .task's id so the tile re-reads disk and picks up the
    // newly-generated strip. 0 = no parent token (default for callers
    // that don't backfill).
    var reloadToken: Int = 0

    // Single static thumbnail (photos always, videos as the fallback
    // when the cycling strip hasn't been generated yet).
    @State private var image: UIImage?
    // For videos: the cycling strip — N evenly-spaced frames extracted
    // by AttachmentImporter.writeVideoStrip. Empty until loaded; tile
    // shows the static `image` in the meantime.
    @State private var strip: [UIImage] = []
    @State private var didLoad: Bool = false

    // ~500ms per frame keeps the cycle feeling like a fast preview
    // without being epileptic. 8 frames × 500ms = 4s loop.
    private static let frameInterval: TimeInterval = 0.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
            content
            if attachment.mediaType == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.55), radius: 3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .task(id: "\(attachment.contentHash)-\(reloadToken)") {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !strip.isEmpty {
            // Video with strip: cycle through frames on a periodic
            // timeline. TimelineView ticks once per frameInterval and
            // we index into the strip by elapsed seconds — cheap and
            // self-correcting if a tick is missed.
            TimelineView(.periodic(from: .now, by: Self.frameInterval)) { ctx in
                let elapsed = ctx.date.timeIntervalSinceReferenceDate
                let idx = Int(elapsed / Self.frameInterval) % strip.count
                Image(uiImage: strip[idx])
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if didLoad {
            Image(
                systemName: attachment.mediaType == .video
                    ? "film" : "photo"
            )
            .foregroundStyle(.white.opacity(0.4))
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.5))
        }
    }

    private func load() async {
        let thumbsRoot = await assets.thumbsRoot
        let staticPath = thumbsRoot
            .appendingPathComponent("\(attachment.contentHash).jpg")
            .path
        let loadedImage = UIImage(contentsOfFile: staticPath)

        // For videos, also try to load the cycling strip. Frames are
        // named 0.jpg..(N-1).jpg under thumbs/<hash>-strip/. If the
        // directory is missing or empty we fall back to the static
        // thumbnail.
        var loadedStrip: [UIImage] = []
        if attachment.mediaType == .video {
            let stripDir = thumbsRoot
                .appendingPathComponent("\(attachment.contentHash)-strip", isDirectory: true)
            for i in 0..<AttachmentImporter.stripFrameCount {
                let p = stripDir.appendingPathComponent("\(i).jpg").path
                if let frame = UIImage(contentsOfFile: p) {
                    loadedStrip.append(frame)
                } else {
                    // Missing frame breaks the cycle invariant — bail
                    // and use the static thumb instead.
                    loadedStrip.removeAll()
                    break
                }
            }
        }

        await MainActor.run {
            self.image = loadedImage
            self.strip = loadedStrip
            self.didLoad = true
        }
    }
}

// Attachment carries an `id` of type `AttachmentID` already; conforming
// to Identifiable lets us use `.sheet(item:)` to drive the fullscreen
// viewer keyed on a non-nil attachment. Kept in the iOS module rather
// than Core because Identifiable is a UI-adjacent concept (sheet bindings,
// ForEach) and Core stays UI-agnostic.
extension Attachment: @retroactive Identifiable {}

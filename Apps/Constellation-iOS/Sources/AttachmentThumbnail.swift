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

    @State private var image: UIImage?
    @State private var didLoad: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
            if let image {
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
        .task(id: attachment.contentHash) {
            await load()
        }
    }

    private func load() async {
        let thumbsRoot = await assets.thumbsRoot
        let path = thumbsRoot
            .appendingPathComponent("\(attachment.contentHash).jpg")
            .path
        let loaded = UIImage(contentsOfFile: path)
        await MainActor.run {
            self.image = loaded
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

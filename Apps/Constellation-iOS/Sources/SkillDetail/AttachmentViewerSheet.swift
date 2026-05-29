import ConstellationCore
import ImageIO
import SwiftUI
import UIKit

// Full-screen viewer for one attachment. Photos render via SwiftUI's
// Image (loaded from disk, not the thumbnail), videos via
// VideoPlayerView with a custom transport + frame-step row. Both share
// a chrome of caption (read-only for v1) and a delete affordance.
//
// State stays local to the sheet — when the user deletes, we tombstone
// via the Store, call onDeleted, and the inspector's reload pulls the
// updated list. Same lifecycle as Clip edit.
//
// When viewing a video the user can also tap "save frame" to write
// the current frame as a sibling photo attachment; that runs the still
// through AttachmentImporter.importStill and calls onCreated so the
// inspector grid behind us reloads with the new tile.
struct AttachmentViewerSheet: View {
    let attachment: Attachment
    let store: Store
    let assets: AssetStore
    let onClose: () -> Void
    let onDeleted: () -> Void
    let onCreated: () -> Void

    @State private var loadedURL: URL?
    // Photo only: the decoded-at-screen-resolution bitmap. Downsampled
    // off-main in loadAsset so opening a photo never realizes the full
    // ~6000px import into a 100MB+ bitmap on the main thread.
    @State private var photoImage: UIImage?
    @State private var loadError: String?
    @State private var showDeleteConfirm: Bool = false
    @State private var deleting: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Sky.bg1.ignoresSafeArea()
                content
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(deleting)
                }
            }
            .confirmationDialog(
                "Remove this \(attachment.mediaType.rawValue)?",
                isPresented: $showDeleteConfirm
            ) {
                Button("Remove", role: .destructive) {
                    Task { await deleteAttachment() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .preferredColorScheme(.dark)
            .task(id: attachment.id) { await loadAsset() }
        }
    }

    private var navTitle: String {
        let date = attachment.capturedAt ?? attachment.addedAt
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .imageScale(.large)
                Text("Couldn't load this \(attachment.mediaType.rawValue).")
                    .font(.system(size: 14, design: .serif))
                Text(loadError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        } else if let loadedURL {
            switch attachment.mediaType {
            case .photo:
                photoView
            case .video:
                VideoPlayerView(url: loadedURL) { frame in
                    try await saveFrame(
                        image: frame.image, offset: frame.offset
                    )
                }
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    @ViewBuilder
    private var photoView: some View {
        if let photoImage {
            Image(uiImage: photoImage)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView().tint(.white)
        }
    }

    // Largest screen dimension in physical pixels — the downsample target
    // for the fullscreen photo. This viewer has no zoom gesture, so
    // decoding past screen resolution only wastes memory.
    @MainActor
    private static func screenMaxPixelSize() -> Int {
        let bounds = UIScreen.main.bounds.size
        let longEdge = max(bounds.width, bounds.height)
        return Int(longEdge * UIScreen.main.scale)
    }

    // Disk → downsampled UIImage via ImageIO, decoding straight to the
    // target pixel size instead of realizing the full-res bitmap. Reads
    // from the file URL so the full JPEG never lands in memory either.
    nonisolated private static func downsampledImage(
        atPath path: String, maxPixelSize: Int
    ) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            src, 0, opts as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    private func loadAsset() async {
        do {
            guard let url = try await assets.url(for: attachment.contentHash) else {
                await MainActor.run {
                    loadError = "File missing from local store."
                }
                return
            }
            await MainActor.run { self.loadedURL = url }
            // Videos hand the URL straight to VideoPlayerView. Photos get
            // downsampled to screen resolution off the main thread before
            // we show them, so the decode never spikes memory or hitches.
            guard attachment.mediaType == .photo else { return }
            let maxPx = await MainActor.run { Self.screenMaxPixelSize() }
            let path = url.path
            let image = await Task.detached(priority: .userInitiated) {
                Self.downsampledImage(atPath: path, maxPixelSize: maxPx)
            }.value
            await MainActor.run {
                if let image {
                    self.photoImage = image
                } else {
                    self.loadError = "Couldn't decode the image."
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = String(describing: error)
            }
        }
    }

    // Frame's capturedAt = video.capturedAt + frame offset so the new
    // photo sorts chronologically just after the source video in the
    // attachment grid. Falls back to "now" if the source has no capture
    // date (airdropped, screen-recorded, etc.).
    private func saveFrame(image: CGImage, offset: Double) async throws {
        let base = attachment.capturedAt ?? Date()
        let stillCapturedAt = base.addingTimeInterval(offset)
        let importer = AttachmentImporter(assets: assets, store: store)
        _ = try await importer.importStill(
            cgImage: image,
            for: attachment.skillId,
            capturedAt: stillCapturedAt
        )
        await MainActor.run { onCreated() }
    }

    private func deleteAttachment() async {
        deleting = true
        defer { deleting = false }
        do {
            try await store.tombstoneAttachment(attachment.id)
            await MainActor.run {
                onDeleted()
            }
        } catch {
            await MainActor.run {
                loadError = "Couldn't remove: \(error)"
            }
        }
    }
}

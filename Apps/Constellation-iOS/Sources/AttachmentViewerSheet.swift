import ConstellationCore
import SwiftUI

// Full-screen viewer for one attachment. Photos render via SwiftUI's
// Image (loaded from disk, not the thumbnail), videos via
// VideoPlayerView which wraps AVPlayerViewController and layers a
// frame-step row on top of the stock AVKit transport. Both share a
// chrome of caption (read-only for v1) and a delete affordance.
//
// State stays local to the sheet — when the user deletes, we tombstone
// via the Store, call onDeleted, and the inspector's reload pulls the
// updated list. Same lifecycle as Clip edit.
struct AttachmentViewerSheet: View {
    let attachment: Attachment
    let store: Store
    let assets: AssetStore
    let onClose: () -> Void
    let onDeleted: () -> Void

    @State private var loadedURL: URL?
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
                photoView(url: loadedURL)
            case .video:
                VideoPlayerView(url: loadedURL)
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    private func photoView(url: URL) -> some View {
        // Use UIImage rather than AsyncImage because the file is local and
        // AsyncImage spins up a URLSession unnecessarily. UIImage(contentsOfFile:)
        // is synchronous but cheap for our re-encoded JPEGs (<1MB typical).
        Group {
            if let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("Image data unavailable")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
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
        } catch {
            await MainActor.run {
                self.loadError = String(describing: error)
            }
        }
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

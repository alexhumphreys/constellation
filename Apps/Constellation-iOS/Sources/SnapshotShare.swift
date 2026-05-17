import ConstellationCore
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// AirDrop-friendly snapshot sharing.
//
// Export path: write the store's pretty-printed JSON snapshot to a
// `.constellation` file in the temp directory, hand the URL to
// UIActivityViewController via SwiftUI. AirDrop is one of the
// activities iOS offers automatically once the file has a registered
// content type — the UTI lives in project.yml.
//
// Import path: see RootView's `.onOpenURL` — iOS routes a received
// `.constellation` file to the app, which decodes + merges via the
// existing CRDT path (Store.merge).

extension UTType {
    // Mirrors the exported declaration in project.yml. Used by the
    // ActivityView writer so the system knows the file is "ours" and
    // by AirDrop on the receiving side to find the matching app.
    static let constellationSnapshot = UTType(
        exportedAs: "com.constellation.snapshot",
        conformingTo: .json
    )
}

// Pure-function helper so the call site can `await` the snapshot work
// off the main thread and only flip its share-sheet binding on success.
// Returns the file URL the share sheet should hand to AirDrop. Caller
// is responsible for deleting the file; in practice we leave it in the
// system's temp dir and let iOS reap it.
@MainActor
enum SnapshotExport {
    static func writeForSharing(store: Store) async throws -> URL {
        let snapshot = try await store.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = fmt.string(from: Date())
        // TODO: consider switching the extension to `.constellation.json`
        // since the payload is plain JSON — would let macOS/iOS preview
        // it with the system text viewer without us shipping a Quick
        // Look extension, and signals "this is human-readable" to
        // anyone who AirDrops it around. Touches the UTI registration
        // in the Info.plist alongside the rename.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("constellation-\(stamp).constellation")
        try data.write(to: url, options: .atomic)
        return url
    }
}

// Inverse: read a `.constellation` URL (from .onOpenURL) and merge it.
// Document-browser URLs are security-scoped, so we have to bracket the
// read in start/stopAccessingSecurityScopedResource.
@MainActor
enum SnapshotImport {
    struct Preview: Sendable {
        let areas: Int
        let skills: Int
        let chains: Int
        let sessions: Int
        let notes: Int
        let clips: Int
        let snapshot: ConstellationSnapshot
    }

    static func preview(from url: URL) throws -> Preview {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ConstellationSnapshot.self, from: data)
        return Preview(
            areas: snapshot.areas.count,
            skills: snapshot.skills.count,
            chains: snapshot.chains.count,
            sessions: snapshot.sessions.count,
            notes: snapshot.notes.count,
            clips: snapshot.clips.count,
            snapshot: snapshot
        )
    }
}

// Thin SwiftUI wrapper around UIActivityViewController. ShareLink would
// be more idiomatic, but it builds a Transferable from a value type;
// our snapshot is on-disk after writeForSharing(), so handing the URL
// directly to UIActivityViewController is simpler and AirDrop appears
// in the list automatically once the file's UTI is registered.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

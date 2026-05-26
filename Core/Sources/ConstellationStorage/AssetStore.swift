import CryptoKit
import Foundation

// Content-addressed binary store for `Attachment` bytes. Photos and
// videos live as files in `<root>/<contentHash>.<ext>`; the database
// holds metadata + the hash as a ref into here. Two attachments with
// identical bytes share one file naturally.
//
// `<root>/thumbs/<contentHash>.jpg` holds locally-generated thumbnails;
// thumbnails are NEVER synced — peers regenerate their own on demand.
//
// Pairs with `Store.liveContentHashes()` for GC: anything on disk but
// not referenced by a live attachment is an orphan and can be deleted.
public actor AssetStore {
    public let root: URL
    public let thumbsRoot: URL

    public init(root: URL) throws {
        self.root = root
        self.thumbsRoot = root.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: thumbsRoot, withIntermediateDirectories: true
        )
    }

    // Hash the bytes, write `<root>/<hash>.<ext>` if not already present,
    // return the hash. Idempotent: re-importing identical bytes is a
    // no-op write but still returns the same hash so the caller can
    // upsert the Attachment row uniformly.
    @discardableResult
    public func write(_ data: Data, fileExtension: String) throws -> String {
        let hash = Self.sha256Hex(data)
        let dest = root.appendingPathComponent("\(hash).\(fileExtension)")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try data.write(to: dest, options: .atomic)
        }
        return hash
    }

    // Resolve a hash to its on-disk URL. The extension was decided at
    // write time and we don't track it separately, so the lookup scans
    // the (flat) assets dir for a file whose stem matches the hash. A
    // 50-photo library is ~50 entries; this is fine. If the dir grows
    // past a few thousand we can index `(hash, ext)` pairs in SQLite.
    public func url(for contentHash: String) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return contents.first { url in
            let stem = url.deletingPathExtension().lastPathComponent
            return stem == contentHash
        }
    }

    public func exists(contentHash: String) throws -> Bool {
        try url(for: contentHash) != nil
    }

    public func data(for contentHash: String) throws -> Data? {
        guard let url = try url(for: contentHash) else { return nil }
        return try Data(contentsOf: url)
    }

    // Hashes currently on disk in the assets root (thumbs/ subdir
    // excluded — those are cache, not canonical). Used by GC and by
    // the MC blob-reconciliation phase to decide what to request.
    public func onDiskHashes() throws -> Set<String> {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var out: Set<String> = []
        for url in contents {
            let isFile = (try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) ?? false
            guard isFile else { continue }
            out.insert(url.deletingPathExtension().lastPathComponent)
        }
        return out
    }

    public func delete(contentHash: String) throws {
        if let url = try url(for: contentHash) {
            try FileManager.default.removeItem(at: url)
        }
        // Clean up the matching thumbnail too — keeps thumbs/ from
        // accumulating after the canonical bytes are gone.
        let thumb = thumbsRoot.appendingPathComponent("\(contentHash).jpg")
        try? FileManager.default.removeItem(at: thumb)
        // Video filmstrip (cycling preview frames). Optional — only
        // present for video attachments. Treat as best-effort like the
        // thumb above.
        let strip = thumbsRoot
            .appendingPathComponent("\(contentHash)-strip", isDirectory: true)
        try? FileManager.default.removeItem(at: strip)
    }

    // Delete on-disk hashes not present in `referenced`. Returns the
    // count removed for caller-side logging.
    @discardableResult
    public func collectGarbage(referenced: Set<String>) throws -> Int {
        let orphans = try onDiskHashes().subtracting(referenced)
        for hash in orphans {
            try delete(contentHash: hash)
        }
        return orphans.count
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

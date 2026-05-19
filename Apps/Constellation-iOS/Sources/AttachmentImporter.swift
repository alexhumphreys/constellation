import AVFoundation
import ConstellationCore
import CoreServices
import Foundation
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// Pipeline for getting a PhotoKit picker result into the local `AssetStore`
// + an `Attachment` row. Each public entry point produces a single
// Attachment, ready for `Store.upsertAttachment`.
//
// Re-encode-on-import: photos are JPEG-downsampled to `photoLongEdge`pt
// long edge before hashing/writing, videos are exported via
// AVAssetExportSession at the 1080p preset. The on-disk hash is computed
// AFTER re-encode, so peers receiving these bytes over MC see the same
// hash and the same downsized file. Originals are never persisted —
// PhotoKit keeps the canonical version in the user's library, we own a
// downsized copy.
//
// Thumbnails are generated as ~thumbnailLongEdge-pt JPEGs in
// `assets/thumbs/<hash>.jpg`. Thumbnails are caches — never synced;
// peers regenerate their own on demand.
@MainActor
struct AttachmentImporter {
    let assets: AssetStore
    let store: Store

    // Cap photos at 2048pt long edge — readable on iPad's largest screen
    // without dragging multi-megabyte JPEGs around. 1080p (long edge
    // 1920) for video matches the design memo.
    static let photoLongEdge: CGFloat = 2048
    static let thumbnailLongEdge: CGFloat = 200

    // Top-level entry: take one PHPicker result, hand back an Attachment
    // already persisted to the store. Throws if the item provider's
    // declared type doesn't map to a supported media kind, or if any
    // step of the load/encode pipeline fails.
    func importPicked(
        _ result: PHPickerResult, for skillId: SkillID
    ) async throws -> Attachment {
        let provider = result.itemProvider
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return try await importVideo(provider: provider, skillId: skillId)
        }
        if provider.canLoadObject(ofClass: UIImage.self) {
            return try await importPhoto(provider: provider, skillId: skillId)
        }
        throw ImportError.unsupportedType
    }

    // MARK: - Photo path

    private func importPhoto(
        provider: NSItemProvider, skillId: SkillID
    ) async throws -> Attachment {
        // Load the original bytes, not the UIImage object — we need EXIF
        // to recover capturedAt and we want to drive ImageIO's downsample
        // off the source data so we can write JPEG efficiently regardless
        // of the input format (HEIC, PNG, etc.).
        let original = try await loadDataRepresentation(
            from: provider, typeIdentifier: UTType.image.identifier
        )
        let (jpegData, dimensions, capturedAt) = try downsamplePhoto(
            original.data,
            maxLongEdge: Self.photoLongEdge
        )
        let hash = try await assets.write(jpegData, fileExtension: "jpg")
        try await writeThumbnail(
            from: jpegData, isVideo: false, hash: hash
        )
        let attachment = Attachment(
            skillId: skillId,
            contentHash: hash,
            mediaType: .photo,
            mimeType: "image/jpeg",
            byteSize: Int64(jpegData.count),
            width: dimensions.width,
            height: dimensions.height,
            durationMs: nil,
            capturedAt: capturedAt
        )
        try await store.upsertAttachment(attachment)
        return attachment
    }

    // ImageIO-only downsample: avoids decoding the whole image into a
    // UIImage when we just want a smaller JPEG. Returns the encoded JPEG
    // data, final pixel dimensions, and any EXIF capture date the source
    // exposed.
    private func downsamplePhoto(
        _ data: Data, maxLongEdge: CGFloat
    ) throws -> (Data, (width: Int, height: Int), Date?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImportError.imageDecodeFailed
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge * UIScreen.main.scale),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImportError.imageDecodeFailed
        }
        let out = NSMutableData()
        guard
            let dst = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil
            )
        else {
            throw ImportError.imageEncodeFailed
        }
        // Quality 0.85 — visually lossless for thumbnail strip + viewer
        // use, but stays well under 1MB for typical phone-camera photos.
        let writeOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(dst, cg, writeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw ImportError.imageEncodeFailed
        }
        let capturedAt = exifDate(from: src)
        return (
            out as Data,
            (width: cg.width, height: cg.height),
            capturedAt
        )
    }

    // Read EXIF DateTimeOriginal from the source if present. PhotoKit
    // round-trips this for camera-roll photos; airdropped/screen-grabbed
    // images typically have nothing and we fall back to `addedAt`.
    private func exifDate(from src: CGImageSource) -> Date? {
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let str = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: str)
    }

    // MARK: - Video path

    private func importVideo(
        provider: NSItemProvider, skillId: SkillID
    ) async throws -> Attachment {
        // PHPicker hands us a tmp file URL via loadFileRepresentation —
        // copy it locally first because the tmp URL is only valid inside
        // the closure, then export through AVAssetExportSession to cap
        // the resolution. We DON'T store the original — the user's
        // library still has the canonical full-res copy.
        let stagedURL = try await stageVideo(provider: provider)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let (exportedURL, dimensions, durationMs) = try await exportVideo(
            source: stagedURL, longEdge: 1920
        )
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let data = try Data(contentsOf: exportedURL)
        let hash = try await assets.write(data, fileExtension: "mp4")
        try await writeVideoThumbnail(sourceURL: exportedURL, hash: hash)
        let attachment = Attachment(
            skillId: skillId,
            contentHash: hash,
            mediaType: .video,
            mimeType: "video/mp4",
            byteSize: Int64(data.count),
            width: dimensions.width,
            height: dimensions.height,
            durationMs: durationMs,
            capturedAt: nil
        )
        try await store.upsertAttachment(attachment)
        return attachment
    }

    private func stageVideo(provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // loadFileRepresentation runs the completion on a private
            // queue; the tmp URL is deleted as soon as we return, so we
            // copy synchronously inside the completion before resuming.
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.movie.identifier
            ) { tmpURL, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let tmpURL else {
                    cont.resume(throwing: ImportError.videoLoadFailed)
                    return
                }
                let dest = FileManager.default
                    .temporaryDirectory
                    .appendingPathComponent("staged-\(UUID().uuidString).mov")
                do {
                    try FileManager.default.copyItem(at: tmpURL, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func exportVideo(
        source: URL, longEdge: Int
    ) async throws -> (URL, (width: Int, height: Int), Int) {
        let asset = AVURLAsset(url: source)
        // 1920x1080 preset matches the design memo. If the source is
        // smaller (e.g. 720p), AVAssetExportSession preserves the source
        // resolution rather than upscaling — checked behaviour.
        let preset = AVAssetExportPreset1920x1080
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: preset
            )
        else {
            throw ImportError.videoExportFailed
        }
        let outURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("exp-\(UUID().uuidString).mp4")
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: outURL, as: .mp4)
        let (size, durationMs) = try await videoMetrics(at: outURL)
        return (outURL, size, durationMs)
    }

    private func videoMetrics(
        at url: URL
    ) async throws -> ((width: Int, height: Int), Int) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMs = Int(CMTimeGetSeconds(duration) * 1000)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            return ((0, 0), durationMs)
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // Account for portrait videos — naturalSize is the encoded
        // dimensions, the preferred transform rotates it for display.
        let rendered = naturalSize.applying(transform)
        let w = Int(abs(rendered.width).rounded())
        let h = Int(abs(rendered.height).rounded())
        return ((w, h), durationMs)
    }

    // MARK: - Thumbnails

    // Public entry: regenerate the thumbnail for a hash whose canonical
    // bytes already exist on disk. Used by the MC blob-receive path —
    // peers receive raw bytes from each other but never the thumbnail,
    // so each device generates its own. Idempotent: overwrites the
    // existing thumb file. No-op if the canonical file isn't on disk
    // (caller should ensure the asset landed first).
    func regenerateThumbnail(forHash hash: String, ext: String) async throws {
        guard let url = try await assets.url(for: hash) else {
            throw ImportError.thumbnailFailed
        }
        switch ext.lowercased() {
        case "mp4", "m4v", "mov":
            try await writeVideoThumbnail(sourceURL: url, hash: hash)
        default:
            // Image of some kind — JPEG, PNG, HEIC, GIF. ImageIO will
            // decode whatever CG recognises, so we don't need a per-ext
            // branch beyond the video discriminator.
            let data = try Data(contentsOf: url)
            try await writeThumbnail(from: data, isVideo: false, hash: hash)
        }
    }

    private func writeThumbnail(
        from data: Data, isVideo: Bool, hash: String
    ) async throws {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return
        }
        try await writeThumbnail(from: src, hash: hash)
    }

    private func writeVideoThumbnail(sourceURL: URL, hash: String) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let maxPx = Int(Self.thumbnailLongEdge * UIScreen.main.scale)
        generator.maximumSize = CGSize(width: maxPx, height: maxPx)
        let cgImage = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: .zero)]
            ) { _, image, _, result, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard result == .succeeded, let image else {
                    cont.resume(throwing: ImportError.thumbnailFailed)
                    return
                }
                cont.resume(returning: image)
            }
        }
        try await writeThumbnailJPEG(cgImage: cgImage, hash: hash)
    }

    // ImageIO-driven thumbnail for the photo path. Same downsample trick
    // as the main encode but capped at `thumbnailLongEdge`pt.
    private func writeThumbnail(
        from src: CGImageSource, hash: String
    ) async throws {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize:
                Int(Self.thumbnailLongEdge * UIScreen.main.scale),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImportError.thumbnailFailed
        }
        try await writeThumbnailJPEG(cgImage: cg, hash: hash)
    }

    private func writeThumbnailJPEG(cgImage: CGImage, hash: String) async throws {
        let thumbsDir = await assets.thumbsRoot
        let dest = thumbsDir.appendingPathComponent("\(hash).jpg")
        let out = NSMutableData()
        guard
            let dst = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil
            )
        else {
            throw ImportError.thumbnailFailed
        }
        let writeOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.80
        ]
        CGImageDestinationAddImage(dst, cgImage, writeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw ImportError.thumbnailFailed
        }
        try (out as Data).write(to: dest, options: .atomic)
    }

    // MARK: - Item-provider helpers

    private func loadDataRepresentation(
        from provider: NSItemProvider, typeIdentifier: String
    ) async throws -> (data: Data, type: String) {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<(Data, String), Error>) in
            provider.loadDataRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { data, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let data else {
                    cont.resume(throwing: ImportError.imageDecodeFailed)
                    return
                }
                cont.resume(returning: (data, typeIdentifier))
            }
        }
    }

    enum ImportError: Error, LocalizedError {
        case unsupportedType
        case imageDecodeFailed
        case imageEncodeFailed
        case videoLoadFailed
        case videoExportFailed
        case thumbnailFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedType:    "That media type isn't supported yet."
            case .imageDecodeFailed:  "Couldn't read the image."
            case .imageEncodeFailed:  "Couldn't encode the image."
            case .videoLoadFailed:    "Couldn't load the video."
            case .videoExportFailed:  "Video re-encode failed."
            case .thumbnailFailed:    "Couldn't generate a thumbnail."
            }
        }
    }
}

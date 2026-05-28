import ConstellationCore
import SwiftUI
import UIKit

// Cover "bloom": the ring of attachment thumbnails (petals) that fans
// out around a star as the user zooms in. Pulled out of SkyView so the
// canvas body stays focused on stars/edges/labels; this owns the petal
// geometry (LOD bands, ring sizing) and the per-petal drawing.
//
// Stateless — SkyView passes the per-frame inputs (transform, caches,
// the TimelineView date that drives video strip cycling, and a
// worldPosition resolver that folds in any in-flight drag). Draws
// directly into the same GraphicsContext as the rest of the canvas, on
// the layer just below labels.
enum SkyBloom {
    // 5 slots at 72° intervals on a ring around the star center,
    // starting at 36° (just past 12 o'clock, so slot 0 lands roughly NE
    // — matches the legacy single-moon position). Newest-first:
    // covers[0] → slot 0. Slots keep their fixed angles regardless of
    // how many petals are visible.
    //
    // Petal size and ring radius both grow with zoom: at scale ≤
    // bloomBaseScale the bloom uses the compact legacy geometry and
    // interpolates linearly to the expanded geometry at bloomPeakScale
    // (= the zoom ceiling), giving the user more room to look at photos
    // as they lean in.
    static let basePetalSize: CGFloat = 40
    static let basePetalRadius: CGFloat = 38
    static let bloomBaseScale: CGFloat = 1.6
    static let bloomPeakScale: CGFloat = 8.0
    static let petalCornerRadius: CGFloat = 6

    // Unit offsets (radius = 1) for each petal slot. Multiply by the
    // current ring radius for the actual pt offset. Precomputed to dodge
    // five sin+cos calls per bloom per frame.
    static let petalUnitOffsets: [CGPoint] = [
        CGPoint(x:  0.5878, y: -0.8090),   //  36°
        CGPoint(x:  0.9511, y:  0.3090),   // 108°
        CGPoint(x:  0,      y:  1.0000),   // 180°
        CGPoint(x: -0.9511, y:  0.3090),   // 252°
        CGPoint(x: -0.5878, y: -0.8090)    // 324°
    ]

    // Per-petal zoom fade windows (start, end). Each petal earns its own
    // band so the bloom progressively reveals as the user zooms in;
    // petal 0's 1.2→1.6 band preserves the original single-moon behavior
    // at moderate zoom for users who never push past it.
    static let petalLODBands: [(CGFloat, CGFloat)] = [
        (1.2, 1.6),
        (2.2, 2.6),
        (2.8, 3.2),
        (3.4, 3.8),
        (4.0, 4.4)
    ]

    // Zoom threshold at which video petals start cycling through their
    // strip frames (vs. a static cover). Tuned to kick in around the
    // time petal 2 is fully visible — motion at lower zoom would feel
    // busy across many tiny moons.
    static let stripCycleZoomThreshold: CGFloat = 3.0
    static let stripFrameInterval: TimeInterval = 0.5

    // iPad gets a substantially bigger bloom at peak zoom — far more
    // screen real estate to spread into. Compact (phone, or pad in
    // split view) gets a modest bump over the original 72/78.
    static func peakPetalSize(regularWidth: Bool) -> CGFloat {
        regularWidth ? 124 : 84
    }
    static func peakPetalRadius(regularWidth: Bool) -> CGFloat {
        regularWidth ? 136 : 92
    }
    static func bloomT(at scale: CGFloat) -> CGFloat {
        max(0, min(1, (scale - bloomBaseScale) / (bloomPeakScale - bloomBaseScale)))
    }
    static func petalSize(at scale: CGFloat, regularWidth: Bool) -> CGFloat {
        let t = bloomT(at: scale)
        return basePetalSize + (peakPetalSize(regularWidth: regularWidth) - basePetalSize) * t
    }
    static func petalOffsets(at scale: CGFloat, regularWidth: Bool) -> [CGPoint] {
        let t = bloomT(at: scale)
        let r = basePetalRadius + (peakPetalRadius(regularWidth: regularWidth) - basePetalRadius) * t
        return petalUnitOffsets.map { CGPoint(x: $0.x * r, y: $0.y * r) }
    }

    // The whole bloom pass: for each star with attachments, draw up to 5
    // LOD-gated petals around its screen position. `worldPosition`
    // resolves a skill to its world coords (folding in any in-flight
    // drag); `timelineDate` drives the video strip frame index.
    //
    // @MainActor because it reads the image caches and AttachmentImporter
    // constants, which are main-actor-isolated. Its only caller is the
    // SkyView Canvas closure, which is already on the main actor.
    @MainActor
    static func draw(
        into context: inout GraphicsContext,
        skills: [Skill],
        transform: CanvasTransform,
        coversBySkillId: [SkillID: [AttachmentCover]],
        attachmentCountsBySkillId: [SkillID: Int],
        coverCache: CoverCache,
        stripCache: StripCache,
        timelineDate: Date,
        regularWidth: Bool,
        worldPosition: (Skill) -> CGPoint
    ) {
        guard transform.scale > petalLODBands[0].0 else { return }
        let petalSize = petalSize(at: transform.scale, regularWidth: regularWidth)
        let offsets = petalOffsets(at: transform.scale, regularWidth: regularWidth)
        let stripFrameIdx = Int(
            timelineDate.timeIntervalSinceReferenceDate / stripFrameInterval
        ) % AttachmentImporter.stripFrameCount
        let cyclingVideos = transform.scale >= stripCycleZoomThreshold
        for skill in skills {
            guard let covers = coversBySkillId[skill.id] else { continue }
            let w = worldPosition(skill)
            let p = transform.apply(w.x, w.y)
            let totalCount = attachmentCountsBySkillId[skill.id] ?? covers.count
            for (idx, cover) in covers.prefix(offsets.count).enumerated() {
                let (start, end) = petalLODBands[idx]
                let alpha = max(0, min(1, (transform.scale - start) / (end - start)))
                if alpha <= 0 { continue }
                // Video at high zoom: prefer the current strip frame,
                // fall back to the static cover if the strip hasn't
                // loaded yet (so we never render a blank petal).
                let petalImage: UIImage? = {
                    if cyclingVideos, cover.mediaType == .video,
                       let frames = stripCache.frames(for: cover.contentHash),
                       stripFrameIdx < frames.count {
                        return frames[stripFrameIdx]
                    }
                    return coverCache.image(for: cover.contentHash)
                }()
                guard let uiImage = petalImage else { continue }
                let slot = offsets[idx]
                let rect = CGRect(
                    x: p.x + slot.x - petalSize / 2,
                    y: p.y + slot.y - petalSize / 2,
                    width: petalSize, height: petalSize
                )
                drawPetal(image: uiImage, in: rect, alpha: alpha, context: &context)
                // +K badge: only on the last slot, only when the skill
                // has more attachments than fit in the bloom.
                if idx == offsets.count - 1 && totalCount > offsets.count {
                    drawMoreBadge(
                        extra: totalCount - offsets.count,
                        in: rect, alpha: alpha, context: &context
                    )
                }
            }
        }
    }

    // Aspect-fill draw of a single petal thumbnail into the given square
    // rect, clipped to a rounded rect with a faint border stroke.
    static func drawPetal(
        image: UIImage,
        in rect: CGRect,
        alpha: CGFloat,
        context: inout GraphicsContext
    ) {
        let imgSize = image.size
        let aspect = imgSize.width / max(imgSize.height, 1)
        let drawRect: CGRect
        if aspect >= 1 {
            let w = rect.width * aspect
            drawRect = CGRect(
                x: rect.midX - w / 2,
                y: rect.minY,
                width: w, height: rect.height
            )
        } else {
            let h = rect.height / aspect
            drawRect = CGRect(
                x: rect.minX,
                y: rect.midY - h / 2,
                width: rect.width, height: h
            )
        }
        let resolved = context.resolve(Image(uiImage: image))
        context.drawLayer { layer in
            layer.opacity = alpha
            layer.clip(to: Path(roundedRect: rect, cornerRadius: petalCornerRadius))
            layer.draw(resolved, in: drawRect)
        }
        context.stroke(
            Path(roundedRect: rect, cornerRadius: petalCornerRadius),
            with: .color(.white.opacity(0.22 * alpha)),
            lineWidth: 0.6
        )
    }

    // "+K" badge overlaid on the last petal when a skill has more than 5
    // attachments. Bottom-right pill, dark scrim + white text — same
    // visual language as label scrims so it reads as UI chrome rather
    // than part of the photo.
    static func drawMoreBadge(
        extra: Int,
        in rect: CGRect,
        alpha: CGFloat,
        context: inout GraphicsContext
    ) {
        let label = "+\(extra)"
        let text = Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white)
        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 60, height: 20))
        let padX: CGFloat = 4
        let padY: CGFloat = 2
        let badgeWidth = textSize.width + padX * 2
        let badgeHeight = textSize.height + padY * 2
        let badgeRect = CGRect(
            x: rect.maxX - badgeWidth - 2,
            y: rect.maxY - badgeHeight - 2,
            width: badgeWidth,
            height: badgeHeight
        )
        context.drawLayer { layer in
            layer.opacity = alpha
            layer.fill(
                Path(roundedRect: badgeRect, cornerRadius: 4),
                with: .color(.black.opacity(0.65))
            )
            layer.draw(
                resolved,
                at: CGPoint(x: badgeRect.midX, y: badgeRect.midY),
                anchor: .center
            )
        }
    }
}

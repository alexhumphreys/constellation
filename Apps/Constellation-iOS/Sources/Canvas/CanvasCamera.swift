import CoreGraphics
import Foundation

// Pure world↔screen transform + camera-placement math for the
// constellation canvas. No SwiftUI, no @State — every function is
// referentially transparent, so the camera behavior (fit-all, cluster
// focus, point focus, eased pans) is unit-testable without standing up
// a view. SkyView owns the live scale/offset @State and the
// gesture/animation wiring; this file just computes where the camera
// should be.
//
// Coordinate spaces:
//   world  = the virtual sky the seed positions live in.
//   screen = the view's local coords (origin top-left).
// Conversion: screen = world * scale + offset.

// The forward/inverse transform between the two spaces. Tiny value type
// so the math lives in one place and is easy to test.
struct CanvasTransform: Equatable {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    // world → screen
    func apply(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * scale + offsetX, y: y * scale + offsetY)
    }

    // screen → world. Exact inverse of `apply`:
    // screen = world * scale + offset ⇒ world = (screen - offset) / scale
    func invert(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offsetX) / scale, y: (p.y - offsetY) / scale)
    }
}

// A resolved camera placement (zoom + pan). The placement functions
// return one of these; SkyView assigns it onto its separate scale /
// offset / bgPan @State. Kept distinct from CanvasTransform because the
// view stores offset as a CGSize and mirrors it into bgPan.
struct CameraPose: Equatable {
    var scale: CGFloat
    var offset: CGSize
}

enum CanvasCamera {
    // Fit a world-space box into `size`, inset by `padding` on every
    // side, with the box center landing at the viewport center. Zoom is
    // clamped to `zoomBounds`.
    static func fit(
        box: CGRect,
        padding: CGFloat,
        into size: CGSize,
        zoomBounds: ClosedRange<CGFloat>
    ) -> CameraPose {
        let availW = size.width - padding * 2
        let availH = size.height - padding * 2
        let s = min(availW / box.width, availH / box.height)
            .zoomClamped(to: zoomBounds)
        return CameraPose(
            scale: s,
            offset: CGSize(
                width: size.width / 2 - box.midX * s,
                height: size.height / 2 - box.midY * s
            )
        )
    }

    // Center `center` at the viewport center, at a zoom that would fit a
    // bbox of `bboxW` × `bboxH` into `viewportFraction` of the viewport —
    // but never below `minScale`, so a cluster focus always lands
    // demonstrably zoomed in rather than fit-to-min. Clamped to
    // `zoomBounds`.
    static func focusCluster(
        bboxW: CGFloat,
        bboxH: CGFloat,
        center: CGPoint,
        into size: CGSize,
        minScale: CGFloat,
        viewportFraction: CGFloat = 0.85,
        zoomBounds: ClosedRange<CGFloat>
    ) -> CameraPose {
        let fitScale = min(
            (size.width * viewportFraction) / bboxW,
            (size.height * viewportFraction) / bboxH
        )
        let s = Swift.max(minScale, fitScale).zoomClamped(to: zoomBounds)
        return CameraPose(
            scale: s,
            offset: CGSize(
                width: size.width / 2 - center.x * s,
                height: size.height / 2 - center.y * s
            )
        )
    }

    // Place `worldPoint` at the horizontal center and `verticalBias` of
    // the viewport height (0.5 = dead center; lower values lift the
    // point into the upper half so it isn't hidden by a bottom sheet),
    // at the given `scale`.
    static func focusPoint(
        worldPoint: CGPoint,
        scale: CGFloat,
        into size: CGSize,
        verticalBias: CGFloat
    ) -> CameraPose {
        CameraPose(
            scale: scale,
            offset: CGSize(
                width: size.width / 2 - worldPoint.x * scale,
                height: size.height * verticalBias - worldPoint.y * scale
            )
        )
    }

    // Linear interpolation between two poses by an already-eased factor
    // `t` in [0, 1]. Pair with `easeInOut` for the gentle-on-both-ends
    // camera pans SkyView animates frame-by-frame.
    static func lerp(from a: CameraPose, to b: CameraPose, t: CGFloat) -> CameraPose {
        CameraPose(
            scale: a.scale + (b.scale - a.scale) * t,
            offset: CGSize(
                width: a.offset.width + (b.offset.width - a.offset.width) * t,
                height: a.offset.height + (b.offset.height - a.offset.height) * t
            )
        )
    }

    // easeInOut cubic: 3t² - 2t³. Zero slope at both ends so an animated
    // pan doesn't lurch out of rest or slam into the target.
    static func easeInOut(_ t: CGFloat) -> CGFloat {
        (3 - 2 * t) * t * t
    }
}

extension CGFloat {
    // Renamed from `clamped` to avoid a name collision with the
    // package-scoped `clamped(to: ClosedRange<Double>)` Apple added
    // somewhere in the iOS 18 SDK — that one wins overload resolution
    // because the SDK considers `CGFloat == Double`, but its `package`
    // visibility means it's not callable from outside its owning module
    // and the build fails. Using a uniquely-named helper sidesteps the
    // whole question.
    func zoomClamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

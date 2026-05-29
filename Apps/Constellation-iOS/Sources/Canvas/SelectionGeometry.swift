import CoreGraphics
import Foundation

// Pure geometry for multi-select on the canvas. No SwiftUI, no @State —
// every function is referentially transparent, so the fiddly,
// silent-failure-prone bits (point-in-polygon ray casting, scaling a
// cluster about a pivot, the tighten radius clamp) are unit-testable
// without standing up a view. SkyView owns the live selection @State,
// the lasso/handle gestures, the ramp Timer, and the upsert commits;
// this file just answers the geometry questions they ask.
//
// All points are plain CGPoints — the caller decides whether they're in
// world space (centroid / scale for the spread) or screen space
// (point-in-polygon for the lasso); the math is identical either way.
enum SelectionGeometry {
    // Average of the given points (the cluster's centroid / the pivot a
    // spread scales about). nil for empty input so the caller can gate
    // on "is there a selection at all".
    static func centroid(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let n = CGFloat(points.count)
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    // Uniformly scale a point about a pivot. factor > 1 pushes it away
    // (expand), factor < 1 pulls it in (tighten), factor == 1 is the
    // identity. Applied per-point with a shared pivot, this scales a
    // whole cluster while leaving its centroid fixed.
    static func scaled(
        _ p: CGPoint, about pivot: CGPoint, by factor: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: pivot.x + (p.x - pivot.x) * factor,
            y: pivot.y + (p.y - pivot.y) * factor
        )
    }

    // Largest distance from `pivot` to any of `points` — the cluster's
    // radius. 0 for empty input. Tighten uses this to stop before the
    // stars collapse onto the centroid.
    static func maxRadius(of points: [CGPoint], about pivot: CGPoint) -> CGFloat {
        points.reduce(CGFloat(0)) { acc, p in
            let dx = p.x - pivot.x, dy = p.y - pivot.y
            return Swift.max(acc, (dx * dx + dy * dy).squareRoot())
        }
    }

    // Even-odd ray cast: count how many edges of the (implicitly closed)
    // polygon a rightward ray from `p` crosses — odd = inside. Fewer
    // than 3 vertices can't enclose anything, so always false. The j/i
    // wrap closes the polygon (last vertex back to first).
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

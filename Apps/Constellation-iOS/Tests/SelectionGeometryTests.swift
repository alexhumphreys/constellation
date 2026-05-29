import CoreGraphics
import Testing

@testable import Constellation_iOS

// Pure-geometry tests for multi-select. No view, no @State — this is
// exactly the math that was tangled inside SkyView's selection methods
// before the extraction, now exercisable in isolation.
@Suite("SelectionGeometry")
struct SelectionGeometryTests {

    @Test("centroid averages the points")
    func centroidAverages() throws {
        let c = try #require(SelectionGeometry.centroid(of: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 4, y: 0),
            CGPoint(x: 2, y: 6),
        ]))
        #expect(abs(c.x - 2) < 1e-9)
        #expect(abs(c.y - 2) < 1e-9)
    }

    @Test("centroid is nil for no points")
    func centroidEmpty() {
        #expect(SelectionGeometry.centroid(of: []) == nil)
    }

    @Test("scaled by 1 is the identity")
    func scaleIdentity() {
        let out = SelectionGeometry.scaled(
            CGPoint(x: 10, y: -4), about: CGPoint(x: 3, y: 3), by: 1
        )
        #expect(abs(out.x - 10) < 1e-9)
        #expect(abs(out.y + 4) < 1e-9)
    }

    @Test("scaled > 1 pushes away from the pivot, < 1 pulls in")
    func scaleExpandContract() {
        let pivot = CGPoint(x: 0, y: 0)
        let p = CGPoint(x: 2, y: 4)
        let out = SelectionGeometry.scaled(p, about: pivot, by: 2)
        #expect(abs(out.x - 4) < 1e-9)
        #expect(abs(out.y - 8) < 1e-9)
        let inward = SelectionGeometry.scaled(p, about: pivot, by: 0.5)
        #expect(abs(inward.x - 1) < 1e-9)
        #expect(abs(inward.y - 2) < 1e-9)
    }

    @Test("scaled holds the pivot itself fixed at any factor")
    func scalePivotFixed() {
        let pivot = CGPoint(x: 5, y: 7)
        let out = SelectionGeometry.scaled(pivot, about: pivot, by: 3.5)
        #expect(abs(out.x - 5) < 1e-9)
        #expect(abs(out.y - 7) < 1e-9)
    }

    @Test("maxRadius is the distance to the farthest point")
    func maxRadiusFarthest() {
        let r = SelectionGeometry.maxRadius(of: [
            CGPoint(x: 3, y: 0),    // 3
            CGPoint(x: 0, y: 5),    // 5  ← farthest
            CGPoint(x: -1, y: -1),  // ~1.41
        ], about: .zero)
        #expect(abs(r - 5) < 1e-9)
    }

    @Test("maxRadius is zero for no points")
    func maxRadiusEmpty() {
        #expect(SelectionGeometry.maxRadius(of: [], about: .zero) == 0)
    }

    // Axis-aligned square (0,0)…(10,10).
    private let square = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 10, y: 0),
        CGPoint(x: 10, y: 10),
        CGPoint(x: 0, y: 10),
    ]

    @Test("contains: a point inside the square is inside")
    func containsInside() {
        #expect(SelectionGeometry.contains(square, CGPoint(x: 5, y: 5)))
    }

    @Test("contains: points outside the square are outside")
    func containsOutside() {
        #expect(!SelectionGeometry.contains(square, CGPoint(x: 15, y: 5)))
        #expect(!SelectionGeometry.contains(square, CGPoint(x: 5, y: -1)))
    }

    @Test("contains: fewer than 3 vertices never contains")
    func containsDegenerate() {
        #expect(!SelectionGeometry.contains([], CGPoint(x: 0, y: 0)))
        #expect(!SelectionGeometry.contains(
            [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
            CGPoint(x: 0.5, y: 0.5)
        ))
    }

    // Concave "L": covers x∈[0,10] for y∈[0,4] (foot) and x∈[0,4] for
    // y∈[4,10] (upright). The top-right notch is inside the bounding box
    // but outside the shape — the case a rectangle lasso gets wrong and
    // a freeform one gets right, so the even-odd ray cast must handle it.
    @Test("contains: concave polygon excludes the notch")
    func containsConcave() {
        let lshape = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 4),
            CGPoint(x: 4, y: 4),
            CGPoint(x: 4, y: 10),
            CGPoint(x: 0, y: 10),
        ]
        #expect(SelectionGeometry.contains(lshape, CGPoint(x: 8, y: 2)))   // foot
        #expect(SelectionGeometry.contains(lshape, CGPoint(x: 2, y: 8)))   // upright
        #expect(!SelectionGeometry.contains(lshape, CGPoint(x: 8, y: 8)))  // notch
    }
}

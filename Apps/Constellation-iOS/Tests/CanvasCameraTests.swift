import CoreGraphics
import Testing

@testable import Constellation_iOS

// Pure-geometry tests for the canvas camera. No view, no @State — this
// is exactly the math that was tangled inside SkyView before the
// extraction, now exercisable in isolation.
@Suite("CanvasCamera")
struct CanvasCameraTests {
    let zoomBounds: ClosedRange<CGFloat> = 0.15...8.00

    // Helper: build a transform from a pose so we can check where world
    // points land on screen.
    private func transform(for pose: CameraPose) -> CanvasTransform {
        CanvasTransform(
            scale: pose.scale,
            offsetX: pose.offset.width,
            offsetY: pose.offset.height
        )
    }

    @Test("invert is the exact inverse of apply")
    func invertRoundTrip() {
        let t = CanvasTransform(scale: 1.7, offsetX: 120, offsetY: -45)
        let world = t.invert(t.apply(300, 200))
        #expect(abs(world.x - 300) < 1e-9)
        #expect(abs(world.y - 200) < 1e-9)
    }

    @Test("fit lands the box center at the viewport center")
    func fitCentersBox() {
        let size = CGSize(width: 1000, height: 800)
        let box = CGRect(x: 0, y: 0, width: 2400, height: 1600)
        let pose = CanvasCamera.fit(
            box: box, padding: 60, into: size, zoomBounds: zoomBounds
        )
        let mid = transform(for: pose).apply(box.midX, box.midY)
        #expect(abs(mid.x - size.width / 2) < 1e-6)
        #expect(abs(mid.y - size.height / 2) < 1e-6)
    }

    @Test("fit clamps an over-tight fit to the zoom ceiling")
    func fitClampsZoom() {
        let size = CGSize(width: 1000, height: 800)
        // A 10×10 box would want ~80× zoom; expect the ceiling instead.
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let pose = CanvasCamera.fit(
            box: box, padding: 0, into: size, zoomBounds: zoomBounds
        )
        #expect(pose.scale == zoomBounds.upperBound)
    }

    @Test("focusCluster never drops below minScale")
    func focusClusterFloor() {
        let size = CGSize(width: 400, height: 600)
        // A 5000×5000 cluster fit-scales well below the floor.
        let pose = CanvasCamera.focusCluster(
            bboxW: 5000, bboxH: 5000,
            center: CGPoint(x: 1200, y: 800),
            into: size, minScale: 0.60, zoomBounds: zoomBounds
        )
        #expect(abs(pose.scale - 0.60) < 1e-9)
    }

    @Test("focusCluster centers the cluster center")
    func focusClusterCenters() {
        let size = CGSize(width: 1000, height: 800)
        let center = CGPoint(x: 600, y: 400)
        let pose = CanvasCamera.focusCluster(
            bboxW: 300, bboxH: 200, center: center,
            into: size, minScale: 0.60, zoomBounds: zoomBounds
        )
        let mapped = transform(for: pose).apply(center.x, center.y)
        #expect(abs(mapped.x - size.width / 2) < 1e-6)
        #expect(abs(mapped.y - size.height / 2) < 1e-6)
    }

    @Test("focusPoint honors the vertical bias")
    func focusPointVerticalBias() {
        let size = CGSize(width: 1000, height: 800)
        let p = CGPoint(x: 500, y: 500)
        let pose = CanvasCamera.focusPoint(
            worldPoint: p, scale: 2.0, into: size, verticalBias: 0.25
        )
        let mapped = transform(for: pose).apply(p.x, p.y)
        #expect(abs(mapped.x - size.width / 2) < 1e-6)
        #expect(abs(mapped.y - size.height * 0.25) < 1e-6)
        #expect(pose.scale == 2.0)
    }

    @Test("easeInOut pins both endpoints and is symmetric at the midpoint")
    func easeEndpoints() {
        #expect(CanvasCamera.easeInOut(0) == 0)
        #expect(CanvasCamera.easeInOut(1) == 1)
        #expect(abs(CanvasCamera.easeInOut(0.5) - 0.5) < 1e-9)
    }

    @Test("lerp returns the bounds at t=0 and t=1")
    func lerpEndpoints() {
        let a = CameraPose(scale: 1, offset: .zero)
        let b = CameraPose(scale: 3, offset: CGSize(width: 100, height: -50))
        #expect(CanvasCamera.lerp(from: a, to: b, t: 0) == a)
        #expect(CanvasCamera.lerp(from: a, to: b, t: 1) == b)
        let mid = CanvasCamera.lerp(from: a, to: b, t: 0.5)
        #expect(abs(mid.scale - 2) < 1e-9)
        #expect(abs(mid.offset.width - 50) < 1e-9)
        #expect(abs(mid.offset.height - (-25)) < 1e-9)
    }
}

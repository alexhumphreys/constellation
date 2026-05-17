import SwiftUI
import UIKit

// Transparent UIKit overlay that owns the pan / pinch / tap / long-press
// recognizers for the constellation canvas.
//
// Why UIKit instead of SwiftUI's MagnifyGesture + DragGesture:
//   1. SwiftUI's DragGesture is single-finger; MagnifyGesture is two-
//      finger. SimultaneousGesture composes them as "pan OR zoom",
//      never "pan AND zoom on the same two-finger gesture". UIKit's
//      UIPan + UIPinch with shouldRecognizeSimultaneouslyWith == true
//      give you the MapKit/Photos pan-while-pinching feel for free.
//   2. UIKit gesture recognizers have been stable for ~15 years;
//      SwiftUI's gesture system has had visible regressions across
//      most iOS majors. The canvas's primary interaction is
//      pan/zoom — worth building it on the more boring foundation.
//
// The view is transparent and is placed on top of the SwiftUI Canvas
// inside a ZStack. SwiftUI still owns the drawing and the @State that
// describes the transform; this view only mutates that state in
// response to touches.
struct CanvasGestureSurface: UIViewRepresentable {
    @Binding var offset: CGSize
    @Binding var scale: CGFloat
    let zoomBounds: ClosedRange<CGFloat>
    let onTap: (CGPoint) -> Void
    // Long-press drag callbacks. began returns true if the hit-test
    // matched a draggable target — that's the signal that we should
    // suppress pan for the rest of this gesture. Each tick during
    // .changed/.autoPan passes the *current finger location in view
    // coords*; the host translates that to world coords. The host
    // also gets to override the view's offset (passed via the binding)
    // each tick, so edge auto-pan composes cleanly.
    let onDragBegan: (CGPoint) -> Bool
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        // 1 → 2 touches so the same recognizer covers single-finger
        // pan AND the two-finger pan that runs alongside a pinch.
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // Default config (single tap, single touch) fails when a pan
        // or pinch starts, which is what we want — taps shouldn't
        // fire when the user is dragging.
        view.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        // 0.4s feels snappier than the 0.5s default without competing
        // with the "hold to inspect" muscle memory iOS users have. The
        // finger has to stay roughly still for those 0.4s, which is
        // what gives us free non-interference with pan (pan needs
        // movement, long-press needs stillness — they don't both fire
        // for the same touch sequence).
        longPress.minimumPressDuration = 0.4
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)
        context.coordinator.longPress = longPress

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Refresh the coordinator's pointer at the latest parent so the
        // closures (especially onTap) it invokes always see the current
        // SwiftUI state.
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CanvasGestureSurface

        // Snapshot taken at pinch-begin so each .changed tick can solve
        // for the offset that keeps `pinchAnchorWorld` glued under the
        // current two-finger centroid.
        private var pinchStartScale: CGFloat = 1.0
        private var pinchAnchorWorld: CGPoint = .zero
        private var pinchActive: Bool = false

        // Drag state. While `draggingActive` is true, the pan handler
        // consumes its translation and bails so we don't move the
        // canvas underneath the star at the same time.
        weak var longPress: UILongPressGestureRecognizer?
        weak var pan: UIPanGestureRecognizer?
        private var draggingActive: Bool = false
        private var autoPanLink: CADisplayLink?
        // Most recent finger location in view coords, refreshed each
        // long-press tick and read by the display-link callback so
        // edge auto-pan doesn't need its own gesture handle.
        private var lastDragLocation: CGPoint = .zero
        private weak var hostView: UIView?

        init(parent: CanvasGestureSurface) {
            self.parent = parent
        }

        // Let pan and pinch fire on the same touches. This is the line
        // that buys us pan-while-pinching: without it UIKit picks one
        // recognizer and starves the other.
        func gestureRecognizer(
            _ a: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // MARK: pan

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            // During a pinch the pinch handler is already moving the
            // offset to track the centroid; applying pan's translation
            // on top would double-count. We still consume it (reset to
            // zero) so when the pinch ends the pan picks up cleanly
            // from the current finger position instead of snapping
            // back by the accumulated translation.
            //
            // Same story while a star is being dragged: the long-press
            // handler is what's mutating world state, and we don't
            // want the canvas to slide under it.
            if pinchActive || draggingActive {
                g.setTranslation(.zero, in: g.view)
                return
            }
            switch g.state {
            case .changed:
                let t = g.translation(in: g.view)
                parent.offset.width  += t.x
                parent.offset.height += t.y
                g.setTranslation(.zero, in: g.view)
            default:
                break
            }
        }

        // MARK: pinch

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                pinchActive = true
                pinchStartScale = parent.scale
                let anchor = g.location(in: g.view)
                // World point under the gesture's starting centroid.
                pinchAnchorWorld = CGPoint(
                    x: (anchor.x - parent.offset.width)  / pinchStartScale,
                    y: (anchor.y - parent.offset.height) / pinchStartScale
                )

            case .changed:
                // location(in:) returns the *current* centroid, which
                // tracks the fingers as they move — that's how pan
                // composes with pinch without a separate handler.
                let anchor = g.location(in: g.view)
                let newScale = clamp(
                    pinchStartScale * g.scale, to: parent.zoomBounds
                )
                parent.scale = newScale
                parent.offset = CGSize(
                    width:  anchor.x - pinchAnchorWorld.x * newScale,
                    height: anchor.y - pinchAnchorWorld.y * newScale
                )

            case .ended, .cancelled, .failed:
                pinchActive = false
                // Fingers almost never lift in the same instant — one
                // comes off first, which collapses UIPan's tracked
                // centroid from "avg of 2 fingers" to "position of the
                // remaining finger". Without this reset, that 20–80pt
                // delta leaks into the next pan tick as a visible snap.
                pan?.setTranslation(.zero, in: g.view)

            default:
                break
            }
        }

        // MARK: tap

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            let loc = g.location(in: g.view)
            parent.onTap(loc)
        }

        // MARK: long-press drag

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            let loc = g.location(in: g.view)
            switch g.state {
            case .began:
                // Ask the host to hit-test. If nothing was under the
                // finger we cancel the recognizer so subsequent ticks
                // don't keep firing for an empty drag, and so the user
                // can long-press background → still pan/zoom normally.
                if parent.onDragBegan(loc) {
                    draggingActive = true
                    lastDragLocation = loc
                    hostView = g.view
                    startAutoPanIfNeeded()
                } else {
                    g.isEnabled = false
                    g.isEnabled = true
                }

            case .changed:
                guard draggingActive else { return }
                lastDragLocation = loc
                parent.onDragChanged(loc)

            case .ended, .cancelled, .failed:
                guard draggingActive else { return }
                draggingActive = false
                stopAutoPan()
                parent.onDragEnded()

            default:
                break
            }
        }

        // MARK: edge auto-pan

        private func startAutoPanIfNeeded() {
            guard autoPanLink == nil else { return }
            let link = CADisplayLink(
                target: self, selector: #selector(autoPanTick)
            )
            // .common so it keeps firing while UIKit is tracking
            // touches (default mode would pause during tracking).
            link.add(to: .main, forMode: .common)
            autoPanLink = link
        }

        private func stopAutoPan() {
            autoPanLink?.invalidate()
            autoPanLink = nil
        }

        @objc private func autoPanTick() {
            guard draggingActive, let view = hostView else { return }
            let bounds = view.bounds
            // Inset = how close to the edge the finger has to be
            // before we start scrolling. Speed ramps from 0 at the
            // inset boundary to `maxSpeed` at the very edge so the
            // pan accelerates the closer you get.
            let inset: CGFloat = 60
            let maxSpeed: CGFloat = 12  // pts per frame at the edge
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            let p = lastDragLocation
            if p.x < inset {
                dx = (inset - p.x) / inset * maxSpeed
            } else if p.x > bounds.width - inset {
                dx = -((p.x - (bounds.width - inset)) / inset * maxSpeed)
            }
            if p.y < inset {
                dy = (inset - p.y) / inset * maxSpeed
            } else if p.y > bounds.height - inset {
                dy = -((p.y - (bounds.height - inset)) / inset * maxSpeed)
            }
            guard dx != 0 || dy != 0 else { return }
            // Move the canvas in the direction we're pushing — same
            // sign as a finger drag in that direction.
            parent.offset.width  += dx
            parent.offset.height += dy
            // The finger hasn't moved, but the canvas under it has —
            // so from the star's perspective the world point under
            // the finger has shifted. Re-emit a changed event so the
            // host re-solves the star's world position and it tracks.
            parent.onDragChanged(p)
        }

        private func clamp(
            _ v: CGFloat, to range: ClosedRange<CGFloat>
        ) -> CGFloat {
            Swift.min(range.upperBound, Swift.max(range.lowerBound, v))
        }
    }
}

// UIView subclass whose only job is to swallow hit-tests for the area
// it covers so the gesture recognizers attached to it actually receive
// touches. A plain UIView with `.clear` backgroundColor *does* receive
// touches in this configuration, but subclassing also gives us a
// single place to intervene later (e.g. forward unhandled touches to
// a child) without surprising anyone.
private final class TouchView: UIView {}

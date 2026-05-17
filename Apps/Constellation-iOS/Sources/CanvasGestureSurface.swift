import SwiftUI
import UIKit

// Transparent UIKit overlay that owns the pan / pinch / tap recognizers
// for the constellation canvas.
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
            if pinchActive {
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

            default:
                break
            }
        }

        // MARK: tap

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            let loc = g.location(in: g.view)
            parent.onTap(loc)
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

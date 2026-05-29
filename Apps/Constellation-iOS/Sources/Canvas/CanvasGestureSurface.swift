import QuartzCore
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
    // Pan-only mirror of offset. The pan handler updates this alongside
    // offset; the pinch handler doesn't touch it. SkyView uses it to
    // position the parallax background so pinches don't slide the sky.
    @Binding var bgPan: CGSize
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
    // Fired on touch-lift. The CGPoint is the finger's screen-space
    // velocity (pt/s) at release, for star flick — zero on a
    // cancelled/failed drag and on a release with no recent motion.
    let onDragEnded: (CGPoint) -> Void
    // Fired once at the start of any user-driven canvas gesture
    // (pan or pinch). Used by the host to dismiss transient overlays
    // — chain trace, etc. — without needing to watch offset/scale.
    var onCanvasGestureBegan: () -> Void = {}
    // Select-mode lasso. While true, a one-finger drag traces a
    // freeform selection path (reported in view coords) instead of
    // panning the canvas; two-finger pan + pinch still navigate, and a
    // long-press star-grab still wins (it suppresses pan before we get
    // here). onLassoChanged fires per tick with the path so far;
    // onLassoEnded fires once on lift with the final path.
    var isSelectMode: Bool = false
    var onLassoChanged: ([CGPoint]) -> Void = { _ in }
    var onLassoEnded: ([CGPoint]) -> Void = { _ in }

    func makeUIView(context: Context) -> UIView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        // Kill any in-flight momentum glide the instant a new finger
        // lands — before any recognizer has even decided what the
        // gesture is — so a follow-up tap/pan/pinch/long-press grabs
        // control without fighting the decaying camera.
        view.onTouchDown = { [weak coordinator = context.coordinator] in
            coordinator?.cancelMomentum()
            // Warm the Taptic engine now so the catch beat fires with
            // no latency if this touch promotes to a long-press grab.
            coordinator?.prepareDragCatchHaptic()
        }

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
        context.coordinator.tap = tap

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        // 0.28s is short enough to feel like a direct grab but still
        // safely above the threshold where casual taps accidentally
        // promote to drags (iOS's own UICollectionView reorder uses
        // ~0.5s; we tolerate going shorter because pan needs >0pt
        // movement and our taps land within ~120ms, so the windows
        // don't overlap meaningfully).
        longPress.minimumPressDuration = 0.28
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

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.tearDown()
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
        // Touch count at the last pinch tick — a change means a finger
        // was added/removed mid-pinch, which needs an anchor re-baseline.
        private var lastPinchTouchCount: Int = 0

        // Drag state. While `draggingActive` is true, the pan handler
        // consumes its translation and bails so we don't move the
        // canvas underneath the star at the same time.
        weak var longPress: UILongPressGestureRecognizer?
        weak var tap: UITapGestureRecognizer?
        private var draggingActive: Bool = false
        // Select-mode lasso state. `lassoActive` latches at .began for a
        // one-finger drag (sticky for the rest of the gesture even if a
        // second finger lands) so the freeform path keeps tracking
        // rather than flipping to a pan mid-stroke.
        private var lassoActive: Bool = false
        private var lassoPoints: [CGPoint] = []
        // Fired the instant a long-press catches a star (single or
        // group), so the grab has a tactile "it's now yours" beat.
        // iPhone-only (iPad no-ops); flip the flag to disable.
        private static let dragCatchHapticEnabled = true
        private let dragCatchHaptic = UIImpactFeedbackGenerator(style: .rigid)

        func prepareDragCatchHaptic() {
            if Self.dragCatchHapticEnabled { dragCatchHaptic.prepare() }
        }
        private let autoPan = DisplayLinkDriver()
        // Most recent finger location in view coords, refreshed each
        // long-press tick and read by the display-link callback so
        // edge auto-pan doesn't need its own gesture handle.
        private var lastDragLocation: CGPoint = .zero
        private weak var hostView: UIView?
        // Recent (location, time) samples during a star drag, used to
        // compute the finger's release velocity for star flick. Trimmed
        // to a short trailing window each tick.
        private var dragSamples: [(loc: CGPoint, t: CFTimeInterval)] = []
        private static let flickVelocityWindow: CFTimeInterval = 0.08

        // Pan momentum (flick-to-glide). Velocity is captured from UIPan
        // on .ended and decayed frame-by-frame until it falls below a
        // stop threshold. Updates offset + bgPan exactly like a live pan,
        // so the parallax background keeps drifting through the glide.
        private let momentum = DisplayLinkDriver()
        private var momentumVelocity: CGPoint = .zero
        private var momentumLastTime: CFTimeInterval = 0

        // Tracks UIPan's touch count across ticks so we can swallow the
        // translation spike when a finger is added or lifted — the
        // tracked centroid jumps between the 2-finger average and the
        // lone finger, and that delta would otherwise land in one tick
        // as a visible snap. Replaces the old pinch-.ended translation
        // reset, which only caught the pinch→pan transition and raced
        // the pan handler to do it.
        private var lastPanTouchCount: Int = 0
        // True once this pan gesture has actually moved the canvas (a
        // real one/two-finger pan, not a suppressed star-drag or a pure
        // pinch). Gates momentum so lifting fingers off a pinch or a
        // star-drag can't fling the camera.
        private var panMovedCanvas: Bool = false

        // Momentum tuning. decelerationPerMs mirrors UIScrollView's
        // normal rate (~0.998/ms); the rest are felt-tuned starting
        // points — adjust on device. minFling: below this a release
        // reads as a deliberate stop, not a flick. stopSpeed: end the
        // glide once it slows to a crawl. maxFling: clamp a violent
        // flick so it can't shoot across the whole world.
        private static let decelerationPerMs: Double = 0.998
        private static let minFlingSpeed: CGFloat = 120   // pt/s
        private static let stopSpeed: CGFloat = 40        // pt/s
        private static let maxFlingSpeed: CGFloat = 8000  // pt/s

        init(parent: CanvasGestureSurface) {
            self.parent = parent
        }

        // Invalidate both display links. Called from dismantleUIView when
        // SwiftUI tears the surface down — the links retain their driver
        // until invalidated, so this is what breaks that cycle.
        func tearDown() {
            autoPan.stop()
            momentum.stop()
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
            if draggingActive {
                g.setTranslation(.zero, in: g.view)
                return
            }
            // Select-mode lasso intercepts a one-finger drag before any
            // canvas panning. Decided at .began by touch count, so a
            // two-finger gesture still falls through to pan/zoom.
            if parent.isSelectMode, handleLasso(g) {
                return
            }
            switch g.state {
            case .began:
                lastPanTouchCount = g.numberOfTouches
                panMovedCanvas = false
                parent.onCanvasGestureBegan()
            case .changed:
                // A finger added/lifted collapses UIPan's tracked
                // centroid between the 2-finger average and the lone
                // finger; that delta lands in this tick's translation as
                // a visible jump. Swallow the tick that straddles the
                // change and re-anchor, so the next tick measures clean.
                if g.numberOfTouches != lastPanTouchCount {
                    lastPanTouchCount = g.numberOfTouches
                    g.setTranslation(.zero, in: g.view)
                    return
                }
                let t = g.translation(in: g.view)
                // Pinch handler already moves `offset` to track the
                // gesture centroid (including any two-finger drift), so
                // adding pan's translation on top would double-count.
                // bgPan is the pan-only mirror — feed it the raw
                // translation whether or not pinch is active, so the
                // background drifts during pan-while-pinching but
                // doesn't slide for a pure scale change.
                if !pinchActive {
                    parent.offset.width  += t.x
                    parent.offset.height += t.y
                    panMovedCanvas = true
                }
                parent.bgPan.width  += t.x
                parent.bgPan.height += t.y
                g.setTranslation(.zero, in: g.view)
            case .ended:
                // Flick → glide. Only for a real pan (not a pinch tail
                // or a suppressed star-drag, both of which leave
                // panMovedCanvas false), and only above a min speed so a
                // slow release reads as a deliberate stop.
                if panMovedCanvas && !pinchActive {
                    startMomentum(velocity: g.velocity(in: g.view))
                }
            default:
                break
            }
        }

        // Freeform lasso path for a one-finger select-mode drag. Returns
        // true while it owns the gesture so handlePan bails out of any
        // canvas panning. Latches at .began on a single touch; once
        // active it stays active for the rest of the gesture (a late
        // second finger won't convert it to a pan).
        private func handleLasso(_ g: UIPanGestureRecognizer) -> Bool {
            switch g.state {
            case .began:
                guard g.numberOfTouches == 1 else { return false }
                lassoActive = true
                lassoPoints = [g.location(in: g.view)]
                parent.onLassoChanged(lassoPoints)
                return true
            case .changed:
                guard lassoActive else { return false }
                lassoPoints.append(g.location(in: g.view))
                parent.onLassoChanged(lassoPoints)
                return true
            case .ended, .cancelled, .failed:
                guard lassoActive else { return false }
                lassoActive = false
                let pts = lassoPoints
                lassoPoints = []
                parent.onLassoEnded(pts)
                return true
            default:
                return false
            }
        }

        // MARK: pinch

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                pinchActive = true
                lastPinchTouchCount = g.numberOfTouches
                capturePinchAnchor(g)
                parent.onCanvasGestureBegan()

            case .changed:
                // Dropped to a single touch (the other finger lifted):
                // leave pinch mode rather than re-anchor the world point
                // onto the lone finger — that re-anchor was the visible
                // "snap to the remaining finger". With pinchActive off the
                // pan handler drives the remaining finger, giving the
                // Maps-style pan-after-pinch. (Pan's own numberOfTouches
                // guard absorbs the centroid jump on the way down.)
                guard g.numberOfTouches >= 2 else {
                    pinchActive = false
                    lastPinchTouchCount = g.numberOfTouches
                    return
                }
                // (Re)entering two-finger mode, or the touch count changed
                // while pinching: re-baseline anchor + scale so resuming
                // after a one-finger pan (or adding/removing a finger)
                // doesn't jump the world out from under the fingers.
                if !pinchActive || g.numberOfTouches != lastPinchTouchCount {
                    pinchActive = true
                    capturePinchAnchor(g)
                }
                lastPinchTouchCount = g.numberOfTouches
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

        // Snapshot the world point under the current two-finger centroid
        // and reset the recognizer's cumulative scale to 1, so subsequent
        // .changed ticks solve offset/scale relative to *now*. Called at
        // pinch .began and again whenever the touch set changes mid-pinch.
        private func capturePinchAnchor(_ g: UIPinchGestureRecognizer) {
            pinchStartScale = parent.scale
            g.scale = 1.0
            let anchor = g.location(in: g.view)
            pinchAnchorWorld = CGPoint(
                x: (anchor.x - parent.offset.width)  / parent.scale,
                y: (anchor.y - parent.offset.height) / parent.scale
            )
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
                    if Self.dragCatchHapticEnabled {
                        dragCatchHaptic.impactOccurred()
                    }
                    lastDragLocation = loc
                    dragSamples = [(loc, CACurrentMediaTime())]
                    hostView = g.view
                    startAutoPanIfNeeded()
                    // Cancel any in-flight tap on the same touches.
                    // Otherwise a drag that ends within UITap's
                    // allowableMovement (~10pt) lets tap fire on
                    // touch lift alongside the drag's .ended, which
                    // re-opens the inspector for the star we just
                    // moved — the "moving a star sometimes opens it"
                    // leak.
                    tap?.isEnabled = false
                    tap?.isEnabled = true
                } else {
                    g.isEnabled = false
                    g.isEnabled = true
                }

            case .changed:
                guard draggingActive else { return }
                lastDragLocation = loc
                recordDragSample(loc)
                parent.onDragChanged(loc)

            case .ended:
                guard draggingActive else { return }
                draggingActive = false
                stopAutoPan()
                recordDragSample(loc)
                parent.onDragEnded(dragReleaseVelocity())

            case .cancelled, .failed:
                guard draggingActive else { return }
                draggingActive = false
                stopAutoPan()
                parent.onDragEnded(.zero)

            default:
                break
            }
        }

        // Append a drag sample and drop anything older than the velocity
        // window so dragReleaseVelocity only ever sees recent motion.
        private func recordDragSample(_ loc: CGPoint) {
            let now = CACurrentMediaTime()
            dragSamples.append((loc, now))
            let cutoff = now - Self.flickVelocityWindow
            while dragSamples.count > 2, dragSamples.first!.t < cutoff {
                dragSamples.removeFirst()
            }
        }

        // Finger velocity (pt/s) over the trailing sample window. Zero if
        // there isn't enough recent motion to measure — a slow release or
        // a press-and-hold then lift reads as a deliberate stop, not a
        // flick.
        private func dragReleaseVelocity() -> CGPoint {
            guard let last = dragSamples.last, let first = dragSamples.first,
                  dragSamples.count >= 2 else { return .zero }
            let dt = last.t - first.t
            guard dt > 0 else { return .zero }
            return CGPoint(
                x: (last.loc.x - first.loc.x) / dt,
                y: (last.loc.y - first.loc.y) / dt
            )
        }

        // MARK: edge auto-pan

        private func startAutoPanIfNeeded() {
            guard !autoPan.isRunning else { return }
            autoPan.start { [weak self] _ in self?.autoPanTick() }
        }

        private func stopAutoPan() {
            autoPan.stop()
        }

        private func autoPanTick() {
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

        // MARK: pan momentum

        private func startMomentum(velocity v: CGPoint) {
            let speed = magnitude(v)
            guard speed > Self.minFlingSpeed else {
                cancelMomentum()
                return
            }
            momentumVelocity = clampMagnitude(v, to: Self.maxFlingSpeed)
            momentumLastTime = CACurrentMediaTime()
            momentum.start { [weak self] link in self?.momentumTick(link) }
        }

        // Cancel mid-glide (a fresh touch landed, or the gesture surface
        // is going away). Leaves the camera wherever the glide reached.
        func cancelMomentum() {
            momentum.stop()
            momentumVelocity = .zero
        }

        private func momentumTick(_ link: CADisplayLink) {
            let now = link.timestamp
            let dt = now - momentumLastTime
            momentumLastTime = now
            guard dt > 0 else { return }
            // Cap the advance step so a dropped frame / stall can't
            // teleport the canvas; decay still uses the true elapsed
            // time so the velocity is correct after the hitch.
            let step = CGFloat(Swift.min(dt, 1.0 / 30.0))
            parent.offset.width  += momentumVelocity.x * step
            parent.offset.height += momentumVelocity.y * step
            parent.bgPan.width   += momentumVelocity.x * step
            parent.bgPan.height  += momentumVelocity.y * step
            // UIScrollView models deceleration as velocity *= rate^millis
            // — frame-rate independent, so the feel holds at 60 or 120Hz.
            let decay = CGFloat(pow(Self.decelerationPerMs, dt * 1000))
            momentumVelocity.x *= decay
            momentumVelocity.y *= decay
            if magnitude(momentumVelocity) < Self.stopSpeed {
                cancelMomentum()
            }
        }

        private func magnitude(_ v: CGPoint) -> CGFloat {
            (v.x * v.x + v.y * v.y).squareRoot()
        }

        private func clampMagnitude(_ v: CGPoint, to maxSpeed: CGFloat) -> CGPoint {
            let speed = magnitude(v)
            guard speed > maxSpeed else { return v }
            let k = maxSpeed / speed
            return CGPoint(x: v.x * k, y: v.y * k)
        }
    }
}

// UIView subclass whose only job is to swallow hit-tests for the area
// it covers so the gesture recognizers attached to it actually receive
// touches. A plain UIView with `.clear` backgroundColor *does* receive
// touches in this configuration, but subclassing also gives us a hook
// for raw finger-down (used to cancel pan momentum the instant a touch
// lands, before any recognizer has decided what the gesture is).
private final class TouchView: UIView {
    var onTouchDown: () -> Void = {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        onTouchDown()
    }
}

// Thin wrapper around CADisplayLink so the canvas's frame-ticked loops
// (edge auto-pan during a drag, pan momentum after a flick) share one
// create / add-to-runloop / invalidate path instead of each hand-rolling
// it. Owns a single link; `start` replaces any already in flight. The
// frame closure should capture its owner weakly — the link retains this
// driver (via target/selector) until `stop`, so the owner must call
// `stop` from deinit to break that cycle.
private final class DisplayLinkDriver {
    private var link: CADisplayLink?
    private var onFrame: ((CADisplayLink) -> Void)?

    var isRunning: Bool { link != nil }

    func start(_ onFrame: @escaping (CADisplayLink) -> Void) {
        stop()
        self.onFrame = onFrame
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // .common so it keeps firing while UIKit is tracking touches
        // (the default runloop mode would pause during tracking).
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        onFrame?(link)
    }
}

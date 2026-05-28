import CoreGraphics
import Foundation

// A hand-rolled frame-ticking animator for values that drive a SwiftUI
// Canvas. withAnimation can't be used here: it interpolates animatable
// view modifiers, not plain values read inside a Canvas content closure
// — so a withAnimation block snaps the value in a single body re-eval
// instead of animating it. This ticks ~60Hz over a duration and hands
// the eased 0→1 progress to onFrame, so the caller can lerp whatever it
// owns (a camera pose, an overlay opacity, …).
//
// Extracted from the twin loops that lived in SkyView.animateFocus and
// ChainTrace.beginFadeOut.
@MainActor
final class CanvasValueAnimator {
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    // Drive onFrame at ~60Hz over `duration`, easing raw 0→1 progress
    // with `easing`. onFrame is called once more with t=1 at the end,
    // then onComplete. Cancels any animation already in flight (last
    // writer wins), so a fresh focus pan pre-empts a queued one.
    func animate(
        duration: TimeInterval,
        easing: @escaping (CGFloat) -> CGFloat,
        onFrame: @escaping (CGFloat) -> Void,
        onComplete: @escaping () -> Void = {}
    ) {
        task?.cancel()
        let frameInterval: UInt64 = 16_666_667  // ~60Hz, nanoseconds
        let startTime = Date.now
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let elapsed = Date.now.timeIntervalSince(startTime)
                if elapsed >= duration {
                    onFrame(1)
                    break
                }
                onFrame(easing(CGFloat(elapsed / duration)))
                try? await Task.sleep(nanoseconds: frameInterval)
            }
            if Task.isCancelled { return }
            self?.task = nil
            onComplete()
        }
    }

    // Stop any in-flight animation immediately, leaving the animated
    // value wherever it currently is (onComplete does NOT run). The
    // caller is responsible for any reset/finalize it wants.
    func cancel() {
        task?.cancel()
        task = nil
    }
}

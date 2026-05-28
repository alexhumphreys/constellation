import ConstellationCore
import Foundation

// Drives the backward-chain overlay: which skill is being traced, the
// fade-out animation, and the resolved set of lit skills. Pulled out of
// RootView so the chain's state + its hand-rolled animation engine live
// in one place instead of as four loose @State vars and three methods on
// the root view.
//
// Backward chain = "what's the path to here" — the learning-planning
// move. RootView owns the skill data and the hobby-filter; this owns the
// trace target and its opacity. Held by RootView as @State so SwiftUI
// observes targetId / opacity reads in the canvas bindings.
//
// Lives at Sources/ root rather than in Canvas/ because RootView owns it
// and it's feature-state that *feeds* the canvas (as plain data), not a
// renderer. It could arguably live in Canvas/ as the chain-overlay
// controller — judgment call; left here so Canvas/ stays "things that
// draw/handle the sky."
@MainActor
@Observable
final class ChainTrace {
    // The skill the overlay is tracing to (nil = no trace). Nulled when
    // the user navigates away so the chain can't outlive the context
    // that explains it.
    private(set) var targetId: SkillID?

    // Visual fade factor for the overlay, 1→0 during a fade-out. The
    // canvas multiplies its gold-edge alphas by this.
    private(set) var opacity: Double = 1.0

    // Drives the fade-out (frame-by-frame; see CanvasValueAnimator for
    // why withAnimation can't). A new trace or an instant clear cancels
    // it; beginFadeOut skips if one is already running.
    @ObservationIgnored private let fadeAnimator = CanvasValueAnimator()

    // Resolved BFS backward chain for the active target, materialised as
    // a Set so SkyView's per-edge / per-star check is O(1). Empty when no
    // trace is active.
    func litSkillIds(in skills: [Skill]) -> Set<SkillID> {
        guard let targetId else { return [] }
        return Set(SkillGraph(skills).backwardChain(from: targetId))
    }

    // Explicit toggle from the inspector's Trace button. Instant —
    // cancels any in-flight fade and resets opacity so a re-toggle
    // doesn't ramp up from a half-faded state. Returns the (possibly
    // empty) chain so the caller can reveal the hobbies it crosses;
    // returns [] when the toggle turned the trace off.
    @discardableResult
    func toggle(to id: SkillID, in skills: [Skill]) -> [SkillID] {
        fadeAnimator.cancel()
        opacity = 1.0
        if targetId == id {
            targetId = nil
            return []
        }
        targetId = id
        return SkillGraph(skills).backwardChain(from: id)
    }

    // Drop the trace instantly (cancel fade, reset opacity). Used when
    // the user selects a different skill — that intent change explained
    // the previous context, not this one, so the next trace renders
    // crisply.
    func clear() {
        fadeAnimator.cancel()
        opacity = 1.0
        targetId = nil
    }

    // Animate the trace to invisible over 2s, then drop the target.
    // Holding targetId in place during the fade keeps litSkillIds non-
    // empty so the gold overlay has something to multiply opacity
    // against. Re-entrant: if a fade is already in flight, leave it.
    func beginFadeOut() {
        guard targetId != nil, !fadeAnimator.isRunning else { return }
        fadeAnimator.animate(
            duration: 2.0,
            easing: { 1 - (1 - $0) * (1 - $0) },  // easeOut quadratic
            onFrame: { [weak self] eased in self?.opacity = 1.0 - eased },
            onComplete: { [weak self] in
                self?.targetId = nil
                self?.opacity = 1.0
            }
        )
    }
}

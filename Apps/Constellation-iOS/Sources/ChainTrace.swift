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

    // Cancellable task that finalizes a fade-out by clearing targetId and
    // resetting opacity. Stored so a new trace (or instant clear) can
    // pre-empt one already in flight.
    @ObservationIgnored private var fadeTask: Task<Void, Never>?

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
        fadeTask?.cancel()
        fadeTask = nil
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
        fadeTask?.cancel()
        fadeTask = nil
        opacity = 1.0
        targetId = nil
    }

    // Animate the trace to invisible over 2s, then drop the target.
    // Holding targetId in place during the fade keeps litSkillIds non-
    // empty so the gold overlay has something to multiply opacity
    // against. Re-entrant: if a fade is already in flight, leave it.
    //
    // Manual frame-by-frame ticking rather than withAnimation because
    // SwiftUI's animation system interpolates animatable view modifiers
    // (.opacity, .scale, etc.) but a plain value read inside Canvas's
    // content closure isn't one of those — withAnimation would snap the
    // value to 0 in a single body re-eval and the chain would vanish
    // instantly. (Same constraint drives SkyView.animateFocus.)
    func beginFadeOut() {
        guard targetId != nil, fadeTask == nil else { return }
        let duration: TimeInterval = 2.0
        let frameInterval: UInt64 = 16_666_667  // ~60Hz, nanoseconds
        let startTime = Date.now
        fadeTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date.now.timeIntervalSince(startTime)
                if elapsed >= duration {
                    opacity = 0
                    break
                }
                let t = elapsed / duration
                // easeOut quadratic: 1 - (1 - t)^2
                let eased = 1 - (1 - t) * (1 - t)
                opacity = 1.0 - eased
                try? await Task.sleep(nanoseconds: frameInterval)
            }
            if Task.isCancelled { return }
            targetId = nil
            opacity = 1.0
            fadeTask = nil
        }
    }
}

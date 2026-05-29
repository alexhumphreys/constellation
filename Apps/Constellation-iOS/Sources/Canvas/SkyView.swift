import ConstellationCore
import SwiftUI
import UIKit

// The constellation canvas. Uses SwiftUI Canvas (declarative drawing
// API) rather than a ZStack of Circle views because we want to render
// ~50 stars + their prereq edges + glows at 60fps during pinch-zoom on
// a phone. Hit testing is done in screen space inside `.onTapGesture`,
// so we don't pay the cost of a per-star tappable view.
//
// Coordinate spaces:
//   - "world" = the 2400x1600 virtual sky the seed positions are in.
//   - "screen" = the view's local coords (origin top-left).
// Conversion: screen = world * scale + offset.
// Where the canvas should center + zoom to on first appear. `.all`
// fits the whole virtual sky (good on iPad's regular width). `.area`
// fits the bounding box of one cluster + padding (used on iPhone, so
// the canvas opens already-readable on the cluster the user actually
// cares about instead of dropping them into a 4-galaxy soup).
enum InitialFocus: Equatable {
    case all
    case area(AreaID)
}

// A request from the parent to recenter the canvas on a particular
// skill. preserveScale=true skips the "snap zoom up to at least 1.0"
// step that AddSheet/Search rely on — used for tap-driven recenters
// where the user already sees the star and shouldn't see the camera
// scale-jump on top of the translate.
struct FocusRequest: Equatable {
    let skillId: SkillID
    let preserveScale: Bool

    init(skillId: SkillID, preserveScale: Bool = false) {
        self.skillId = skillId
        self.preserveScale = preserveScale
    }
}

struct SkyView: View {
    let skills: [Skill]
    let areas: [Area]
    let initialFocus: InitialFocus
    // Skills participating in the active chain-trace overlay. Empty when
    // no trace is on. Used purely for rendering — the canvas doesn't
    // own the chain state, it just highlights what the parent supplies.
    let chainSkillIds: Set<SkillID>
    // Multiplier applied to the chain highlight color alphas. 1.0 =
    // fully on; 0.0 = invisible (and the underlying normal edges show
    // through). The parent uses this to fade the trace out smoothly
    // on canvas gestures instead of dropping it instantly.
    let chainHighlightOpacity: Double
    // Per-skill newest-N attachments (N=5), newest-first. Skills without
    // attachments are absent from the dict. Each petal is gated on its
    // own LOD band (see petalLODBands) so the bloom progressively
    // reveals as the user zooms in — petal 0 fades in at 1.2→1.6 (the
    // original single-moon behavior), each subsequent petal earns its
    // own higher zoom band.
    let coversBySkillId: [SkillID: [AttachmentCover]]
    // Total attachment count per skill — drives the "+K more" badge on
    // the 5th petal when the skill has more attachments than fit in
    // the bloom. Absent for skills with no attachments.
    let attachmentCountsBySkillId: [SkillID: Int]
    let coverCache: CoverCache
    let stripCache: StripCache
    let store: Store
    let onMutation: () -> Void
    // Fired on the first tick of any user-driven pan/pinch on the
    // canvas. The parent uses this to dismiss transient overlays
    // (e.g. the chain trace) so they don't outlive the context that
    // explains them.
    let onCanvasGesture: () -> Void
    // Fired when the user taps an attachment petal in a star's bloom.
    // The host selects the skill (opening its inspector) and asks the
    // inspector to open that attachment's fullscreen viewer.
    let onOpenAttachment: (SkillID, AttachmentID) -> Void
    @Binding var selectedSkillId: SkillID?
    // When set, pan/zoom to that skill and clear the binding. Lets the
    // parent ask the canvas to recenter on a target after a state change
    // (e.g. focusing a freshly-added skill so it doesn't get lost at
    // whatever zoom the user was at).
    @Binding var focusRequest: FocusRequest?
    // Fraction of viewport height to use as the target vertical center
    // when focusing on a skill. 0.5 = dead center. iPhone passes 0.25
    // so the focused star lands in the upper half — the part not
    // covered by the medium-detent inspector sheet.
    let focusVerticalBias: CGFloat
    // Width (points) of a trailing-edge inspector covering the canvas
    // (the iPad side inspector); 0 on iPhone, where the inspector is a
    // bottom sheet handled by focusVerticalBias instead. Shifts focus
    // pans left so the targeted star lands in the visible region rather
    // than behind the inspector.
    let focusTrailingInset: CGFloat
    // Multi-select state. In select mode, tap toggles a star's id
    // in/out of `multiSelectedIds` instead of opening the inspector,
    // and long-press-drag on a selected star moves the whole group
    // rigidly (every selected star's position override picks up the
    // same world-delta).
    let isSelectMode: Bool
    @Binding var multiSelectedIds: Set<SkillID>

    init(
        skills: [Skill],
        areas: [Area],
        initialFocus: InitialFocus = .all,
        chainSkillIds: Set<SkillID> = [],
        chainHighlightOpacity: Double = 1.0,
        coversBySkillId: [SkillID: [AttachmentCover]] = [:],
        attachmentCountsBySkillId: [SkillID: Int] = [:],
        coverCache: CoverCache,
        stripCache: StripCache,
        store: Store,
        onMutation: @escaping () -> Void,
        selectedSkillId: Binding<SkillID?>,
        focusRequest: Binding<FocusRequest?> = .constant(nil),
        focusVerticalBias: CGFloat = 0.5,
        focusTrailingInset: CGFloat = 0,
        isSelectMode: Bool = false,
        multiSelectedIds: Binding<Set<SkillID>> = .constant([]),
        onCanvasGesture: @escaping () -> Void = {},
        onOpenAttachment: @escaping (SkillID, AttachmentID) -> Void = { _, _ in }
    ) {
        self.skills = skills
        self.areas = areas
        self.initialFocus = initialFocus
        self.chainSkillIds = chainSkillIds
        self.chainHighlightOpacity = chainHighlightOpacity
        self.coversBySkillId = coversBySkillId
        self.attachmentCountsBySkillId = attachmentCountsBySkillId
        self.coverCache = coverCache
        self.stripCache = stripCache
        self.store = store
        self.onMutation = onMutation
        self._selectedSkillId = selectedSkillId
        self._focusRequest = focusRequest
        self.focusVerticalBias = focusVerticalBias
        self.focusTrailingInset = focusTrailingInset
        self.isSelectMode = isSelectMode
        self._multiSelectedIds = multiSelectedIds
        self.onCanvasGesture = onCanvasGesture
        self.onOpenAttachment = onOpenAttachment
    }

    // Canvas transform. Mutated directly by CanvasGestureSurface as
    // pan/pinch tick, so there's no separate "in-flight delta" state
    // to compose — the UIKit gestures already give us per-tick deltas
    // we can apply incrementally.
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 0.5
    // Pan-only mirror of `offset` used to position the parallax
    // background. Updated by pan ticks and by programmatic camera
    // moves (fit / reset / focus animation), but deliberately *not*
    // updated by pinch — so the dampened-zoom jump during pinches is
    // gone and the background sits still under a pure scale change.
    @State private var bgPan: CGSize = .zero

    @State private var didFit: Bool = false

    // Drag state, unified across single + group. `dragBaselines` is
    // populated while a finger is on the canvas: one entry for a
    // single-star drag (baseline = anchor world, so baseline + delta
    // tracks the finger), or one per selected star for a group drag
    // (baselines preserve relative offsets so the cluster moves
    // rigidly). Cleared on touch lift.
    @State private var dragBaselines: [SkillID: CGPoint] = [:]
    @State private var dragAnchorWorld: CGPoint = .zero
    @State private var dragDelta: CGSize = .zero

    // Committed-but-not-yet-reloaded positions. Set in endDrag right
    // after the live drag state clears, held through the async upsert
    // + parent reload so the canvas doesn't flicker back to the stale
    // `skill.x/y` between the finger lifting and the new data
    // propagating. Cleared by `.onChange(of: skills)`.
    @State private var positionOverrides: [SkillID: CGPoint] = [:]

    // Drives the focus pan/zoom animation. A fresh focus request pre-empts
    // one already in flight (animate cancels prior), and the gesture
    // surface cancels it the moment the user touches the canvas (their
    // input should always win over a queued camera move).
    @State private var focusAnimator = CanvasValueAnimator()

    // Drives the star-flick glide (see endDrag). Reuses the eased
    // frame-ticker; flickActive guards the settle-on-completion path so
    // an interrupting gesture can commit the star where it currently is.
    @State private var flickAnimator = CanvasValueAnimator()
    @State private var flickActive = false

    // Freeform lasso path (screen coords), populated while a one-finger
    // drag is in progress in select mode. Drawn on top of the canvas;
    // on release the enclosed stars are unioned into multiSelectedIds.
    @State private var lassoPoints: [CGPoint] = []

    // Cluster spread (expand / tighten the selection around its
    // centroid). Driven by holding one of the floating centroid
    // handles: a timer ramps a uniform scale of the selected stars
    // about `spreadCentroid` (captured in world space at press, fixed
    // for the hold since a uniform scale leaves the centroid put);
    // release commits via the same batched upsert path as drag/flick.
    private enum SpreadDirection { case expand, tighten }
    @State private var activeSpread: SpreadDirection? = nil
    @State private var spreadTimer: Timer? = nil
    @State private var spreadCentroid: CGPoint = .zero
    @State private var spreadHaptics = UIImpactFeedbackGenerator(style: .soft)
    @State private var lastSpreadHaptic: CFTimeInterval = 0
    // Felt-tuned: fraction the cluster radius grows/shrinks per second
    // while a handle is held. Tighten won't collapse below spreadMinRadius
    // so the stars can't all crush onto the centroid.
    private static let spreadRatePerSec: CGFloat = 0.6
    private static let spreadMinRadius: CGFloat = 15
    // Haptics ratchet while spreading. Single flag to disable; iPhone-
    // only (iPad has no Taptic Engine → no-op) and silent in the sim.
    private static let spreadHapticsEnabled = true
    private static let spreadHapticInterval: CFTimeInterval = 0.07

    // Passed to SkyBloom for petal sizing — iPad's regular width earns a
    // bigger bloom at peak zoom (see SkyBloom.peakPetalSize).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let world = CGSize(width: 2400, height: 1600)
    // Upper bound is deliberately past SkyBloom.bloomPeakScale (8.0): the
    // bloom's petal size + ring radius cap at that scale, so any zoom
    // beyond it spreads neighbouring stars apart on screen *without*
    // growing their petals — letting the user dolly past two close
    // stars whose blooms overlap until each bloom stands alone. Below
    // ~bloomPeakScale, overlapping petals still resolve to the nearest
    // one on tap (see SkyBloom.hitTest).
    private let zoomBounds: ClosedRange<CGFloat> = 0.15...16.00

    // --- Star flick (flick a star and let it glide to a stop) ---------
    // Single toggle: set `starFlickEnabled = false` to disable and the
    // drag reverts to snap-on-lift (everything below the flag goes
    // inert). The glide is screen-space-consistent: a given flick speed
    // travels the same on-screen distance at any zoom.
    private static let starFlickEnabled = true
    // World-space speeds (px/s at zoom 1). Felt-tuned starting points.
    private static let flickMinSpeed: CGFloat = 220     // below → no glide
    private static let flickStopSpeed: CGFloat = 70     // glide ends here
    // Per-second velocity retention; -ln gives the decay rate, so 0.05 ⇒
    // ~0.33s time-constant. Lower = shorter glide.
    private static let flickRetentionPerSec: CGFloat = 0.05
    private static let flickMaxDuration: TimeInterval = 1.0

    // Bloom geometry + drawing live in SkyBloom.swift; the body calls
    // SkyBloom.draw for the petal pass.

    var body: some View {
        GeometryReader { geo in
            let transform = effectiveTransform
            let visibleSkillsById = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
            let areaTints = Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0.color) })

            // Main canvas is wrapped in a 2Hz TimelineView so the cover
            // bloom can swap a video petal's static thumb for its current
            // strip frame inline — keeping video petals on the same
            // z-layer as photo petals (below labels). Cost is negligible
            // (the canvas redrew at 60Hz under gesture anyway; 2Hz when
            // idle is nothing).
            TimelineView(.periodic(from: .now, by: SkyBloom.stripFrameInterval)) { timeline in
            Canvas { context, size in
                // Solid background fill — the radial-gradient sky is a
                // future polish item; the flat dark color reads almost
                // identically at the device sizes we care about.
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Theme.Sky.bg1)
                )

                // Faint background star field. Deterministic positions
                // (seeded once) and rendered with a *fixed* scale and a
                // dampened pan offset — dots don't change size with
                // zoom (true infinity-distance metaphor) but still
                // drift at 40% of the foreground when panning, so
                // depth-on-pan reads while pinches no longer cause the
                // field to jump. The seeded region overshoots world
                // bounds so the screen stays covered at extreme pan.
                let bgScale: CGFloat = 0.7
                let bgOffsetX = bgPan.width * 0.4
                let bgOffsetY = bgPan.height * 0.4
                for dot in Self.bgDots {
                    let px = dot.x * bgScale + bgOffsetX
                    let py = dot.y * bgScale + bgOffsetY
                    if px < -2 || py < -2 || px > size.width + 2 || py > size.height + 2 {
                        continue
                    }
                    let r = dot.r
                    let rect = CGRect(
                        x: px - r, y: py - r, width: r * 2, height: r * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Theme.Sky.star.opacity(dot.alpha))
                    )
                }

                // Prereq edges first so stars sit on top. While
                // a star is being dragged, both endpoints of any
                // edge it touches need to use the override world
                // position so the wires follow the star.
                for skill in skills {
                    let toWorld = worldPosition(of: skill)
                    let to = transform.apply(toWorld.x, toWorld.y)
                    for prereqId in skill.prereqIds {
                        guard let prereq = visibleSkillsById[prereqId] else {
                            continue
                        }
                        let fromWorld = worldPosition(of: prereq)
                        let from = transform.apply(fromWorld.x, fromWorld.y)
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        // Always render the normal edge underneath so
                        // it shows through as the gold chain overlay
                        // fades out on canvas gesture.
                        context.stroke(
                            path,
                            with: .color(Theme.Sky.star.opacity(
                                opacityForEdge(skill: skill, prereq: prereq))),
                            lineWidth: 0.8
                        )
                        let inChain = chainSkillIds.contains(skill.id)
                            && chainSkillIds.contains(prereq.id)
                        if inChain && chainHighlightOpacity > 0 {
                            // Soft halo + bright core = "glowing arc"
                            // through the traced chain. Wide strokes
                            // cover the underlying grey at full opacity.
                            context.stroke(
                                path,
                                with: .color(Theme.Sky.chain.opacity(0.22 * chainHighlightOpacity)),
                                lineWidth: 4
                            )
                            context.stroke(
                                path,
                                with: .color(Theme.Sky.chain.opacity(0.90 * chainHighlightOpacity)),
                                lineWidth: 1.6
                            )
                        }
                    }
                    // Soft prereqs — dashed. Kept dashed when lit by an
                    // active chain trace so hard vs soft stays legible,
                    // but bumped to the gold halo so the arc doesn't
                    // dead-end at a soft link.
                    for prereqId in skill.softPrereqIds {
                        guard let prereq = visibleSkillsById[prereqId] else {
                            continue
                        }
                        let fromWorld = worldPosition(of: prereq)
                        let from = transform.apply(fromWorld.x, fromWorld.y)
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        // Always render the faint dashed soft edge
                        // underneath so it shows through as the gold
                        // chain overlay fades out on canvas gesture.
                        // Dialed up from the original 0.06 so the soft
                        // graph is actually decodable on the canvas
                        // (was almost invisible at default zoom). Dash
                        // kept tight so it still reads as "lighter"
                        // next to a hard edge.
                        let isAdjacent = selectedSkillId == skill.id
                            || selectedSkillId == prereq.id
                        let softAlpha = isAdjacent ? 0.40 : 0.14
                        context.stroke(
                            path,
                            with: .color(Theme.Sky.star.opacity(softAlpha)),
                            style: StrokeStyle(lineWidth: 0.7, dash: [2.5, 3.5])
                        )
                        let inChain = chainSkillIds.contains(skill.id)
                            && chainSkillIds.contains(prereq.id)
                        if inChain && chainHighlightOpacity > 0 {
                            context.stroke(
                                path,
                                with: .color(Theme.Sky.chain.opacity(0.22 * chainHighlightOpacity)),
                                style: StrokeStyle(lineWidth: 4, dash: [6, 4])
                            )
                            context.stroke(
                                path,
                                with: .color(Theme.Sky.chain.opacity(0.90 * chainHighlightOpacity)),
                                style: StrokeStyle(lineWidth: 1.6, dash: [3, 3])
                            )
                        }
                    }
                }

                // Stars on top.
                for skill in skills {
                    let w = worldPosition(of: skill)
                    let p = transform.apply(w.x, w.y)
                    let visual = StatusVisual.of(skill.status)
                    let tint = areaTints[skill.areaId] ?? .gray
                    let inChain = chainSkillIds.contains(skill.id)
                    // Skills along an active chain trace stay bright
                    // even when another star is selected — otherwise
                    // the arc would dim out from under the user.
                    let dim = selectedSkillId != nil
                        && selectedSkillId != skill.id
                        && !inChain
                    let opacity = dim ? min(0.3, visual.opacity * 0.35) : visual.opacity

                    // Hobby-tint halo
                    if visual.glow > 0 {
                        let glowRect = CGRect(
                            x: p.x - visual.glow, y: p.y - visual.glow,
                            width: visual.glow * 2, height: visual.glow * 2
                        )
                        context.fill(
                            Path(ellipseIn: glowRect),
                            with: .color(tint.opacity(0.18 * opacity))
                        )
                    }

                    // Star core
                    if skill.status == .locked {
                        // Locked = dashed outlined circle, no fill.
                        let r = visual.size
                        let rect = CGRect(
                            x: p.x - r, y: p.y - r, width: r * 2, height: r * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rect),
                            with: .color(Theme.Sky.starDim.opacity(opacity)),
                            style: StrokeStyle(lineWidth: 0.8, dash: [1.5, 2])
                        )
                    } else {
                        let r = visual.size
                        let rect = CGRect(
                            x: p.x - r, y: p.y - r, width: r * 2, height: r * 2
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(Theme.Sky.star.opacity(opacity))
                        )
                    }

                    // Next-up dashed ring (subtle "you could try this" cue).
                    if visual.ring == .dashed {
                        let r = visual.size + 5
                        let rect = CGRect(
                            x: p.x - r, y: p.y - r, width: r * 2, height: r * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rect),
                            with: .color(Theme.Sky.star.opacity(opacity * 0.7)),
                            style: StrokeStyle(lineWidth: 0.8, dash: [2, 3])
                        )
                    }

                    // Drill = solid bright ring in the area tint. Reads
                    // as "this is the live one." The expanding pulse
                    // halo on top is drawn by the TimelineView overlay
                    // below — kept separate so only the animated layer
                    // redraws per frame and the heavy main canvas stays
                    // static between gesture/state changes.
                    if visual.ring == .pulse {
                        let r = visual.size + 4
                        let rect = CGRect(
                            x: p.x - r, y: p.y - r, width: r * 2, height: r * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rect),
                            with: .color(tint.opacity(opacity * 0.95)),
                            lineWidth: 1.4
                        )
                    }

                    // Multi-select ring: gold halo + solid inner ring,
                    // distinct from the single-select treatment so a
                    // selection of one star (in select mode) still
                    // reads as "selected for group ops" rather than
                    // "open in the inspector".
                    if multiSelectedIds.contains(skill.id) {
                        let r1 = visual.size + 8
                        let rect1 = CGRect(
                            x: p.x - r1, y: p.y - r1,
                            width: r1 * 2, height: r1 * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rect1),
                            with: .color(Theme.Sky.chain),
                            lineWidth: 2.0
                        )
                        let r2 = visual.size + 13
                        let rect2 = CGRect(
                            x: p.x - r2, y: p.y - r2,
                            width: r2 * 2, height: r2 * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rect2),
                            with: .color(Theme.Sky.chain.opacity(0.35)),
                            lineWidth: 1.0
                        )
                    }

                    // Selection ring on the focused star — uses the area
                    // tint at full saturation plus a faint outer dashed
                    // halo, matching the SkyNode design.
                    if selectedSkillId == skill.id {
                        let r1 = visual.size + 10
                        let rect1 = CGRect(
                            x: p.x - r1, y: p.y - r1, width: r1 * 2, height: r1 * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rect1),
                            with: .color(tint),
                            lineWidth: 1.6
                        )
                        let r2 = visual.size + 14
                        let rect2 = CGRect(
                            x: p.x - r2, y: p.y - r2, width: r2 * 2, height: r2 * 2
                        )
                        context.stroke(
                            Path(ellipseIn: rect2),
                            with: .color(Theme.Sky.star.opacity(0.5)),
                            style: StrokeStyle(lineWidth: 0.6, dash: [2, 3])
                        )
                    }
                }

                // Cover bloom: the ring of attachment thumbnails that
                // fans out around each star as the user zooms in (LOD-
                // gated petals, video strip cycling, +K badge). Geometry
                // and drawing live in SkyBloom; the worldPosition closure
                // folds in any in-flight drag so petals track a dragged
                // star, and timeline.date drives the video frame index.
                SkyBloom.draw(
                    into: &context,
                    skills: skills,
                    transform: transform,
                    coversBySkillId: coversBySkillId,
                    attachmentCountsBySkillId: attachmentCountsBySkillId,
                    coverCache: coverCache,
                    stripCache: stripCache,
                    timelineDate: timeline.date,
                    regularWidth: horizontalSizeClass == .regular,
                    worldPosition: { worldPosition(of: $0) }
                )

                // Labels. Smart density: always label foundations,
                // drilling stars, the currently selected/neighbour set;
                // hide everything else when zoomed out so the canvas
                // doesn't read as soup.
                //
                // Each label gets a thin scrim behind the text so it
                // stays readable when it overlaps a prereq edge or
                // another star's glow. Without it, 12pt serif on dark
                // sky melts into anything bright passing underneath.
                for skill in skills where shouldLabel(skill, scale: transform.scale) {
                    let w = worldPosition(of: skill)
                    let p = transform.apply(w.x, w.y)
                    let visual = StatusVisual.of(skill.status)
                    let text = Text(skill.name)
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(Theme.Sky.star)
                    let resolved = context.resolve(text)
                    let textSize = resolved.measure(in: CGSize(width: 220, height: 40))
                    let origin = CGPoint(x: p.x + visual.size + 6, y: p.y)
                    let scrimRect = CGRect(
                        x: origin.x - 3,
                        y: origin.y - textSize.height / 2 - 1,
                        width: textSize.width + 6,
                        height: textSize.height + 2
                    )
                    context.fill(
                        Path(roundedRect: scrimRect, cornerRadius: 3),
                        with: .color(Theme.Sky.bg1.opacity(0.55))
                    )
                    context.draw(resolved, at: origin, anchor: .leading)
                }

                // Lasso overlay (select mode): the freeform selection
                // path in screen space, drawn on top of everything. Gold
                // to match the multi-select ring — faint fill so the
                // enclosed region reads as "about to be selected",
                // brighter stroke for the edge being traced.
                if lassoPoints.count > 1 {
                    var path = Path()
                    path.move(to: lassoPoints[0])
                    for pt in lassoPoints.dropFirst() { path.addLine(to: pt) }
                    path.closeSubpath()
                    context.fill(path, with: .color(Theme.Sky.chain.opacity(0.10)))
                    context.stroke(
                        path,
                        with: .color(Theme.Sky.chain.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                    )
                }
            }
            }  // closes TimelineView wrapping the main Canvas
            .overlay {
                // Drill pulse overlay. Separate Canvas wrapped in
                // TimelineView so only the pulse rings redraw at 60fps;
                // the main canvas above stays static unless gesture or
                // selection state changes. Hit-testing disabled so taps
                // pass through to the gesture surface below.
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    Canvas { context, _ in
                        let drillIds: Set<SkillID> = Set(skills.compactMap {
                            $0.status == .drill ? $0.id : nil
                        })
                        if drillIds.isEmpty { return }
                        let period: Double = 2.8
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        let phase = (now.truncatingRemainder(dividingBy: period)) / period
                        // Half-sine envelope — eases in from 0, peaks at
                        // mid-cycle, eases back to 0. No pop at the
                        // wrap-around, so the breath reads as one slow
                        // gentle rhythm instead of a hard reset.
                        let envelope = sin(phase * .pi)
                        let byId = Dictionary(
                            uniqueKeysWithValues: skills.map { ($0.id, $0) }
                        )

                        // Edge pulse first so star pulse layers on top.
                        // Additive over the static edges in the main
                        // canvas — alpha tracks the same envelope the
                        // ring uses so the drill star and its
                        // connections breathe in unison.
                        let edgeAlpha = 0.22 * envelope
                        if edgeAlpha > 0.01 {
                            for skill in skills {
                                let skillIsDrill = drillIds.contains(skill.id)
                                for prereqId in skill.prereqIds {
                                    guard skillIsDrill || drillIds.contains(prereqId),
                                          let prereq = byId[prereqId] else { continue }
                                    let drillEnd = skillIsDrill ? skill : prereq
                                    let tint = areaTints[drillEnd.areaId] ?? .gray
                                    let fromW = worldPosition(of: prereq)
                                    let toW = worldPosition(of: skill)
                                    var path = Path()
                                    path.move(to: transform.apply(fromW.x, fromW.y))
                                    path.addLine(to: transform.apply(toW.x, toW.y))
                                    context.stroke(
                                        path,
                                        with: .color(tint.opacity(edgeAlpha)),
                                        lineWidth: 1.0
                                    )
                                }
                                for prereqId in skill.softPrereqIds {
                                    guard skillIsDrill || drillIds.contains(prereqId),
                                          let prereq = byId[prereqId] else { continue }
                                    let drillEnd = skillIsDrill ? skill : prereq
                                    let tint = areaTints[drillEnd.areaId] ?? .gray
                                    let fromW = worldPosition(of: prereq)
                                    let toW = worldPosition(of: skill)
                                    var path = Path()
                                    path.move(to: transform.apply(fromW.x, fromW.y))
                                    path.addLine(to: transform.apply(toW.x, toW.y))
                                    context.stroke(
                                        path,
                                        with: .color(tint.opacity(edgeAlpha * 0.75)),
                                        style: StrokeStyle(
                                            lineWidth: 0.9,
                                            dash: [2.5, 3.5]
                                        )
                                    )
                                }
                            }
                        }

                        for skill in skills where skill.status == .drill {
                            let w = worldPosition(of: skill)
                            let p = transform.apply(w.x, w.y)
                            let visual = StatusVisual.of(skill.status)
                            let tint = areaTints[skill.areaId] ?? .gray
                            let inChain = chainSkillIds.contains(skill.id)
                            let dim = selectedSkillId != nil
                                && selectedSkillId != skill.id
                                && !inChain
                            let baseOpacity = dim
                                ? min(0.3, visual.opacity * 0.35)
                                : visual.opacity
                            // Ring grows from the static-ring radius
                            // outward, fading in and out on the same
                            // half-sine envelope as the edges — reads
                            // as the star "breathing" into the
                            // surrounding sky.
                            let r = visual.size + 4 + 8 * phase
                            let alpha = baseOpacity * 0.5 * envelope
                            let rect = CGRect(
                                x: p.x - r, y: p.y - r,
                                width: r * 2, height: r * 2
                            )
                            context.stroke(
                                Path(ellipseIn: rect),
                                with: .color(tint.opacity(alpha)),
                                lineWidth: 1.2
                            )
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(
                CanvasGestureSurface(
                    offset: $offset,
                    scale: $scale,
                    bgPan: $bgPan,
                    zoomBounds: zoomBounds,
                    onTap: { location in
                        handleTap(at: location, in: geo.size, transform: transform)
                    },
                    onDragBegan: { location in
                        beginDrag(at: location, transform: transform)
                    },
                    onDragChanged: { location in
                        updateDrag(at: location)
                    },
                    onDragEnded: { velocity in
                        endDrag(screenVelocity: velocity)
                    },
                    onCanvasGestureBegan: {
                        // User grabbed the canvas — abort any focus pan
                        // already in flight so they're not fighting a
                        // queued camera move with their fingers, and
                        // commit any star still gliding from a flick.
                        focusAnimator.cancel()
                        cancelFlick()
                        onCanvasGesture()
                    },
                    isSelectMode: isSelectMode,
                    onLassoChanged: { lassoPoints = $0 },
                    onLassoEnded: { finishLasso($0) }
                )
            )
            .overlay(alignment: .bottomTrailing) {
                resetButton(into: geo.size)
            }
            // Floating expand/tighten handles at the selection centroid.
            // Layered above the gesture surface (like the reset button)
            // so the holds hit-test before the canvas pan/lasso; the
            // empty regions of the overlay stay touch-transparent.
            .overlay {
                spreadControls()
            }
            .onAppear { fitIfNeeded(into: geo.size) }
            .onChange(of: geo.size) { _, newSize in
                fitIfNeeded(into: newSize)
            }
            // Skills load asynchronously via the parent's .task — on
            // first appear `skills` is still empty, so we defer the
            // initial fit until the data arrives. `initialFocus`
            // changes don't re-fit once the user has already seen the
            // canvas (we'd otherwise yank them back to the cluster
            // every time they pan and the parent recomputes the focus).
            .onChange(of: skills.count) { _, _ in
                fitIfNeeded(into: geo.size)
                // Retry a pending focus once the new skill lands in
                // `skills` — the parent often sets focusRequest in the
                // same tick as it bumps the reload token, so the first
                // attempt below misses (the new skill isn't here yet).
                if let req = focusRequest {
                    tryFocusOnSkill(req, into: geo.size)
                }
            }
            // Drop the committed drag overrides once the parent's
            // reload has propagated new x/y into `skills`. Only fires
            // when no finger is on the canvas (dragBaselines empty),
            // so a peer-sync reload mid-drag can't yank the overrides
            // out from under a live gesture.
            .onChange(of: skills) { _, _ in
                if dragBaselines.isEmpty, !positionOverrides.isEmpty {
                    positionOverrides = [:]
                }
            }
            // External pan/zoom request: focus on a target skill, then
            // clear the binding so the same skill can be re-targeted
            // later. Animates so the user sees the canvas move toward
            // the new star instead of teleporting under the inspector.
            // If the skill isn't in the slice yet (parent reload in
            // flight), leave the binding set — the .onChange(of:
            // skills.count) above will retry once it arrives.
            .onChange(of: focusRequest) { _, newValue in
                guard let req = newValue else { return }
                tryFocusOnSkill(req, into: geo.size)
            }
        }
    }

    // MARK: - Transform composition

    private var effectiveTransform: CanvasTransform {
        CanvasTransform(
            scale: scale,
            offsetX: offset.width,
            offsetY: offset.height
        )
    }

    // MARK: - Initial focus

    // Idempotent fit-on-load. We can't fit during the very first
    // onAppear because skills is still []; we can't fit after the
    // user has interacted because that would override their pan/zoom.
    // So: fit exactly once, the first time we see both a non-empty
    // skill set and a real geometry.
    private func fitIfNeeded(into size: CGSize) {
        guard !didFit, !skills.isEmpty, size.width > 0, size.height > 0 else {
            return
        }
        applyInitialFocus(into: size)
        didFit = true
    }

    private func applyInitialFocus(into size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        switch initialFocus {
        case .all:
            fitToBox(.init(x: 0, y: 0, width: world.width, height: world.height),
                     padding: 60, into: size)
        case .area(let areaId):
            focusOnCluster(areaId: areaId, into: size)
        }
    }

    // Cluster focus is intentionally NOT a plain fit-to-bbox. Wide
    // clusters like cali (1000 world-units wide × 200 tall) would
    // fit-to-viewport at min zoom, leaving acres of vertical empty
    // space that the *next-door* cluster leaks into — defeating the
    // whole "land readable on one cluster" goal.
    //
    // Compromise: position by the area's defined center (matches the
    // design's CLUSTER_CENTERS) and pick a zoom that *would* fit the
    // bbox into 85% of the viewport, but never below 0.60 so we
    // always end up demonstrably zoomed-in. User can pan/pinch from
    // there to reach the rest of the sky.
    private func focusOnCluster(areaId: AreaID, into size: CGSize) {
        let areaSkills = skills.filter { $0.areaId == areaId }
        guard !areaSkills.isEmpty else {
            fitToBox(.init(x: 0, y: 0, width: world.width, height: world.height),
                     padding: 60, into: size)
            return
        }
        let area = areas.first { $0.id == areaId }
        let xs = areaSkills.map(\.x)
        let ys = areaSkills.map(\.y)
        // Cast the world-space bbox dimensions to CGFloat — skill
        // positions are Double in the model, viewport sizes are
        // CGFloat in SwiftUI, and the Swift overload resolver hates
        // mixing the two without an explicit conversion (CGFloat is a
        // typealias for Double on 64-bit but the type system treats
        // them as distinct for method dispatch).
        let bboxW = CGFloat(max((xs.max() ?? 0) - (xs.min() ?? 0), 200))
        let bboxH = CGFloat(max((ys.max() ?? 0) - (ys.min() ?? 0), 200))
        // Centroid of the live cluster — `Area.liveCenter` falls back
        // to the stored centerX/centerY when the area has no skills,
        // but the early-return above means we always have at least one
        // here, so this is effectively the rolling cluster center.
        let center = area?.liveCenter(in: skills)
            ?? (x: xs.reduce(0, +) / Double(xs.count),
                y: ys.reduce(0, +) / Double(ys.count))
        setCamera(CanvasCamera.focusCluster(
            bboxW: bboxW,
            bboxH: bboxH,
            center: CGPoint(x: center.x, y: center.y),
            into: size,
            minScale: 0.60,
            zoomBounds: zoomBounds
        ))
    }

    // MARK: - Reset view

    // Bottom-trailing affordance to fit-all the virtual sky again after
    // pan/zoom. Layered on top of the gesture surface (SwiftUI hit-tests
    // overlays before their backing views, so the button consumes taps
    // without leaking them through to UIPan/UITap below).
    @ViewBuilder
    private func resetButton(into size: CGSize) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                fitToBox(
                    .init(x: 0, y: 0, width: world.width, height: world.height),
                    padding: 60, into: size
                )
            }
        } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(.black.opacity(0.30))
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset view")
        .padding(.trailing, 16)
        .padding(.bottom, 24)
    }

    // Pan + zoom so the target skill lands at viewport center. Floor the
    // zoom at 1.0 so the new star is comfortably readable; if the user
    // was already zoomed in further, leave their zoom alone.
    //
    // Returns silently if the skill isn't in the slice yet — the caller
    // re-tries via .onChange(of: skills.count) once the reload that
    // produced this skill propagates down. Clearing the binding here
    // (rather than at the call site) ensures we only clear once the
    // animation actually ran.
    private func tryFocusOnSkill(_ request: FocusRequest, into size: CGSize) {
        guard let skill = skills.first(where: { $0.id == request.skillId }) else { return }
        // preserveScale=true: tap-driven recenter where the user already
        // sees the star — only translate, don't surprise them with a
        // scale change. Otherwise (AddSheet/Search) ensure zoom is at
        // least 1.0 so the focused star is readable even if the user
        // was previously zoomed all the way out.
        let targetScale: CGFloat = request.preserveScale
            ? scale
            : max(CGFloat(1.0), scale).zoomClamped(to: zoomBounds)
        let target = CanvasCamera.focusPoint(
            worldPoint: CGPoint(x: skill.x, y: skill.y),
            scale: targetScale,
            into: size,
            verticalBias: focusVerticalBias,
            trailingInset: focusTrailingInset
        )
        animateFocus(to: target)
        focusRequest = nil
    }

    // Lerp scale + offset to the target over 0.3s. Driven by
    // CanvasValueAnimator (frame-by-frame) rather than withAnimation,
    // which interpolates animatable view modifiers, not values read
    // inside a Canvas content closure — withAnimation would snap the
    // transform in a single body re-eval and the camera would *jump*.
    private func animateFocus(to target: CameraPose) {
        let start = CameraPose(scale: scale, offset: offset)
        guard start != target else {
            focusAnimator.cancel()
            return
        }
        focusAnimator.animate(
            duration: 0.3,
            easing: CanvasCamera.easeInOut,
            onFrame: { setCamera(CanvasCamera.lerp(from: start, to: target, t: $0)) }
        )
    }

    private func fitToBox(_ box: CGRect, padding: CGFloat, into size: CGSize) {
        setCamera(CanvasCamera.fit(
            box: box, padding: padding, into: size, zoomBounds: zoomBounds
        ))
    }

    // Snap the camera @State to a computed pose. bgPan mirrors offset so
    // the parallax background follows programmatic moves (it's only held
    // back during pinch — see the bgPan docs at the top of the view).
    private func setCamera(_ pose: CameraPose) {
        scale = pose.scale
        offset = pose.offset
        bgPan = pose.offset
    }

    // MARK: - Hit testing

    private func handleTap(
        at location: CGPoint, in size: CGSize, transform: CanvasTransform
    ) {
        // A tap during a glide stops it and commits, then selects as usual.
        cancelFlick()
        if isSelectMode {
            // Multi-select: tap a star toggles it in/out of the set,
            // tap empty space clears the set. Petals are inert here —
            // select mode is about choosing stars to move as a group.
            // Inspector is suppressed by the parent while this mode is
            // on so a single tap can't accidentally open it.
            if let bestId = nearestStar(at: location, transform: transform)?.id {
                if multiSelectedIds.contains(bestId) {
                    multiSelectedIds.remove(bestId)
                } else {
                    multiSelectedIds.insert(bestId)
                }
            } else {
                multiSelectedIds.removeAll()
            }
            return
        }
        // Outside select mode the bloom petals are tappable. Resolve the
        // nearest target — an attachment petal vs. the star under it (or
        // a neighbour's overlapping petal) — by finger proximity, so
        // colliding blooms from close-together stars disambiguate to
        // whatever the finger is actually on. A petal opens its skill +
        // that attachment; a star toggles its inspector.
        let petal = SkyBloom.hitTest(
            at: location,
            skills: skills,
            transform: transform,
            coversBySkillId: coversBySkillId,
            regularWidth: horizontalSizeClass == .regular,
            worldPosition: { worldPosition(of: $0) }
        )
        let star = nearestStar(at: location, transform: transform)
        if let petal, petal.dist <= (star?.dist ?? .greatestFiniteMagnitude) {
            selectedSkillId = petal.skillId
            onOpenAttachment(petal.skillId, petal.attachmentId)
            return
        }
        if let star {
            selectedSkillId = (selectedSkillId == star.id) ? nil : star.id
        } else {
            selectedSkillId = nil
        }
    }

    // Star id under the finger, ignoring distance — used by the drag
    // hit-test, which only ever grabs stars (never petals).
    private func hitTest(
        at location: CGPoint, transform: CanvasTransform
    ) -> SkillID? {
        nearestStar(at: location, transform: transform)?.id
    }

    // Linear scan over skills — N is tiny (~50). Pick the nearest star
    // within a finger-sized screen-space radius regardless of zoom (so
    // zoomed-out tiny stars are still hittable) and return its distance
    // so the tap handler can weigh it against a competing petal hit.
    private func nearestStar(
        at location: CGPoint, transform: CanvasTransform
    ) -> (id: SkillID, dist: CGFloat)? {
        var best: (id: SkillID, dist: CGFloat)?
        var bestDist: CGFloat = 40  // 40pt = comfortable finger target
        for skill in skills {
            let w = worldPosition(of: skill)
            let p = transform.apply(w.x, w.y)
            let dx = p.x - location.x, dy = p.y - location.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < bestDist {
                bestDist = dist
                best = (skill.id, dist)
            }
        }
        return best
    }

    // MARK: - Lasso select

    // On lasso release: union every visible star whose screen position
    // falls inside the traced polygon into the selection. Additive
    // (tap still toggles individuals), and a no-op for a degenerate
    // path or outside select mode. Always clears the path so the
    // overlay disappears on lift.
    private func finishLasso(_ points: [CGPoint]) {
        defer { lassoPoints = [] }
        guard isSelectMode, points.count >= 3 else { return }
        let transform = effectiveTransform
        var selected = multiSelectedIds
        for skill in skills {
            let w = worldPosition(of: skill)
            let p = transform.apply(w.x, w.y)
            if Self.pointInPolygon(p, points) {
                selected.insert(skill.id)
            }
        }
        multiSelectedIds = selected
    }

    // Even-odd ray cast: count how many polygon edges a rightward ray
    // from `p` crosses; odd = inside. Closes the polygon implicitly
    // (edge from last vertex back to first via the j/i wrap).
    private static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - Cluster spread (expand / tighten the selection)

    // Centroid of the selected stars in world space — the fixed pivot
    // for the spread scale. nil unless 3+ are selected (with 2, moving
    // one star apart is simpler than a radial scale, so the handles
    // don't appear).
    private func selectionCentroidWorld() -> CGPoint? {
        let pts = skills
            .filter { multiSelectedIds.contains($0.id) }
            .map { worldPosition(of: $0) }
        guard pts.count >= 3 else { return nil }
        let sx = pts.reduce(CGFloat(0)) { $0 + $1.x }
        let sy = pts.reduce(CGFloat(0)) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
    }

    @ViewBuilder
    private func spreadControls() -> some View {
        if isSelectMode, lassoPoints.isEmpty, dragBaselines.isEmpty,
           let centroid = selectionCentroidWorld() {
            let p = effectiveTransform.apply(centroid.x, centroid.y)
            HStack(spacing: 4) {
                spreadHandle(.tighten)
                spreadHandle(.expand)
            }
            .position(x: p.x, y: p.y)
        }
    }

    private func spreadHandle(_ dir: SpreadDirection) -> some View {
        // Small, semi-transparent badge so it doesn't loom over the
        // stars, wrapped in a 44pt touch target so it's still easy to
        // press. The visible circle is 28pt; the outer frame +
        // contentShape carry the hit area.
        Image(systemName: dir == .expand
            ? "arrow.up.left.and.arrow.down.right"
            : "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(Theme.Sky.chain.opacity(0.16))
                    .background(Circle().fill(.ultraThinMaterial.opacity(0.6)))
                    .overlay(Circle().stroke(Theme.Sky.chain.opacity(0.5), lineWidth: 0.8))
            )
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            // minimumDistance 0 makes this a press-and-hold: the first
            // change fires on touch-down (starts the ramp timer), end
            // fires on lift (commits). The timer — not this gesture —
            // drives the scaling, since a stationary finger emits no
            // further change events.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if activeSpread != dir { beginSpread(dir) } }
                    .onEnded { _ in endSpread() }
            )
            .accessibilityLabel(dir == .expand ? "Spread selection" : "Tighten selection")
    }

    private func beginSpread(_ dir: SpreadDirection) {
        guard let centroid = selectionCentroidWorld() else { return }
        activeSpread = dir
        spreadCentroid = centroid
        // Seed overrides from the stars' current positions so the scale
        // grows from where they actually are, and holds through the
        // post-commit reload (cleared by .onChange(of: skills)).
        var seed = positionOverrides
        for s in skills where multiSelectedIds.contains(s.id) {
            seed[s.id] = worldPosition(of: s)
        }
        positionOverrides = seed
        if Self.spreadHapticsEnabled {
            spreadHaptics.prepare()
            lastSpreadHaptic = 0
        }
        spreadTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            spreadTick()
        }
        // .common so it keeps firing while the finger is held down
        // (default mode pauses during UIKit touch tracking).
        RunLoop.main.add(timer, forMode: .common)
        spreadTimer = timer
    }

    private func spreadTick() {
        guard let dir = activeSpread else { return }
        let dt: CGFloat = 1.0 / 60.0
        let factor = dir == .expand
            ? 1 + Self.spreadRatePerSec * dt
            : 1 - Self.spreadRatePerSec * dt
        let c = spreadCentroid
        var next = positionOverrides
        // Tighten stops once the cluster has pulled in to the floor so
        // the stars don't all crush onto a single point.
        if dir == .tighten {
            let maxR = skills
                .filter { multiSelectedIds.contains($0.id) }
                .map { s -> CGFloat in
                    let w = next[s.id] ?? worldPosition(of: s)
                    let dx = w.x - c.x, dy = w.y - c.y
                    return (dx * dx + dy * dy).squareRoot()
                }
                .max() ?? 0
            if maxR < Self.spreadMinRadius { return }
        }
        for s in skills where multiSelectedIds.contains(s.id) {
            let w = next[s.id] ?? worldPosition(of: s)
            next[s.id] = CGPoint(
                x: c.x + (w.x - c.x) * factor,
                y: c.y + (w.y - c.y) * factor
            )
        }
        positionOverrides = next
        spreadHapticTick()
    }

    private func endSpread() {
        spreadTimer?.invalidate()
        spreadTimer = nil
        guard activeSpread != nil else { return }
        activeSpread = nil
        commitSpread()
    }

    // Persist the spread the same way settleDrag does — one upsert (and
    // one skill.upsert wide event) per moved star, serial so an inbound
    // MC merge mid-flight can't see a half-applied group. Overrides stay
    // until the reload lands.
    private func commitSpread() {
        let bySkillId = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        let now = Date()
        var updates: [Skill] = []
        for id in multiSelectedIds {
            guard var s = bySkillId[id], let pos = positionOverrides[id] else { continue }
            s.x = Double(pos.x)
            s.y = Double(pos.y)
            s.updatedAt = now
            updates.append(s)
        }
        guard !updates.isEmpty else { return }
        Task {
            for s in updates { try? await store.upsertSkill(s) }
            await MainActor.run { onMutation() }
        }
    }

    private func spreadHapticTick() {
        guard Self.spreadHapticsEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastSpreadHaptic >= Self.spreadHapticInterval else { return }
        spreadHaptics.impactOccurred(intensity: 0.6)
        spreadHaptics.prepare()
        lastSpreadHaptic = now
    }

    // MARK: - Drag-to-move

    // Render-time position. Live drag wins (baseline + delta tracks
    // the finger); falling through, a committed override held from a
    // recent drag wins over the persisted x/y so the canvas stays at
    // the drag-end position until the reload propagates. Final
    // fallback is the model's stored coords.
    private func worldPosition(of skill: Skill) -> CGPoint {
        if let base = dragBaselines[skill.id] {
            return CGPoint(
                x: base.x + dragDelta.width,
                y: base.y + dragDelta.height
            )
        }
        if let pos = positionOverrides[skill.id] {
            return pos
        }
        return CGPoint(x: skill.x, y: skill.y)
    }

    // True iff the long-press began over a star — that's the signal
    // CanvasGestureSurface uses to suppress pan for the rest of the
    // gesture. A long-press on a selected star with 2+ in the set
    // promotes to a rigid group-translate (per-star baselines preserve
    // relative offsets); everything else is a single-star drag where
    // the baseline = anchor world so the star tracks the finger.
    private func beginDrag(
        at location: CGPoint, transform: CanvasTransform
    ) -> Bool {
        // A new grab interrupts any in-flight flick — commit the gliding
        // star before this drag re-seeds the baselines.
        cancelFlick()
        guard let hit = hitTest(at: location, transform: transform) else {
            return false
        }
        let world = transform.invert(location)
        dragAnchorWorld = world
        dragDelta = .zero
        // Prefer the still-held positionOverride over the persisted
        // x/y when seeding the baseline — a re-drag on a star whose
        // previous commit hasn't been reloaded yet shouldn't snap
        // back to skill.x/y.
        func baseline(for id: SkillID, fallback: CGPoint) -> CGPoint {
            positionOverrides[id] ?? fallback
        }
        if isSelectMode,
           multiSelectedIds.contains(hit),
           multiSelectedIds.count >= 2 {
            var baselines: [SkillID: CGPoint] = [:]
            for s in skills where multiSelectedIds.contains(s.id) {
                baselines[s.id] = baseline(
                    for: s.id, fallback: CGPoint(x: s.x, y: s.y)
                )
            }
            dragBaselines = baselines
        } else {
            // Single drag: baseline = anchor world, so worldPosition
            // returns world + (current - world) = current finger
            // coord on every tick. Snaps the star under the finger
            // immediately (no one-frame visual gap).
            dragBaselines = [hit: world]
        }
        return true
    }

    private func updateDrag(at location: CGPoint) {
        guard !dragBaselines.isEmpty else { return }
        let world = effectiveTransform.invert(location)
        dragDelta = CGSize(
            width: world.x - dragAnchorWorld.x,
            height: world.y - dragAnchorWorld.y
        )
    }

    // On finger lift. With star flick off (default), settle immediately
    // (snap to a stop). With it on and the release fast enough, hand off
    // to a decaying glide first; the glide settles on completion.
    private func endDrag(screenVelocity: CGPoint) {
        guard !dragBaselines.isEmpty else { return }
        let scale = effectiveTransform.scale
        // Finger velocity in world units. glide·scale is scale-invariant,
        // so a given flick travels the same on-screen distance at any zoom.
        let worldVel = CGPoint(
            x: scale > 0 ? screenVelocity.x / scale : 0,
            y: scale > 0 ? screenVelocity.y / scale : 0
        )
        let speed = (worldVel.x * worldVel.x + worldVel.y * worldVel.y).squareRoot()
        if Self.starFlickEnabled, speed > Self.flickMinSpeed {
            startFlick(worldVelocity: worldVel, speed: speed)
        } else {
            settleDrag()
        }
    }

    // Glide the dragged star(s) on from the lift position with an
    // ease-out matched to an exponential velocity decay, then settle.
    // dragBaselines stays populated through the glide so the canvas keeps
    // rendering the moving star(s); only dragDelta animates.
    private func startFlick(worldVelocity v: CGPoint, speed: CGFloat) {
        let k = Double(Self.flickRetentionPerSec)
        let lnk = log(k)                              // negative
        let stopOverSpeed = Double(Self.flickStopSpeed / speed)
        let tStop = log(stopOverSpeed) / lnk
        let duration = min(max(tStop, 0.12), Self.flickMaxDuration)
        // Displacement of an exponentially-decaying velocity over [0,tStop]:
        //   ∫ v·k^t dt = v·(k^tStop − 1)/ln k = v·(stopSpeed/speed − 1)/ln k
        let factor = CGFloat((stopOverSpeed - 1) / lnk)
        let startDelta = dragDelta
        let endDelta = CGSize(
            width: startDelta.width + v.x * factor,
            height: startDelta.height + v.y * factor
        )
        flickActive = true
        flickAnimator.animate(
            duration: duration,
            easing: CanvasCamera.easeOut,
            onFrame: { t in
                dragDelta = CGSize(
                    width: startDelta.width + (endDelta.width - startDelta.width) * t,
                    height: startDelta.height + (endDelta.height - startDelta.height) * t
                )
            },
            onComplete: { settleDrag() }
        )
    }

    // Stop an in-flight glide and commit the star(s) wherever it reached.
    // No-op when no glide is running. Called by any gesture that should
    // interrupt the flick (a new drag, a tap, a canvas pan/pinch).
    private func cancelFlick() {
        guard flickActive else { return }
        flickAnimator.cancel()   // leaves dragDelta where it is; no onComplete
        settleDrag()
    }

    // Freeze the resolved positions into `positionOverrides` so the
    // canvas keeps drawing them at the final coords while the async
    // upsert + parent reload propagate. The overrides are cleared by
    // .onChange(of: skills) once new data lands — the only safe moment,
    // since clearing earlier would re-render against the still-stale
    // skill.x/y and pop the stars back.
    private func settleDrag() {
        let baselines = dragBaselines
        let delta = dragDelta
        dragBaselines = [:]
        dragAnchorWorld = .zero
        dragDelta = .zero
        flickActive = false
        guard !baselines.isEmpty, delta != .zero else {
            // No-movement long-press → nothing to commit; star stays
            // wherever it already was.
            return
        }
        var finals = positionOverrides
        for (id, base) in baselines {
            finals[id] = CGPoint(
                x: base.x + delta.width,
                y: base.y + delta.height
            )
        }
        positionOverrides = finals

        let bySkillId = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        let now = Date()
        var updates: [Skill] = []
        for (id, base) in baselines {
            guard var s = bySkillId[id] else { continue }
            s.x = Double(base.x + delta.width)
            s.y = Double(base.y + delta.height)
            s.updatedAt = now
            updates.append(s)
        }
        // One upsert per touched skill (one `skill.upsert` wide event
        // each — matches the wide-events-as-business-logic pattern).
        // Serial so an inbound MC merge mid-flight can't see a
        // half-applied group.
        Task {
            for s in updates {
                try? await store.upsertSkill(s)
            }
            await MainActor.run { onMutation() }
        }
    }

    // MARK: - Label density

    private func shouldLabel(_ skill: Skill, scale: CGFloat) -> Bool {
        if selectedSkillId == skill.id { return true }
        if skill.isFoundation { return true }
        if skill.status == .drill { return true }
        if skill.status == .master { return scale > 0.85 }
        if skill.status == .next { return scale > 0.85 }
        return scale > 1.3
    }

    // Stronger edges when a neighbour is selected, faint by default —
    // mirrors the design's "highlight chain" effect without the full
    // chain-tracing UI.
    private func opacityForEdge(skill: Skill, prereq: Skill) -> Double {
        if selectedSkillId == skill.id || selectedSkillId == prereq.id {
            return 0.70
        }
        return 0.18
    }

    // Background star-field positions. Computed once via a deterministic
    // pseudo-random walk over an oversized region (world bounds +50%
    // padding each side) so the parallax-dampened render stays covered
    // at extreme pan/zoom. Stable across launches — feels like a real
    // sky, not a procedurally-jittered overlay.
    struct BackgroundDot { let x: Double; let y: Double; let r: CGFloat; let alpha: Double }
    static let bgDots: [BackgroundDot] = {
        var rng = SplitMix64(seed: 0x510D_C0DE_BEEF)
        var dots: [BackgroundDot] = []
        let count = 320
        dots.reserveCapacity(count)
        // Seed over [-1200, 3600] x [-800, 2400] — the world plus a
        // 50%-on-each-side margin. Density is held roughly constant
        // (~1 dot per 6_000 sqpt) so the field doesn't look sparser
        // than the old smaller seeding.
        for _ in 0..<count {
            let x = -1200 + rng.nextDouble() * 4800
            let y = -800  + rng.nextDouble() * 3200
            let bright = rng.nextDouble()
            // Most dots tiny + faint, a handful brighter to suggest depth.
            let r: CGFloat = bright > 0.92 ? 0.9 : (bright > 0.75 ? 0.6 : 0.4)
            let alpha = 0.10 + bright * 0.18   // 0.10 … 0.28
            dots.append(BackgroundDot(x: x, y: y, r: r, alpha: alpha))
        }
        return dots
    }()

}

// Inline deterministic RNG so the background-dot positions don't depend
// on SystemRandomNumberGenerator (which would re-seed per launch and
// make the sky shift every time the app opened). Tiny implementation —
// not crypto, just stable seeding.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
    mutating func nextDouble() -> Double {
        Double(next() &>> 11) / Double(1 &<< 53)
    }
}

// CanvasTransform / CameraPose / CanvasCamera live in CanvasCamera.swift
// (pure, SwiftUI-free, unit-testable). SkyView owns the live @State and
// the gesture/animation wiring below and delegates the math to them.

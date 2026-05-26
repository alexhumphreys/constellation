import ConstellationCore
import SwiftUI

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
    let store: Store
    let onMutation: () -> Void
    // Fired on the first tick of any user-driven pan/pinch on the
    // canvas. The parent uses this to dismiss transient overlays
    // (e.g. the chain trace) so they don't outlive the context that
    // explains them.
    let onCanvasGesture: () -> Void
    @Binding var selectedSkillId: SkillID?
    // When set, pan/zoom to that skill and clear the binding. Lets the
    // parent ask the canvas to recenter on a target after a state change
    // (e.g. focusing a freshly-added skill so it doesn't get lost at
    // whatever zoom the user was at).
    @Binding var focusRequest: FocusRequest?
    let onAdd: () -> Void
    // Fraction of viewport height to use as the target vertical center
    // when focusing on a skill. 0.5 = dead center. iPhone passes 0.25
    // so the focused star lands in the upper half — the part not
    // covered by the medium-detent inspector sheet.
    let focusVerticalBias: CGFloat

    init(
        skills: [Skill],
        areas: [Area],
        initialFocus: InitialFocus = .all,
        chainSkillIds: Set<SkillID> = [],
        chainHighlightOpacity: Double = 1.0,
        store: Store,
        onMutation: @escaping () -> Void,
        selectedSkillId: Binding<SkillID?>,
        focusRequest: Binding<FocusRequest?> = .constant(nil),
        focusVerticalBias: CGFloat = 0.5,
        onCanvasGesture: @escaping () -> Void = {},
        onAdd: @escaping () -> Void = {}
    ) {
        self.skills = skills
        self.areas = areas
        self.initialFocus = initialFocus
        self.chainSkillIds = chainSkillIds
        self.chainHighlightOpacity = chainHighlightOpacity
        self.store = store
        self.onMutation = onMutation
        self._selectedSkillId = selectedSkillId
        self._focusRequest = focusRequest
        self.focusVerticalBias = focusVerticalBias
        self.onCanvasGesture = onCanvasGesture
        self.onAdd = onAdd
    }

    // Canvas transform. Mutated directly by CanvasGestureSurface as
    // pan/pinch tick, so there's no separate "in-flight delta" state
    // to compose — the UIKit gestures already give us per-tick deltas
    // we can apply incrementally.
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 0.5

    @State private var didFit: Bool = false

    // Drag-to-move overlay state. While the user is long-press dragging
    // a star we render at this overridden world position so the canvas
    // updates at 60fps without round-tripping through the Store. On
    // drag-end we upsert the skill, trigger a parent reload, and clear
    // the override on the next tick — by then the persisted x/y is in
    // `skills` so the star doesn't jump.
    @State private var draggingSkillId: SkillID? = nil
    @State private var dragOverride: CGPoint? = nil

    private let world = CGSize(width: 2400, height: 1600)
    private let zoomBounds: ClosedRange<CGFloat> = 0.30...3.00

    var body: some View {
        GeometryReader { geo in
            let transform = effectiveTransform
            let visibleSkillsById = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
            let areaTints = Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0.color) })

            Canvas { context, size in
                // Solid background fill — the radial-gradient sky is a
                // future polish item; the flat dark color reads almost
                // identically at the device sizes we care about.
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Theme.Sky.bg1)
                )

                // Faint background star field. Deterministic positions
                // (seeded once) and rendered through a *dampened*
                // transform — dots only move 40% as much as the
                // foreground when panning, and 70% as much when
                // zooming. That mismatch is the parallax cue: a sky
                // that sits behind the skill graph rather than glued
                // to it. The seeded region overshoots world bounds by
                // 50% on each side so the screen stays covered at
                // extreme pan.
                let bgScale = Swift.max(0.6, transform.scale * 0.7)
                let bgOffsetX = transform.offsetX * 0.4
                let bgOffsetY = transform.offsetY * 0.4
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
            }
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
                    onDragEnded: {
                        endDrag()
                    },
                    onCanvasGestureBegan: onCanvasGesture
                )
            )
            .overlay(alignment: .bottomTrailing) {
                resetButton(into: geo.size)
            }
            .overlay(alignment: .bottomLeading) {
                addButton
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
        let fitScale: CGFloat = min(
            (size.width  * 0.85) / bboxW,
            (size.height * 0.85) / bboxH
        )
        let s = Swift.max(CGFloat(0.60), fitScale).zoomClamped(to: zoomBounds)
        // Centroid of the live cluster — `Area.liveCenter` falls back
        // to the stored centerX/centerY when the area has no skills,
        // but the early-return above means we always have at least one
        // here, so this is effectively the rolling cluster center.
        let center = area?.liveCenter(in: skills)
            ?? (x: xs.reduce(0, +) / Double(xs.count),
                y: ys.reduce(0, +) / Double(ys.count))
        let centerX = center.x
        let centerY = center.y
        scale = s
        offset = CGSize(
            width: size.width / 2 - centerX * s,
            height: size.height / 2 - centerY * s
        )
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

    // Bottom-leading floating "+" mirroring the reset button's style —
    // primary on-canvas affordance for adding skills/hobbies. The same
    // action lives in HobbyFilterView's header but reads as decorative
    // (Alex called it "very hidden"), so this is the discoverable one.
    @ViewBuilder
    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(.black.opacity(0.30))
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add skill or hobby")
        .padding(.leading, 16)
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
        let s = request.preserveScale
            ? scale
            : max(CGFloat(1.0), scale).zoomClamped(to: zoomBounds)
        withAnimation(.easeInOut(duration: 0.3)) {
            scale = s
            offset = CGSize(
                width: size.width / 2 - CGFloat(skill.x) * s,
                height: size.height * focusVerticalBias - CGFloat(skill.y) * s
            )
        }
        focusRequest = nil
    }

    private func fitToBox(_ box: CGRect, padding: CGFloat, into size: CGSize) {
        let availW = size.width - padding * 2
        let availH = size.height - padding * 2
        let s = min(availW / box.width, availH / box.height)
            .zoomClamped(to: zoomBounds)
        scale = s
        // Place box center at view center.
        offset = CGSize(
            width: size.width / 2 - (box.midX) * s,
            height: size.height / 2 - (box.midY) * s
        )
    }

    // MARK: - Hit testing

    private func handleTap(
        at location: CGPoint, in size: CGSize, transform: CanvasTransform
    ) {
        let bestId = hitTest(at: location, transform: transform)
        // Tap on background clears selection; tap on a star toggles.
        if let bestId {
            selectedSkillId = (selectedSkillId == bestId) ? nil : bestId
        } else {
            selectedSkillId = nil
        }
    }

    // Linear scan over skills — N is tiny (~50). Pick the nearest star
    // within a finger-sized screen-space radius regardless of zoom; that
    // way zoomed-out tiny stars are still hittable.
    private func hitTest(
        at location: CGPoint, transform: CanvasTransform
    ) -> SkillID? {
        var bestId: SkillID? = nil
        var bestDist: CGFloat = 40  // 40pt = comfortable finger target
        for skill in skills {
            let w = worldPosition(of: skill)
            let p = transform.apply(w.x, w.y)
            let dx = p.x - location.x, dy = p.y - location.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < bestDist {
                bestDist = dist
                bestId = skill.id
            }
        }
        return bestId
    }

    // MARK: - Drag-to-move

    // Render-time position: returns the live drag override if this
    // is the star being dragged, otherwise its persisted (x, y).
    private func worldPosition(of skill: Skill) -> CGPoint {
        if let dragOverride, draggingSkillId == skill.id {
            return dragOverride
        }
        return CGPoint(x: skill.x, y: skill.y)
    }

    // True iff the long-press began over a star — that's the signal
    // CanvasGestureSurface uses to suppress pan for the rest of the
    // gesture. Returning false means "no star here, let normal
    // recognizers proceed".
    private func beginDrag(
        at location: CGPoint, transform: CanvasTransform
    ) -> Bool {
        guard let hit = hitTest(at: location, transform: transform) else {
            return false
        }
        draggingSkillId = hit
        // Initialize the override to the finger location in world
        // coords so the very first render snaps the star under the
        // finger (rather than leaving a one-frame visual gap).
        dragOverride = screenToWorld(location)
        return true
    }

    private func updateDrag(at location: CGPoint) {
        guard draggingSkillId != nil else { return }
        dragOverride = screenToWorld(location)
    }

    // On end, persist via Store.upsertSkill (LWW merge, bumps
    // updatedAt) and ask the parent to refresh. We clear the override
    // *after* the refresh has had a chance to land — clearing eagerly
    // would snap the star back to its old position for one frame.
    private func endDrag() {
        guard let id = draggingSkillId, let target = dragOverride else {
            draggingSkillId = nil
            dragOverride = nil
            return
        }
        draggingSkillId = nil
        guard var skill = skills.first(where: { $0.id == id }) else {
            dragOverride = nil
            return
        }
        skill.x = Double(target.x)
        skill.y = Double(target.y)
        skill.updatedAt = Date()
        Task {
            do {
                try await store.upsertSkill(skill)
                await MainActor.run {
                    onMutation()
                    dragOverride = nil
                }
            } catch {
                // Persist failed — drop the override so the canvas
                // reverts to the last known good position. Throwing
                // from a UI gesture has no good surface yet; quiet
                // revert is better than a stuck "off by inches" star.
                await MainActor.run { dragOverride = nil }
            }
        }
    }

    // screen = world * scale + offset  ⇒  world = (screen - offset) / scale
    private func screenToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - offset.width)  / scale,
            y: (p.y - offset.height) / scale
        )
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

// Tiny value type so the transform math is one place and easy to test.
struct CanvasTransform {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    func apply(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * scale + offsetX, y: y * scale + offsetY)
    }
}

private extension CGFloat {
    // Renamed from `clamped` to avoid a name collision with the
    // package-scoped `clamped(to: ClosedRange<Double>)` Apple added
    // somewhere in the iOS 18 SDK — that one wins overload resolution
    // because the SDK considers `CGFloat == Double`, but its
    // `package` visibility means it's not callable from outside its
    // owning module and the build fails. Using a uniquely-named
    // helper sidesteps the whole question.
    func zoomClamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

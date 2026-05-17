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

struct SkyView: View {
    let skills: [Skill]
    let areas: [Area]
    let initialFocus: InitialFocus
    @Binding var selectedSkillId: SkillID?

    init(
        skills: [Skill],
        areas: [Area],
        initialFocus: InitialFocus = .all,
        selectedSkillId: Binding<SkillID?>
    ) {
        self.skills = skills
        self.areas = areas
        self.initialFocus = initialFocus
        self._selectedSkillId = selectedSkillId
    }

    // Canvas transform. Mutated directly by CanvasGestureSurface as
    // pan/pinch tick, so there's no separate "in-flight delta" state
    // to compose — the UIKit gestures already give us per-tick deltas
    // we can apply incrementally.
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 0.5

    @State private var didFit: Bool = false

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

                // Prereq edges first so stars sit on top.
                for skill in skills {
                    let to = transform.apply(skill.x, skill.y)
                    for prereqId in skill.prereqIds {
                        guard let prereq = visibleSkillsById[prereqId] else {
                            continue
                        }
                        let from = transform.apply(prereq.x, prereq.y)
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        context.stroke(
                            path,
                            with: .color(Theme.Sky.star.opacity(
                                opacityForEdge(skill: skill, prereq: prereq))),
                            lineWidth: 0.6
                        )
                    }
                    // Soft prereqs — dashed
                    for prereqId in skill.softPrereqIds {
                        guard let prereq = visibleSkillsById[prereqId] else {
                            continue
                        }
                        let from = transform.apply(prereq.x, prereq.y)
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        context.stroke(
                            path,
                            with: .color(Theme.Sky.star.opacity(0.06)),
                            style: StrokeStyle(lineWidth: 0.6, dash: [3, 3])
                        )
                    }
                }

                // Stars on top.
                for skill in skills {
                    let p = transform.apply(skill.x, skill.y)
                    let visual = StatusVisual.of(skill.status)
                    let tint = areaTints[skill.areaId] ?? .gray
                    let dim = selectedSkillId != nil && selectedSkillId != skill.id
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
                for skill in skills where shouldLabel(skill, scale: transform.scale) {
                    let p = transform.apply(skill.x, skill.y)
                    let visual = StatusVisual.of(skill.status)
                    let text = Text(skill.name)
                        .font(.system(size: 11, weight: .regular, design: .serif))
                        .foregroundStyle(Theme.Sky.star.opacity(0.95))
                    context.draw(
                        text,
                        at: CGPoint(x: p.x + visual.size + 6, y: p.y),
                        anchor: .leading
                    )
                }
            }
            .overlay(
                CanvasGestureSurface(
                    offset: $offset,
                    scale: $scale,
                    zoomBounds: zoomBounds,
                    onTap: { location in
                        handleTap(at: location, in: geo.size, transform: transform)
                    }
                )
            )
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
        let centerX = area?.centerX ?? (xs.reduce(0, +) / Double(xs.count))
        let centerY = area?.centerY ?? (ys.reduce(0, +) / Double(ys.count))
        scale = s
        offset = CGSize(
            width: size.width / 2 - centerX * s,
            height: size.height / 2 - centerY * s
        )
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
        // Linear scan over skills — N is tiny (~50). Pick the nearest
        // star within a finger-sized screen-space radius regardless of
        // zoom; that way zoomed-out tiny stars are still hittable.
        var bestId: SkillID? = nil
        var bestDist: CGFloat = 40  // 40pt = comfortable finger target
        for skill in skills {
            let p = transform.apply(skill.x, skill.y)
            let dx = p.x - location.x, dy = p.y - location.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < bestDist {
                bestDist = dist
                bestId = skill.id
            }
        }
        // Tap on background clears selection; tap on a star toggles.
        if let bestId {
            selectedSkillId = (selectedSkillId == bestId) ? nil : bestId
        } else {
            selectedSkillId = nil
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
            return 0.55
        }
        return 0.10
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

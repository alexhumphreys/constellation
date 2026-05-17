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
struct SkyView: View {
    let skills: [Skill]
    let areas: [Area]
    @Binding var selectedSkillId: SkillID?

    // Committed state — applied when a gesture ends.
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 0.5

    // Live deltas while a gesture is in-flight. Composed with the
    // committed state in `effectiveTransform` so we don't have to
    // recompute the entire layout on every gesture tick.
    @State private var dragDelta: CGSize = .zero
    @State private var pinchDelta: CGFloat = 1.0

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
            .contentShape(Rectangle())  // make whole canvas tappable
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            dragDelta = value.translation
                        }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                            dragDelta = .zero
                        },
                    MagnifyGesture()
                        .onChanged { value in
                            pinchDelta = value.magnification
                        }
                        .onEnded { value in
                            let next = (scale * value.magnification)
                                .clamped(to: zoomBounds)
                            scale = next
                            pinchDelta = 1.0
                        }
                )
            )
            .onTapGesture(coordinateSpace: .local) { location in
                handleTap(at: location, in: geo.size, transform: transform)
            }
            .onAppear { if !didFit { fitAll(into: geo.size); didFit = true } }
            .onChange(of: geo.size) { _, newSize in
                // If the view resizes (rotation, multitasking) before a
                // user has interacted, re-fit so the constellation
                // stays centered. Once they've panned/zoomed we leave
                // their viewport alone.
                if !didFit { fitAll(into: newSize) }
            }
        }
    }

    // MARK: - Transform composition

    private var effectiveTransform: CanvasTransform {
        let s = (scale * pinchDelta).clamped(to: zoomBounds)
        return CanvasTransform(
            scale: s,
            offsetX: offset.width + dragDelta.width,
            offsetY: offset.height + dragDelta.height
        )
    }

    // MARK: - Fit-all (initial layout)

    private func fitAll(into size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let padding: CGFloat = 60
        let availW = size.width - padding * 2
        let availH = size.height - padding * 2
        let s = min(availW / world.width, availH / world.height)
            .clamped(to: zoomBounds)
        scale = s
        offset = CGSize(
            width: (size.width - world.width * s) / 2,
            height: (size.height - world.height * s) / 2
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
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

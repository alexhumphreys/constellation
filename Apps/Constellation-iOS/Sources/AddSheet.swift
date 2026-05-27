import ConstellationCore
import SwiftUI
import UIKit

// "+" sheet for creating a new skill or a new hobby (area). Mirrors
// the CLI's `skill add` / `area add` but with the affordances a phone
// wants: IDs derived from the name (no user-facing ID field — a phone
// shouldn't make you type slugs), a picker for the hobby, a ColorPicker
// for the tint. Position fields are intentionally absent — new skills
// drop at the area's center and drag-to-move handles repositioning.
// Saving goes through Store.upsertSkill / Store.upsertArea so the CRDT
// semantics are identical to the CLI.
struct AddSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case skill, area
        var id: String { rawValue }
        var label: String { self == .skill ? "Skill" : "Hobby" }
    }

    let areas: [Area]
    let store: Store
    let onClose: () -> Void
    // Fires after a successful save. First arg is the area the newly-
    // added thing belongs to (== the area itself for `.area` mode, the
    // skill's area for `.skill` mode) — parent uses it to refresh and
    // make sure that area is visible. Second arg is the new skill's id
    // for `.skill` mode (nil for `.area` mode) so the caller can focus
    // the canvas on it or auto-select it as a prereq.
    let onAdded: (AreaID, SkillID?) -> Void

    // Optional skill the user is editing in a picker context (prereq /
    // unlocks). Used as the "drop the new skill near this one" hint:
    // pre-selects its hobby (so the new skill lands in the same cluster)
    // and feeds its position into the manual placement spiral so a new
    // prereq doesn't materialise at the area centroid far from where
    // the user was working. Concentric layout uses graph topology
    // instead, so this hint is ignored there.
    let seedSkill: Skill?

    init(
        areas: [Area],
        store: Store,
        onClose: @escaping () -> Void,
        onAdded: @escaping (AreaID, SkillID?) -> Void,
        seedSkill: Skill? = nil
    ) {
        self.areas = areas
        self.store = store
        self.onClose = onClose
        self.onAdded = onAdded
        self.seedSkill = seedSkill
    }

    @State private var mode: Mode = .skill

    // Skill form
    @State private var skillName: String = ""
    @State private var skillAreaId: AreaID? = nil
    @State private var skillStatus: SkillStatus = .next
    @State private var skillFoundation: Bool = false

    // Area form
    @State private var areaName: String = ""
    // Soft orange default — distinct from the seed palette so a
    // freshly-added area is immediately visually identifiable.
    @State private var areaTint: Color = Color(red: 0.91, green: 0.54, blue: 0.48)

    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    // Remembers the last hobby a skill was saved into, so the next
    // AddSheet open pre-selects it. Stored as the raw id string because
    // @AppStorage doesn't take typed wrappers.
    @AppStorage("AddSheet.lastSkillAreaId") private var lastSkillAreaIdRaw: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .listRowBackground(Color.clear)

                if mode == .skill {
                    skillFields
                } else {
                    areaFields
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Sky.bg2)
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving || !canSave)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                // Prefer the picker-context skill's hobby (so a "new
                // prereq" lands in the same cluster you were just
                // looking at), then the last hobby the user saved
                // into, then the first existing hobby as a last resort.
                if skillAreaId == nil {
                    if let seedSkill,
                       areas.contains(where: { $0.id == seedSkill.areaId }) {
                        skillAreaId = seedSkill.areaId
                    } else if let stored = AreaID(rawValue: lastSkillAreaIdRaw),
                       areas.contains(where: { $0.id == stored }) {
                        skillAreaId = stored
                    } else {
                        skillAreaId = areas.first?.id
                    }
                }
            }
        }
    }

    // MARK: - Skill fields

    @ViewBuilder
    private var skillFields: some View {
        if areas.isEmpty {
            Section {
                Text("Add a hobby first — switch to the Hobby tab above.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        } else {
            Section("Name") {
                TextField("e.g. Hip Key", text: $skillName)
            }
            Section("Hobby") {
                Picker("Hobby", selection: $skillAreaId) {
                    ForEach(areas, id: \.id) { area in
                        Text(area.name).tag(Optional(area.id))
                    }
                }
                .labelsHidden()
            }
            Section("Status") {
                Picker("Status", selection: $skillStatus) {
                    ForEach(SkillStatus.allCases, id: \.self) { s in
                        Text(s.displayLabel).tag(s)
                    }
                }
                .labelsHidden()
            }
            Section {
                Toggle("Foundation skill", isOn: $skillFoundation)
            } footer: {
                Text("Foundation skills are entry points — drawn with a star marker.")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Area fields

    private var areaFields: some View {
        Group {
            Section("Name") {
                TextField("e.g. Aerial Silks", text: $areaName)
            }
            Section("Tint") {
                ColorPicker("Color", selection: $areaTint, supportsOpacity: false)
            }
        }
    }

    // MARK: - Validation

    private var canSave: Bool {
        switch mode {
        case .skill:
            return !skillName.trimmed.isEmpty
                && skillAreaId != nil
                && !areas.isEmpty
        case .area:
            return !areaName.trimmed.isEmpty
        }
    }

    // MARK: - Save

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                let activeArea: AreaID
                let newSkillId: SkillID?
                switch mode {
                case .skill:
                    let saved = try await saveSkill()
                    activeArea = saved.areaId
                    newSkillId = saved.id
                case .area:
                    activeArea = try await saveArea()
                    newSkillId = nil
                }
                await MainActor.run {
                    onAdded(activeArea, newSkillId)
                    onClose()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    saving = false
                }
            }
        }
    }

    private func saveSkill() async throws -> Skill {
        guard let areaId = skillAreaId,
              let area = areas.first(where: { $0.id == areaId })
        else {
            throw FormError("pick a hobby first")
        }
        let sid = try await uniqueSkillId(from: skillName.trimmed)
        let allSkills = try await store.skills()
        // Picker-context hint: drop the new skill near the skill the
        // user was just editing, but only when that skill is in the
        // *same* area we're saving into. Cross-area picker creates fall
        // back to area-centric placement so a new "cross-hobby helper"
        // doesn't land in the wrong cluster.
        let seedInArea = seedSkill.flatMap { $0.areaId == areaId ? $0 : nil }
        let draft = Skill(
            id: sid,
            areaId: areaId,
            name: skillName.trimmed,
            status: skillStatus,
            isFoundation: skillFoundation
        )
        let (x, y) = dropSpot(
            for: draft, in: area, among: allSkills, seedNear: seedInArea
        )
        var skill = draft
        skill.x = x
        skill.y = y
        try await store.upsertSkill(skill)
        lastSkillAreaIdRaw = areaId.rawValue
        return skill
    }

    private func saveArea() async throws -> AreaID {
        let aid = try await uniqueAreaId(from: areaName.trimmed)
        let area = Area(
            id: aid,
            name: areaName.trimmed,
            tint: hexString(from: areaTint)
        )
        try await store.upsertArea(area)
        return aid
    }

    // Try the base slug, then base-2, base-3, … so two skills can share
    // a display name without the second save bouncing off LWW. Bails out
    // after 100 attempts so a degenerate name doesn't hang the save.
    private func uniqueSkillId(from name: String) async throws -> SkillID {
        let base = slugify(name)
        guard !base.isEmpty,
              let baseId = SkillID(rawValue: base)
        else {
            throw FormError("name needs at least one letter or number")
        }
        if try await store.skill(baseId) == nil { return baseId }
        for n in 2...100 {
            guard let candidate = SkillID(rawValue: "\(base)-\(n)") else {
                continue
            }
            if try await store.skill(candidate) == nil { return candidate }
        }
        throw FormError("too many skills named '\(name)' — try a different name")
    }

    private func uniqueAreaId(from name: String) async throws -> AreaID {
        let base = slugify(name)
        guard !base.isEmpty,
              let baseId = AreaID(rawValue: base)
        else {
            throw FormError("name needs at least one letter or number")
        }
        if try await store.area(baseId) == nil { return baseId }
        for n in 2...100 {
            guard let candidate = AreaID(rawValue: "\(base)-\(n)") else {
                continue
            }
            if try await store.area(candidate) == nil { return candidate }
        }
        throw FormError("too many hobbies named '\(name)' — try a different name")
    }

    private struct FormError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - Helpers

// Find a placement near (cx, cy) that isn't on top of an existing
// star. Tries the center first (so the first skill in an empty area
// still lands at the documented spot), then walks concentric rings of
// 8 slots each, expanding by `step` per ring. Each ring is rotated by
// a half-slot from the previous so adjacent rings don't line up
// radially. Falls back to (cx, cy) after a bounded number of rings —
// at that density the user's better off dragging-to-move anyway.
// Made module-internal so EditSkillSheet can reuse this when a skill
// is moved to a different hobby (re-drops it at the destination
// area's center, spiraling out to avoid stacking).
func openSpot(
    near cx: Double, near cy: Double, avoiding existing: [Skill]
) -> (Double, Double) {
    let minSeparation: Double = 55
    let step: Double = 45
    let slotsPerRing = 8
    let maxRings = 12

    func clear(_ x: Double, _ y: Double) -> Bool {
        for s in existing {
            let dx = s.x - x
            let dy = s.y - y
            if (dx * dx + dy * dy).squareRoot() < minSeparation {
                return false
            }
        }
        return true
    }

    if clear(cx, cy) { return (cx, cy) }
    for ring in 1...maxRings {
        let radius = Double(ring) * step
        let rotation = Double(ring) * (.pi / Double(slotsPerRing))
        for slot in 0..<slotsPerRing {
            let angle = rotation + Double(slot) * (2 * .pi / Double(slotsPerRing))
            let x = cx + radius * cos(angle)
            let y = cy + radius * sin(angle)
            if clear(x, y) { return (x, y) }
        }
    }
    return (cx, cy)
}

// Turn "Hip Key Drop" → "hip-key-drop". Keeps letters and digits,
// folds whitespace / underscores / hyphens into single hyphens, and
// strips leading/trailing hyphens.
private func slugify(_ s: String) -> String {
    var out = ""
    var lastWasDash = false
    for ch in s.lowercased() {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            lastWasDash = false
        } else if ch == " " || ch == "-" || ch == "_" {
            if !out.isEmpty, !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

// SwiftUI Color → "#rrggbb". Goes via UIColor's sRGB components so
// the round-trip with `Area.color` (which parses 6-digit hex) lines
// up. Clamps to [0,1] because ColorPicker can return out-of-gamut
// values in extended ranges.
// Module-internal so EditHobbySheet's ColorPicker save path can reuse it.
func hexString(from color: Color) -> String {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    let ri = Int((max(0, min(1, r)) * 255).rounded())
    let gi = Int((max(0, min(1, g)) * 255).rounded())
    let bi = Int((max(0, min(1, b)) * 255).rounded())
    return String(format: "#%02x%02x%02x", ri, gi, bi)
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

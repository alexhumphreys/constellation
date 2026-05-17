import ConstellationCore
import SwiftUI
import UIKit

// "+" sheet for creating a new skill or a new hobby (area). Mirrors
// the CLI's `skill add` / `area add` but with the affordances a phone
// wants: auto-slugified IDs, a picker for the hobby, a ColorPicker
// for the tint. Position fields are intentionally absent — new skills
// drop at the area's center and the next task (drag-to-move) handles
// repositioning. Saving goes through Store.upsertSkill /
// Store.upsertArea so the CRDT semantics are identical to the CLI.
struct AddSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case skill, area
        var id: String { rawValue }
        var label: String { self == .skill ? "Skill" : "Hobby" }
    }

    let areas: [Area]
    let store: Store
    let onClose: () -> Void
    // Fires after a successful save with the area the newly-added
    // thing belongs to (== the area itself for `.area` mode, the
    // skill's area for `.skill` mode). The parent uses this to
    // (a) refresh the canvas and (b) make sure that area is visible
    // in the hobby filter so the new item isn't hidden behind a
    // toggled-off chip.
    let onAdded: (AreaID) -> Void

    @State private var mode: Mode = .skill

    // Skill form
    @State private var skillName: String = ""
    @State private var skillId: String = ""
    @State private var skillIdEdited: Bool = false
    @State private var skillAreaId: AreaID? = nil
    @State private var skillStatus: SkillStatus = .next
    @State private var skillFoundation: Bool = false

    // Area form
    @State private var areaName: String = ""
    @State private var areaId: String = ""
    @State private var areaIdEdited: Bool = false
    // Soft orange default — distinct from the seed palette so a
    // freshly-added area is immediately visually identifiable.
    @State private var areaTint: Color = Color(red: 0.91, green: 0.54, blue: 0.48)

    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

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
                // Default to the first hobby so the user can save a
                // skill without touching the picker.
                if skillAreaId == nil { skillAreaId = areas.first?.id }
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
                    .onChange(of: skillName) { _, new in
                        if !skillIdEdited { skillId = slugify(new) }
                    }
            }
            Section {
                TextField("hip-key", text: $skillId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: skillId) { _, _ in skillIdEdited = true }
            } header: {
                Text("ID")
            } footer: {
                Text("Auto-generated from name. Used in URLs and CLI.")
                    .font(.caption2)
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
                    .onChange(of: areaName) { _, new in
                        if !areaIdEdited { areaId = slugify(new) }
                    }
            }
            Section {
                TextField("silks", text: $areaId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: areaId) { _, _ in areaIdEdited = true }
            } header: {
                Text("ID")
            } footer: {
                Text("Auto-generated from name. Used in URLs and CLI.")
                    .font(.caption2)
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
                && !skillId.isEmpty
                && skillAreaId != nil
                && !areas.isEmpty
        case .area:
            return !areaName.trimmed.isEmpty && !areaId.isEmpty
        }
    }

    // MARK: - Save

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                let active: AreaID
                switch mode {
                case .skill:
                    active = try await saveSkill()
                case .area:
                    active = try await saveArea()
                }
                await MainActor.run {
                    onAdded(active)
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

    private func saveSkill() async throws -> AreaID {
        guard let areaId = skillAreaId,
              let area = areas.first(where: { $0.id == areaId })
        else {
            throw FormError("pick a hobby first")
        }
        guard let sid = SkillID(rawValue: skillId) else {
            throw FormError("ID can't be empty")
        }
        // Reject duplicate IDs explicitly so the user sees a clear
        // error rather than silently merging via LWW (which would
        // overwrite the existing skill's fields).
        if try await store.skill(sid) != nil {
            throw FormError("a skill with id '\(skillId)' already exists")
        }
        let skill = Skill(
            id: sid,
            areaId: areaId,
            name: skillName.trimmed,
            status: skillStatus,
            x: area.centerX,
            y: area.centerY,
            isFoundation: skillFoundation
        )
        try await store.upsertSkill(skill)
        return areaId
    }

    private func saveArea() async throws -> AreaID {
        guard let aid = AreaID(rawValue: areaId) else {
            throw FormError("ID can't be empty")
        }
        if try await store.area(aid) != nil {
            throw FormError("a hobby with id '\(areaId)' already exists")
        }
        let area = Area(
            id: aid,
            name: areaName.trimmed,
            tint: hexString(from: areaTint)
        )
        try await store.upsertArea(area)
        return aid
    }

    private struct FormError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - Helpers

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
private func hexString(from color: Color) -> String {
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

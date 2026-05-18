import ConstellationCore
import SwiftUI

// "Edit skill" sheet — companion to AddSheet for an existing skill. The
// id is fixed (it's the CRDT key); name, hobby, and foundation are
// editable, and a Delete row tombstones the skill via the same path the
// CLI uses. Moving a skill to a different hobby re-drops it at the new
// area's center (via openSpot from AddSheet) so it doesn't keep its
// old (x, y) which would now sit in a different cluster — the user can
// drag-to-move from there if they want a specific spot.
struct EditSkillSheet: View {
    let skill: Skill
    let areas: [Area]
    let store: Store
    let onClose: () -> Void
    let onSaved: () -> Void
    let onDeleted: () -> Void

    @State private var name: String
    @State private var areaId: AreaID
    @State private var isFoundation: Bool

    @State private var saving: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var errorMessage: String? = nil

    init(
        skill: Skill,
        areas: [Area],
        store: Store,
        onClose: @escaping () -> Void,
        onSaved: @escaping () -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.skill = skill
        self.areas = areas
        self.store = store
        self.onClose = onClose
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: skill.name)
        _areaId = State(initialValue: skill.areaId)
        _isFoundation = State(initialValue: skill.isFoundation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Skill name", text: $name)
                }
                Section {
                    Picker("Hobby", selection: $areaId) {
                        ForEach(areas, id: \.id) { area in
                            Text(area.name).tag(area.id)
                        }
                    }
                    .labelsHidden()
                } header: {
                    Text("Hobby")
                } footer: {
                    if areaId != skill.areaId {
                        Text("Moving this skill will re-drop it at the new hobby's center. You can drag it anywhere from there.")
                            .font(.caption2)
                    }
                }
                Section {
                    Toggle("Foundation skill", isOn: $isFoundation)
                } footer: {
                    Text("Foundation skills are entry points — drawn with a star marker.")
                        .font(.caption2)
                }
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete skill", systemImage: "trash")
                    }
                    .disabled(saving)
                } footer: {
                    Text("Tombstones the skill — it stops appearing in the sky and on other devices when they sync.")
                        .font(.caption2)
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
            .navigationTitle("Edit skill")
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
            .confirmationDialog(
                "Delete \"\(skill.name)\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete skill", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone from the app. Notes, clips, and sessions stay attached so the data isn't lost if you re-add the same id.")
            }
        }
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                var updated = skill
                updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.isFoundation = isFoundation
                if areaId != skill.areaId,
                   let dest = areas.first(where: { $0.id == areaId })
                {
                    updated.areaId = areaId
                    let neighbours = try await store.skills()
                        .filter { $0.areaId == areaId && !$0.isDeleted && $0.id != skill.id }
                    let (x, y) = openSpot(
                        near: dest.centerX, near: dest.centerY,
                        avoiding: neighbours
                    )
                    updated.x = x
                    updated.y = y
                }
                updated.updatedAt = Date()
                try await store.upsertSkill(updated)
                await MainActor.run {
                    onSaved()
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

    private func delete() {
        saving = true
        errorMessage = nil
        Task {
            do {
                try await store.tombstoneSkill(skill.id)
                await MainActor.run {
                    onDeleted()
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
}

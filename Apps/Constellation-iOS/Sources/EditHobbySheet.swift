import ConstellationCore
import SwiftUI
import UIKit

// "Edit hobby" sheet — name + tint editor for an existing Area, plus a
// Delete action. Delete is blocked when the area has any non-tombstoned
// skill: the error names the count so the user knows what they need to
// move or delete first, rather than silently losing a hobby's worth of
// work. Tint round-trips through hexString (shared with AddSheet) so
// the storage shape stays "#rrggbb".
struct EditHobbySheet: View {
    let area: Area
    let store: Store
    let onClose: () -> Void
    let onSaved: () -> Void
    let onDeleted: () -> Void

    @State private var name: String
    @State private var tint: Color
    @State private var layoutKind: LayoutKind

    @State private var saving: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var errorMessage: String? = nil

    init(
        area: Area,
        store: Store,
        onClose: @escaping () -> Void,
        onSaved: @escaping () -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.area = area
        self.store = store
        self.onClose = onClose
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: area.name)
        _tint = State(initialValue: area.color)
        _layoutKind = State(initialValue: area.layoutKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Hobby name", text: $name)
                }
                Section("Tint") {
                    ColorPicker("Color", selection: $tint, supportsOpacity: false)
                }
                Section {
                    Picker("Layout", selection: $layoutKind) {
                        ForEach(LayoutKind.allCases, id: \.self) { k in
                            Text(k.displayLabel).tag(k)
                        }
                    }
                } footer: {
                    Text(layoutFooter)
                        .font(.caption2)
                }
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete hobby", systemImage: "trash")
                    }
                    .disabled(saving)
                } footer: {
                    Text("Tombstones the hobby across devices. Blocked if any of its skills are still active — delete or move them first.")
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
            .navigationTitle("Edit hobby")
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
                "Delete \"\(area.name)\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete hobby", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone from the app.")
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var layoutFooter: String {
        switch layoutKind {
        case .manual:
            "Fresh skills drop at the cluster center and spiral out to a clear spot. Existing stars stay where you put them."
        case .concentric:
            "Fresh skills land on a concentric ring — foundations at the center, each prereq hop one ring further out. Drag any star to pin it."
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                var updated = area
                updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.tint = hexString(from: tint)
                updated.layoutKind = layoutKind
                updated.updatedAt = Date()
                try await store.upsertArea(updated)
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
                let liveSkills = try await store.skills(in: area.id)
                    .filter { !$0.isDeleted }
                if !liveSkills.isEmpty {
                    await MainActor.run {
                        errorMessage = "Can't delete — \(liveSkills.count) "
                            + "skill\(liveSkills.count == 1 ? "" : "s") "
                            + "still in this hobby. Move or delete them first."
                        saving = false
                    }
                    return
                }
                try await store.tombstoneArea(area.id)
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

import ConstellationCore
import SwiftUI

// Lets `.sheet(item: $editingNote)` drive presentation off a Note? in
// the parent. Same pattern as Attachment (see AttachmentThumbnail.swift).
extension Note: @retroactive Identifiable {}

// Sheet for editing or deleting a Note. Notes are LWW-with-tombstones
// (v5→v6) so save preserves the original id + addedAt and bumps
// updatedAt to now; the CRDT merge then propagates the edit across
// devices. Delete tombstones via Store.tombstoneNote — the row stays
// in the table for sync convergence but disappears from `notes(for:)`.
struct EditNoteSheet: View {
    let note: Note
    let store: Store
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var text: String
    @State private var saving: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var errorMessage: String? = nil

    init(
        note: Note,
        store: Store,
        onClose: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.note = note
        self.store = store
        self.onClose = onClose
        self.onSaved = onSaved
        _text = State(initialValue: note.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("What's the cue?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                }
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete note", systemImage: "trash")
                    }
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
            .navigationTitle("Edit note")
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
                "Delete this note?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var canSave: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != note.text
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                var updated = note
                updated.text = trimmed
                updated.updatedAt = Date()
                try await store.upsertNote(updated)
                await MainActor.run { onSaved() }
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
        Task {
            do {
                try await store.tombstoneNote(note.id)
                await MainActor.run { onSaved() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    saving = false
                }
            }
        }
    }
}

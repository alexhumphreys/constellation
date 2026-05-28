import ConstellationCore
import SwiftUI

// Sheet for attaching or editing a clip (IG reel, YouTube video, blog
// post, …) on a skill. Mirrors the CLI's `clip add` but with
// iOS-friendly affordances: the URL host is auto-mapped to a platform
// label so the user doesn't have to type "Instagram"/"YouTube" every
// time, and the optional @handle is the one piece that can't be
// inferred from reel URLs (IG doesn't include the creator in the path).
//
// When `existing` is non-nil the sheet runs in edit mode: fields
// pre-populate from the clip, the title changes, and on save the
// original id + addedAt are preserved while updatedAt bumps to now so
// LWW merge propagates the edit. Platform is only re-derived if the
// URL actually changed — otherwise we preserve whatever was there
// (matters mostly for CLI-imported clips with custom platform strings).
//
// v1 takes URL-bearing or notes-only clips; camera-roll picker,
// in-app playback, and IG/YT API embeds are deferred.
struct AddClipSheet: View {
    let skill: Skill
    let store: Store
    let existing: Clip?
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var title: String
    @State private var urlText: String
    @State private var handle: String
    @State private var duration: String
    @State private var note: String

    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    init(
        skill: Skill,
        store: Store,
        existing: Clip? = nil,
        onClose: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        self.skill = skill
        self.store = store
        self.existing = existing
        self.onClose = onClose
        self.onSaved = onSaved
        _title = State(initialValue: existing?.title ?? "")
        _urlText = State(initialValue: existing?.url?.absoluteString ?? "")
        _handle = State(initialValue: existing?.handle ?? "")
        _duration = State(initialValue: existing?.duration ?? "")
        _note = State(initialValue: existing?.note ?? "")
    }

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Hip key entry from a stand", text: $title)
                }
                Section {
                    TextField("https://…", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("URL")
                } footer: {
                    Text("Optional. Platform (Instagram, YouTube, …) is inferred from the host.")
                        .font(.caption2)
                }
                Section {
                    TextField("@silks_tutor", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Creator handle")
                } footer: {
                    Text("Optional. Can't be inferred from IG reel URLs.")
                        .font(.caption2)
                }
                Section {
                    TextField("6:42", text: $duration)
                        .autocorrectionDisabled()
                } header: {
                    Text("Duration")
                } footer: {
                    Text("Optional. Freeform — '0:42', '3 min', etc.")
                        .font(.caption2)
                }
                Section("Note") {
                    TextField("What's useful about this clip?", text: $note, axis: .vertical)
                        .lineLimit(1...4)
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
            .navigationTitle(isEditing ? "Edit clip" : "Save clip")
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
        }
    }

    private var canSave: Bool {
        !title.trimmed.isEmpty
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                let trimmedUrl = urlText.trimmed
                let url = trimmedUrl.isEmpty ? nil : URL(string: trimmedUrl)
                if !trimmedUrl.isEmpty, url == nil {
                    throw FormError("That URL doesn't look valid.")
                }
                let handleValue = normalizedHandle(handle.trimmed)
                // Preserve the existing platform unless the URL actually
                // changed — matters mostly for clips imported via CLI
                // with a custom platform string the user wouldn't want
                // clobbered just because they edited a note.
                let platform: String
                if let existing,
                   (existing.url?.absoluteString ?? "") == trimmedUrl
                {
                    platform = existing.platform
                } else {
                    platform = ClipPlatform.derive(from: url)
                }
                let now = Date()
                let clip = Clip(
                    id: existing?.id ?? .generate(),
                    skillId: existing?.skillId ?? skill.id,
                    platform: platform,
                    handle: handleValue,
                    title: title.trimmed,
                    url: url,
                    duration: duration.trimmed.isEmpty ? nil : duration.trimmed,
                    note: note.trimmed.isEmpty ? nil : note.trimmed,
                    addedAt: existing?.addedAt ?? now,
                    updatedAt: now
                )
                try await store.upsertClip(clip)
                await MainActor.run {
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    saving = false
                }
            }
        }
    }

    // Strip whitespace and accept either "silks_tutor" or "@silks_tutor".
    // Returns nil for empty input so the model field stays optional.
    private func normalizedHandle(_ raw: String) -> String? {
        let h = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        let trimmed = h.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "@\(trimmed)"
    }

    private struct FormError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// Coarse platform classifier — recognizes the handful of services the
// user actually saves clips from. Unknown hosts fall through to the
// bare host string ("medium.com") so they at least carry provenance;
// notes-only clips with no URL get "Note". Kept as a static API so the
// CLI can reuse the same mapping if/when we add `--url` auto-derive.
enum ClipPlatform {
    static func derive(from url: URL?) -> String {
        guard let host = url?.host?.lowercased() else { return "Note" }
        // Normalize www.foo.com → foo.com so the lookup table stays small.
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        switch bare {
        case "instagram.com":
            return "Instagram"
        case "youtube.com", "youtu.be", "m.youtube.com":
            return "YouTube"
        case "tiktok.com":
            return "TikTok"
        case "twitter.com", "x.com":
            return "Twitter"
        case "vimeo.com":
            return "Vimeo"
        default:
            return bare
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

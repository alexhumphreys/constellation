import ConstellationCore
import PhotosUI
import SwiftUI
import UIKit

// The drawer / sheet shown when a star is tapped. Mirrors the design's
// SkillDrawer:
//   header (area chip + name + status pill + Save/Trace buttons)
//   prereqs / unlocks chip rows
//   clips list
//   sessions list
//   notes list
// v1 supports: changing the skill's status, jumping to a neighbour
// (which keeps the drawer open on the new skill), adding a session,
// note, or URL-based clip inline. Deferred: chain tracing, camera-roll
// picker, in-app playback, edit/delete (matches sessions + notes).
struct SkillDetailView: View {
    let skill: Skill
    let area: Area?
    let allSkills: [Skill]
    let allAreas: [Area]
    let chainActive: Bool
    let store: Store
    let assets: AssetStore

    private var areasById: [AreaID: Area] {
        Dictionary(uniqueKeysWithValues: allAreas.map { ($0.id, $0) })
    }

    let onClose: () -> Void
    let onSelect: (SkillID) -> Void
    let onMutation: () -> Void
    let onToggleChain: () -> Void
    // Called when a child sheet (PrereqPickerSheet's inline AddSheet)
    // creates a brand-new skill or area, so RootView can flip its
    // visibility on and bump the reload token. Separate from
    // onMutation so the callee can distinguish "data changed" from
    // "a new entity was just born".
    let onSkillAdded: (AreaID, SkillID?) -> Void
    // Fires after the edit sheet tombstones the current skill. RootView
    // clears `selectedSkillId` and reloads so the now-deleted inspector
    // doesn't linger on a star that's vanished from the canvas.
    let onSkillDeleted: () -> Void

    @State private var sessions: [Session] = []
    @State private var notes: [Note] = []
    @State private var clips: [Clip] = []
    @State private var attachments: [Attachment] = []
    // Bumped after each successful video-strip backfill so the
    // attachment thumbnails re-read disk and start cycling. Per-success
    // bump rather than a single end-of-batch bump so videos light up
    // progressively as their strips land.
    @State private var stripVersion: Int = 0
    @State private var draftSession: String = ""
    @State private var draftNote: String = ""
    @State private var isSaving: Bool = false
    @State private var showPrereqPicker: Bool = false
    @State private var showUnlocksPicker: Bool = false
    // Clip-sheet state. `editingClip = nil && showClipSheet = true`
    // means "add"; `editingClip = <clip>` means "edit that clip". We
    // bind `showClipSheet` to the sheet so dismissal works for both.
    @State private var showClipSheet: Bool = false
    @State private var editingClip: Clip? = nil
    @State private var showEditSheet: Bool = false
    // Attachment sheet state — picker on `showAttachmentPicker`,
    // fullscreen viewer on a non-nil `viewingAttachment`. `importing`
    // gates the ADD button while PHPicker results are being re-encoded
    // and written to disk (can take a moment for a 30s video).
    @State private var showAttachmentPicker: Bool = false
    @State private var viewingAttachment: Attachment? = nil
    @State private var importing: Bool = false
    @State private var importError: String? = nil

    private var graph: SkillGraph { SkillGraph(allSkills) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusPicker
                prereqsBlock(neighbours: graph.neighbours(of: skill.id))
                unlocksBlock(neighbours: graph.neighbours(of: skill.id))
                clipsSection
                attachmentsSection
                sessionSection
                notesSection
                Color.clear.frame(height: 40)  // bottom safe area
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: skill.id) { await reload() }
        .sheet(isPresented: $showPrereqPicker) {
            PrereqPickerSheet(
                skill: skill,
                allSkills: allSkills,
                allAreas: allAreas,
                store: store,
                onClose: { showPrereqPicker = false },
                onSaved: {
                    showPrereqPicker = false
                    onMutation()
                },
                onSkillAdded: onSkillAdded
            )
        }
        .sheet(isPresented: $showUnlocksPicker) {
            UnlocksPickerSheet(
                skill: skill,
                allSkills: allSkills,
                allAreas: allAreas,
                store: store,
                onClose: { showUnlocksPicker = false },
                onSaved: {
                    showUnlocksPicker = false
                    onMutation()
                },
                onSkillAdded: onSkillAdded
            )
        }
        .sheet(isPresented: $showClipSheet, onDismiss: { editingClip = nil }) {
            AddClipSheet(
                skill: skill,
                store: store,
                existing: editingClip,
                onClose: { showClipSheet = false },
                onSaved: {
                    showClipSheet = false
                    Task { await reload() }
                    onMutation()
                }
            )
        }
        .sheet(isPresented: $showEditSheet) {
            EditSkillSheet(
                skill: skill,
                areas: allAreas,
                store: store,
                onClose: { showEditSheet = false },
                onSaved: {
                    showEditSheet = false
                    onMutation()
                },
                onDeleted: {
                    showEditSheet = false
                    onSkillDeleted()
                }
            )
        }
        .sheet(isPresented: $showAttachmentPicker) {
            AttachmentPicker { results in
                showAttachmentPicker = false
                guard !results.isEmpty else { return }
                Task { await importPicked(results) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $viewingAttachment) { att in
            AttachmentViewerSheet(
                attachment: att,
                store: store,
                assets: assets,
                onClose: { viewingAttachment = nil },
                onDeleted: {
                    viewingAttachment = nil
                    Task { await reload() }
                    onMutation()
                }
            )
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // Mirrors prereqsBlock — always-rendered, with an EDIT pill that
    // opens a picker. Unlocks aren't a field on this skill (they're
    // derived from OTHER skills' prereq lists), so saving from the
    // picker writes to N other skills' prereqIds rather than to this
    // one. The asymmetry is invisible to the user.
    @ViewBuilder
    private func unlocksBlock(neighbours n: SkillGraph.Neighbours?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("THIS UNLOCKS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button { showUnlocksPicker = true } label: {
                    Text("EDIT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            if let n, !n.unlocks.isEmpty {
                chipRow(n.unlocks)
            } else {
                Text("None yet — tap EDIT to mark what this skill unlocks.")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // Header with an EDIT pill, current hard + soft chip rows, and an
    // empty-state line when both lists are empty so the affordance is
    // discoverable on a freshly-added skill that isn't wired up yet.
    @ViewBuilder
    private func prereqsBlock(neighbours n: SkillGraph.Neighbours?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("PREREQUISITES")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button { showPrereqPicker = true } label: {
                    Text("EDIT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            if let n, !n.prereqs.isEmpty {
                chipRow(n.prereqs)
            }
            if let n, !n.softPrereqs.isEmpty {
                Text("RECOMMENDED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
                chipRow(n.softPrereqs)
            }
            if let n, n.prereqs.isEmpty, n.softPrereqs.isEmpty {
                Text("None yet — tap EDIT to wire this skill into the graph.")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let area {
                    Circle()
                        .fill(area.color)
                        .frame(width: 6, height: 6)
                        .shadow(color: area.color.opacity(0.8), radius: 4)
                    Text(area.name.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(area.color)
                }
                Spacer()
                tracePill
                editMenu
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                        .imageScale(.large)
                }
            }
            Text(skill.name)
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Theme.Sky.star)
            if !skill.aliases.isEmpty {
                Text("a.k.a. \(skill.aliases.joined(separator: " · "))")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // Ellipsis menu sitting between TRACE and the close X. Houses the
    // skill-level edit/delete affordances so the header doesn't grow
    // a fourth pill — discoverability via the standard iOS ⋯ icon.
    // Delete sits inside EditSkillSheet rather than the menu so the
    // confirmation has the full edit context (name, hobby) visible.
    private var editMenu: some View {
        Menu {
            Button {
                showEditSheet = true
            } label: {
                Label("Edit skill", systemImage: "pencil")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.white.opacity(0.45))
                .imageScale(.large)
        }
    }

    // Toggle the backward-chain overlay on the canvas — lights up the
    // path of prereqs leading to this skill ("what do I need to learn
    // to get here"). Filled with the chain tint when active so the user
    // has a clear "this is on" cue without leaving the inspector to see
    // the canvas.
    private var tracePill: some View {
        Button(action: onToggleChain) {
            Text("TRACE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        chainActive ? Theme.Sky.chain.opacity(0.20) : .clear
                    )
                )
                .overlay(
                    Capsule().stroke(
                        chainActive ? Theme.Sky.chain : .white.opacity(0.25),
                        lineWidth: 1
                    )
                )
                .foregroundStyle(
                    chainActive ? Theme.Sky.chain : .white.opacity(0.75)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status picker (tapping a status both shows + sets it)

    private var statusPicker: some View {
        HStack(spacing: 6) {
            ForEach(SkillStatus.allCases, id: \.self) { s in
                let chosen = s == skill.status
                Button {
                    Task { await setStatus(s) }
                } label: {
                    Text(s.displayLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(chosen ? statusColor(s).opacity(0.20) : .clear)
                        )
                        .overlay(
                            Capsule().stroke(
                                chosen ? statusColor(s) : .white.opacity(0.10),
                                lineWidth: 1
                            )
                        )
                        .foregroundStyle(chosen ? statusColor(s) : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
    }

    private func statusColor(_ s: SkillStatus) -> Color {
        switch s {
        case .master: Color(red: 0.66, green: 0.90, blue: 0.76)
        case .got:    Color(red: 0.80, green: 0.90, blue: 0.66)
        case .drill:  Theme.Sky.chain
        case .next:   Color(red: 1.00, green: 0.70, blue: 0.54)
        case .wish:   Color(red: 0.85, green: 0.67, blue: 0.91)
        case .locked: .white.opacity(0.45)
        }
    }

    // MARK: - Sections / chip row

    private func section<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
    }

    private func chipRow(_ skills: [Skill]) -> some View {
        WrappingHStack(skills, spacing: 6) { neighbour in
            Button { onSelect(neighbour.id) } label: {
                HStack(spacing: 6) {
                    let tint = allSkillsArea(of: neighbour)?.color ?? .gray
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .shadow(color: tint.opacity(0.7), radius: 3)
                    Text(neighbour.name)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(Theme.Sky.star)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(.white.opacity(0.02))
                )
                .overlay(
                    Capsule().stroke(.white.opacity(0.10), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func allSkillsArea(of skill: Skill) -> Area? {
        areasById[skill.areaId]
    }

    // MARK: - Sessions

    private var sessionSection: some View {
        section("PRACTICE LOG · \(sessions.count)") {
            ForEach(sessions, id: \.id) { s in
                HStack(alignment: .top, spacing: 10) {
                    Text(formatDate(s.date))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 48, alignment: .leading)
                    Text(s.text)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            HStack {
                TextField("Log a session…", text: $draftSession, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.10))
                    )
                Button("Log") {
                    Task { await logSession() }
                }
                .disabled(draftSession.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Sky.chain)
            }
        }
    }

    // MARK: - Clips

    // Section header mirrors the PREREQUISITES block — count chip on the
    // left, ADD pill on the right. Empty state is a single hint line so
    // the affordance is discoverable on a freshly-added skill.
    private var clipsSection: some View {
        let area = self.area
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("CLIPS · \(clips.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    editingClip = nil
                    showClipSheet = true
                } label: {
                    Text("ADD")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            if clips.isEmpty {
                Text("None yet — tap ADD to save an IG reel, YouTube link, or article. Long-press a saved clip to edit.")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(clips, id: \.id) { clip in
                    clipRow(clip, tint: area?.color ?? .gray)
                }
            }
        }
    }

    private func clipRow(_ clip: Clip, tint: Color) -> some View {
        // Tap behaviour: open the URL in Safari if present; for
        // notes-only clips (no URL) tap → edit so they're not a
        // dead row. Long-press → context menu with Edit for both.
        Button {
            if let url = clip.url {
                UIApplication.shared.open(url)
            } else {
                openEditor(for: clip)
            }
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(clip.platform.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(tint)
                        if let handle = clip.handle {
                            Text("· \(handle)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        if let duration = clip.duration {
                            Text("· \(duration)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        if clip.url != nil {
                            Image(systemName: "arrow.up.right.square")
                                .imageScale(.small)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    Text(clip.title)
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.white.opacity(0.88))
                        .multilineTextAlignment(.leading)
                    if let note = clip.note {
                        Text(note)
                            .font(.system(size: 13, design: .serif))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                openEditor(for: clip)
            } label: {
                Label("Edit clip", systemImage: "pencil")
            }
        }
    }

    // Edit affordance shared between long-press menu and the
    // tap-on-noteless-clip path. Order of operations matters: set
    // `editingClip` before flipping `showClipSheet` so the sheet's
    // init reads the right existing clip.
    private func openEditor(for clip: Clip) {
        editingClip = clip
        showClipSheet = true
    }

    // MARK: - Attachments

    // Mirrors the CLIPS section visually — count chip on the left, ADD
    // pill on the right, empty-state hint when no items. Differs in the
    // body: thumbnails are a wrapping grid (LazyVGrid with adaptive
    // 80pt min) rather than a vertical list, since photos/videos read
    // better as a contact sheet than a stacked feed.
    @ViewBuilder
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ATTACHMENTS · \(attachments.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if importing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white.opacity(0.7))
                }
                Button {
                    showAttachmentPicker = true
                } label: {
                    Text("ADD")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .disabled(importing)
            }
            if attachments.isEmpty {
                Text("None yet — tap ADD to attach a photo or video from your library.")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 80), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(attachments, id: \.id) { att in
                        Button {
                            viewingAttachment = att
                        } label: {
                            AttachmentThumbnail(
                                attachment: att,
                                assets: assets,
                                reloadToken: stripVersion
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // PHPicker handed us N items; import them sequentially so we don't
    // saturate the device with concurrent video transcodes. UI shows a
    // spinner via `importing` until the last one lands.
    private func importPicked(_ results: [PHPickerResult]) async {
        importing = true
        defer { importing = false }
        let importer = AttachmentImporter(assets: assets, store: store)
        for result in results {
            do {
                _ = try await importer.importPicked(result, for: skill.id)
            } catch {
                await MainActor.run {
                    importError = "Couldn't import: \(error.localizedDescription)"
                }
                // Continue with the rest — a single bad item shouldn't
                // abort the batch. The user sees the alert; partial
                // success still leaves the good items attached.
            }
        }
        await reload()
        onMutation()
    }

    // MARK: - Notes

    private var notesSection: some View {
        let area = self.area
        return section("NOTES") {
            ForEach(notes, id: \.id) { n in
                HStack(alignment: .top, spacing: 0) {
                    Rectangle()
                        .fill(area?.color ?? .gray)
                        .frame(width: 2)
                    Text(n.text)
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .background(.white.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                TextField("Add a note…", text: $draftNote, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.10))
                    )
                Button("Add") {
                    Task { await addNote() }
                }
                .disabled(draftNote.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Async helpers

    private func reload() async {
        do {
            let s = try await store.sessions(for: skill.id)
            let n = try await store.notes(for: skill.id)
            let c = try await store.clips(for: skill.id)
            let a = try await store.attachments(for: skill.id)
            await MainActor.run {
                self.sessions = s
                self.notes = n
                self.clips = c
                self.attachments = a
            }
            // Lazy backfill: generate cycling strips for any video
            // attachments that don't have one yet (imported before the
            // strip feature shipped, or received via MC blob sync).
            await backfillStrips(for: a)
        } catch {
            print("detail reload failed: \(error)")
        }
    }

    // Best-effort: walk video attachments, generate the cycling-preview
    // strip for any that's missing one. Sequential so we don't fire N
    // AVAssetImageGenerators against the same disk at once; per-success
    // stripVersion bump so each video starts cycling as soon as its
    // strip lands rather than waiting for the slowest one in the batch.
    private func backfillStrips(for atts: [Attachment]) async {
        let importer = AttachmentImporter(assets: assets, store: store)
        let thumbsRoot = await assets.thumbsRoot
        for att in atts where att.mediaType == .video {
            let firstFrame = thumbsRoot
                .appendingPathComponent("\(att.contentHash)-strip", isDirectory: true)
                .appendingPathComponent("0.jpg")
            if FileManager.default.fileExists(atPath: firstFrame.path) { continue }
            guard let url = try? await assets.url(for: att.contentHash) else {
                continue
            }
            do {
                try await importer.writeVideoStrip(
                    sourceURL: url, hash: att.contentHash
                )
                await MainActor.run { stripVersion &+= 1 }
            } catch {
                // Best-effort; tile keeps falling back to the static
                // thumbnail. No user-facing surface for this.
            }
        }
    }

    private func setStatus(_ status: SkillStatus) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.setStatus(status, for: skill.id)
            onMutation()
        } catch {
            print("setStatus failed: \(error)")
        }
    }

    private func logSession() async {
        let text = draftSession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await store.upsertSession(
                Session(skillId: skill.id, text: text)
            )
            draftSession = ""
            await reload()
            onMutation()
        } catch {
            print("session log failed: \(error)")
        }
    }

    private func addNote() async {
        let text = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try await store.upsertNote(Note(skillId: skill.id, text: text))
            draftNote = ""
            await reload()
            onMutation()
        } catch {
            print("note add failed: \(error)")
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}

// Minimal flow layout — wraps children onto multiple lines.
// SwiftUI's HStack doesn't wrap, and ScrollView+HStack with many chips
// would scroll horizontally rather than reflow.
struct WrappingHStack<Item, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let content: (Item) -> Content

    init(_ items: [Item], spacing: CGFloat = 6,
         @ViewBuilder content: @escaping (Item) -> Content)
    {
        self.items = items
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // LazyVGrid with adaptive min-width gives us reflow for free.
        // The chips' intrinsic widths vary, so use a generous minimum
        // that still fits at least one per "column" on iPhone width.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90, maximum: 220), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(0..<items.count, id: \.self) { i in
                content(items[i])
            }
        }
    }
}

import ConstellationCore
import SwiftUI

// Layout: the constellation canvas fills the screen on both devices.
// On iPad/regular-width, tapping a star slides a fixed-width inspector
// in from the trailing edge (NavigationSplitView's detail column).
// On iPhone/compact-width the inspector pops as a half-sheet so the
// canvas remains the primary surface.
struct RootView: View {
    let context: AppContext

    @State private var areas: [Area] = []
    @State private var skills: [Skill] = []
    @State private var activeHobbies: Set<AreaID> = []
    @State private var selectedSkillId: SkillID? = nil
    // Target of an active backward-chain overlay (nil = no trace).
    // Nullified whenever the user navigates away from the trace target
    // so the chain can't outlive the context that explains it.
    @State private var chainSkillId: SkillID? = nil
    @State private var reloadToken: Int = 0
    @State private var showAddSheet: Bool = false
    // Set when we want SkyView to pan/zoom onto a specific skill —
    // primarily right after adding a new one so it doesn't drop at the
    // area center and immediately get lost behind existing stars. SkyView
    // clears the binding once the focus animation kicks off.
    @State private var pendingFocusRequest: FocusRequest? = nil
    // Snapshot share sheet (export → AirDrop). URL is set after the
    // background JSON write finishes; presentation is bound to its
    // presence so the sheet only opens once the file actually exists.
    @State private var exportURL: URL? = nil
    @State private var exportError: String? = nil
    // Inbound snapshot pending the user's "merge?" confirmation. Set by
    // `.onOpenURL` after a successful preview-decode.
    @State private var pendingImport: SnapshotImport.Preview? = nil
    @State private var importError: String? = nil
    @State private var importSourceName: String = ""
    // Area currently being edited via EditHobbySheet. Bound to a
    // single sheet so we don't need a separate isPresented flag —
    // non-nil ⇒ sheet open.
    @State private var editingArea: Area? = nil
    // Sync settings sheet (paired devices + add-device CTA), reached
    // by tapping the sync pill.
    @State private var showSyncSheet: Bool = false
    // Keyboard-first lookup overlay reached from the search icon in
    // HobbyFilterView's header. Picking a result goes through the same
    // focus pathway as a freshly-added skill.
    @State private var showSearchSheet: Bool = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                phoneLayout
            } else {
                padLayout
            }
        }
        .task(id: reloadToken) { await reload() }
        // Every local mutation bumps reloadToken — piggyback on that to
        // queue a peer push. PeerSync internally debounces so drag-to-
        // move's per-frame bumps collapse to one network send.
        .onChange(of: reloadToken) { _, _ in
            context.peerSync.kick()
        }
        // A successful inbound merge bumps pullCount; refresh the UI so
        // peer changes appear without the user pulling-to-refresh.
        .onChange(of: context.peerSync.pullCount) { _, _ in
            reloadToken &+= 1
        }
        // Navigating to (or closing) any skill other than the trace
        // source invalidates the overlay — a chain stranded next to an
        // unrelated inspector is just visual noise.
        .onChange(of: selectedSkillId) { _, newValue in
            if newValue != chainSkillId { chainSkillId = nil }
            // On iPhone, the inspector covers the bottom half of the
            // canvas — pan the newly-selected star into the visible
            // upper half. preserveScale=true so a tap doesn't snap
            // zoom on top of the translate; only the translation
            // matters here since the user already sees the star.
            // Skip if pendingFocusRequest is already set (AddSheet /
            // SearchSheet already queued a focus and we don't want
            // to fight them).
            if sizeClass == .compact,
               let newValue,
               pendingFocusRequest == nil {
                pendingFocusRequest = FocusRequest(
                    skillId: newValue,
                    preserveScale: true
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let exportURL { ActivityView(items: [exportURL]) }
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .onOpenURL { url in handleInboundFile(url) }
        .alert(
            "Merge snapshot from \(importSourceName)?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingImport = nil }
            Button("Merge") {
                if let p = pendingImport {
                    Task { await performImport(p) }
                }
            }
        } message: {
            if let p = pendingImport {
                Text(
                    "\(p.areas) hobbies · \(p.skills) skills · "
                    + "\(p.sessions) sessions · \(p.notes) notes · "
                    + "\(p.clips) clips\n\n"
                    + "Existing entries merge via CRDT — your local edits won't be lost."
                )
            }
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showSyncSheet) {
            SyncSheet(
                peerSync: context.peerSync,
                onClose: { showSyncSheet = false }
            )
        }
        .sheet(isPresented: $showSearchSheet) {
            SearchSheet(
                skills: skills,
                areas: areas,
                onClose: { showSearchSheet = false },
                onPick: focusOnSearchResult
            )
        }
        .sheet(isPresented: Binding(
            get: { editingArea != nil },
            set: { if !$0 { editingArea = nil } }
        )) {
            if let area = editingArea {
                EditHobbySheet(
                    area: area,
                    store: context.store,
                    onClose: { editingArea = nil },
                    onSaved: {
                        editingArea = nil
                        reloadToken &+= 1
                    },
                    onDeleted: {
                        editingArea = nil
                        activeHobbies.remove(area.id)
                        reloadToken &+= 1
                    }
                )
            }
        }
    }

    // ── iPad layout: canvas + side inspector on selection ──
    private var padLayout: some View {
        ZStack(alignment: .topLeading) {
            canvas
            HobbyFilterView(
                areas: areas,
                active: $activeHobbies,
                skillCount: visibleSkills.count,
                onAdd: { showAddSheet = true },
                onShare: { Task { await prepareExport() } },
                onEdit: { editingArea = $0 },
                onSearch: { showSearchSheet = true },
                syncStatus: context.peerSync.status,
                onSyncTap: { showSyncSheet = true }
            )
            .padding(.top, 12)
            .padding(.leading, 16)
        }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .overlay(alignment: .trailing) {
            if let selectedSkillId,
               let skill = skills.first(where: { $0.id == selectedSkillId })
            {
                SkillDetailView(
                    skill: skill,
                    area: areas.first { $0.id == skill.areaId },
                    allSkills: skills,
                    allAreas: areas,
                    chainActive: chainSkillId == skill.id,
                    store: context.store,
                    assets: context.assets,
                    onClose: { self.selectedSkillId = nil },
                    onSelect: { self.selectedSkillId = $0 },
                    onMutation: { reloadToken &+= 1 },
                    onToggleChain: { toggleChain(for: skill.id) },
                    onSkillAdded: handleAddCompleted,
                    onSkillDeleted: {
                        self.selectedSkillId = nil
                        reloadToken &+= 1
                    }
                )
                .frame(width: 420)
                .background(Theme.Sky.bg2.opacity(0.96))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: selectedSkillId)
        .background(Theme.Sky.bg1.ignoresSafeArea())
    }

    // ── iPhone layout: canvas full-bleed, inspector as half-sheet ──
    private var phoneLayout: some View {
        ZStack(alignment: .topLeading) {
            canvas
            HobbyFilterView(
                areas: areas,
                active: $activeHobbies,
                skillCount: visibleSkills.count,
                onAdd: { showAddSheet = true },
                onShare: { Task { await prepareExport() } },
                onEdit: { editingArea = $0 },
                onSearch: { showSearchSheet = true },
                syncStatus: context.peerSync.status,
                onSyncTap: { showSyncSheet = true }
            )
            .padding(.top, 12)
            .padding(.leading, 12)
        }
        .background(Theme.Sky.bg1.ignoresSafeArea())
        .sheet(isPresented: $showAddSheet) { addSheet }
        .sheet(
            isPresented: Binding(
                get: { selectedSkillId != nil },
                set: { if !$0 { selectedSkillId = nil } }
            )
        ) {
            if let id = selectedSkillId,
               let skill = skills.first(where: { $0.id == id })
            {
                SkillDetailView(
                    skill: skill,
                    area: areas.first { $0.id == skill.areaId },
                    allSkills: skills,
                    allAreas: areas,
                    chainActive: chainSkillId == skill.id,
                    store: context.store,
                    assets: context.assets,
                    onClose: { selectedSkillId = nil },
                    onSelect: { selectedSkillId = $0 },
                    onMutation: { reloadToken &+= 1 },
                    onToggleChain: { toggleChain(for: skill.id) },
                    onSkillAdded: handleAddCompleted,
                    onSkillDeleted: {
                        self.selectedSkillId = nil
                        reloadToken &+= 1
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.Sky.bg2)
                // Let pan/zoom on the canvas keep working while the
                // inspector is parked at .medium — otherwise the user
                // has to dismiss the sheet to look at a neighbouring
                // star. At .large the sheet covers the canvas anyway,
                // so background interaction is moot.
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .preferredColorScheme(.dark)
            }
        }
    }

    private var canvas: some View {
        SkyView(
            skills: visibleSkills,
            areas: areas,
            initialFocus: initialFocus,
            chainSkillIds: chainSkillIds,
            store: context.store,
            onMutation: { reloadToken &+= 1 },
            selectedSkillId: $selectedSkillId,
            focusRequest: $pendingFocusRequest,
            // iPhone's medium-detent inspector covers the bottom ~half
            // of the canvas; aim focus animations at the upper-half
            // centroid so the focused star isn't hidden by the sheet.
            focusVerticalBias: sizeClass == .compact ? 0.25 : 0.5,
            onAdd: { showAddSheet = true }
        )
    }

    // Resolved BFS backward chain for the active target, materialised as
    // a Set so SkyView's per-edge / per-star check is O(1). Empty when
    // no chain is active. Backward = "what's the path to here" — the
    // learning-planning move (forward "what does this unlock" is in the
    // graph if we ever want to toggle).
    private var chainSkillIds: Set<SkillID> {
        guard let id = chainSkillId else { return [] }
        return Set(SkillGraph(skills).backwardChain(from: id))
    }

    private func toggleChain(for id: SkillID) {
        if chainSkillId == id {
            chainSkillId = nil
            return
        }
        chainSkillId = id
        // Make sure every area the chain crosses is visible — otherwise
        // a hidden hobby would silently truncate the trace and the user
        // would see a chain that doesn't actually reach where it comes from.
        let chain = SkillGraph(skills).backwardChain(from: id)
        let bySkillId = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        for sid in chain {
            if let skill = bySkillId[sid] {
                activeHobbies.insert(skill.areaId)
            }
        }
    }

    // Shared between phone + pad sheet modifiers so the add flow is
    // identical regardless of size class.
    private var addSheet: some View {
        AddSheet(
            areas: areas,
            store: context.store,
            onClose: { showAddSheet = false },
            onAdded: { areaId, skillId in
                handleAddCompleted(areaId: areaId, skillId: skillId)
                // Pan/zoom the canvas onto the new star and open its
                // inspector — addresses "easy to lose newly added
                // skills" (they drop at the area center and otherwise
                // disappear behind whatever's at that spot).
                if let skillId {
                    pendingFocusRequest = FocusRequest(skillId: skillId)
                    selectedSkillId = skillId
                }
            }
        )
    }

    // Common bookkeeping after any add (canvas-level or nested in the
    // prereq picker): make the area visible so the new thing isn't
    // hidden behind a toggled-off chip, and bump the reload token so
    // the data flows back through .task(id: reloadToken).
    private func handleAddCompleted(areaId: AreaID, skillId: SkillID?) {
        activeHobbies.insert(areaId)
        reloadToken &+= 1
    }

    // Search sheet picked a skill: make sure its hobby is on (otherwise
    // the star is filtered out and the focus pan lands on empty space),
    // queue the focus animation, and open the inspector. Same pathway
    // used by AddSheet for freshly-added skills, minus the reload bump
    // (search doesn't mutate state).
    private func focusOnSearchResult(_ skill: Skill) {
        activeHobbies.insert(skill.areaId)
        pendingFocusRequest = FocusRequest(skillId: skill.id)
        selectedSkillId = skill.id
    }

    private var visibleSkills: [Skill] {
        skills.filter { activeHobbies.contains($0.areaId) }
    }

    // iPad opens to the whole sky; iPhone fits onto the most active
    // cluster so the user lands somewhere readable instead of into
    // a 4-galaxy soup at 0.3× zoom. Pinch-zoom out reveals the others.
    private var initialFocus: InitialFocus {
        if sizeClass == .compact, let mostActive = mostActiveAreaId {
            return .area(mostActive)
        }
        return .all
    }

    // "Most active" = sum of weighted statuses across the area's
    // skills: drilling counts most (you're actively doing it now),
    // then `next` (queued up), then everything else at zero. Ties
    // resolve by area id (stable, so identical states yield identical
    // landings — important for tests and for "the app should feel
    // consistent between launches").
    private var mostActiveAreaId: AreaID? {
        let byArea = Dictionary(grouping: skills, by: \.areaId)
        let scored = byArea.map { (id, skills) -> (AreaID, Int) in
            let score = skills.reduce(0) { running, skill in
                switch skill.status {
                case .drill: return running + 3
                case .next:  return running + 1
                default:     return running
                }
            }
            return (id, score)
        }
        return scored
            .filter { $0.1 > 0 }
            .max { ($0.1, $1.0.rawValue) < ($1.1, $0.0.rawValue) }?
            .0
    }

    // MARK: - Snapshot sharing (AirDrop)

    private func prepareExport() async {
        do {
            let url = try await SnapshotExport.writeForSharing(store: context.store)
            exportURL = url
        } catch {
            exportError = String(describing: error)
        }
    }

    private func handleInboundFile(_ url: URL) {
        do {
            let preview = try SnapshotImport.preview(from: url)
            importSourceName = url.lastPathComponent
            pendingImport = preview
        } catch {
            importError = "Couldn't read snapshot: \(error)"
        }
    }

    private func performImport(_ preview: SnapshotImport.Preview) async {
        do {
            try await context.store.merge(preview.snapshot)
            pendingImport = nil
            reloadToken &+= 1
        } catch {
            importError = "Merge failed: \(error)"
        }
    }

    private func reload() async {
        do {
            let fetchedAreas = try await context.store.allAreas()
            let fetchedSkills = try await context.store.skills()
            await MainActor.run {
                self.areas = fetchedAreas
                self.skills = fetchedSkills
                if self.activeHobbies.isEmpty {
                    self.activeHobbies = Set(fetchedAreas.map(\.id))
                }
            }
        } catch {
            // Failure to refresh shouldn't crash the canvas — leave the
            // last good state on screen. A future toast could surface
            // this, but the constellation is read-mostly so the
            // user-visible impact of a transient read failure is low.
            print("reload failed: \(error)")
        }
    }
}

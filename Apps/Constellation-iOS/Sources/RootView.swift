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
    // Per-skill newest-N attachments (N=5), used by SkyView to render
    // the zoom-LOD bloom of cover moons (petal 0 = newest, fades in at
    // 1.2→1.6 like the original single moon; petals 1..4 reveal at
    // progressively higher zoom). Derived from store.allAttachments()
    // during reload.
    @State private var coversBySkillId: [SkillID: [AttachmentCover]] = [:]
    // Total attachment count per skill — drives the "+K more" badge on
    // the 5th petal when a skill has more attachments than fit in the
    // bloom.
    @State private var attachmentCountsBySkillId: [SkillID: Int] = [:]
    // Long-lived in-memory thumbnail cache. Created once per RootView
    // instance so a reload doesn't drop already-decoded UIImages on the
    // floor and re-load them from disk.
    @State private var coverCache = CoverCache()
    // Parallel cache for video strip frames — powers the canvas
    // strip-cycle overlay at high zoom. Photos never enter this cache.
    @State private var stripCache = StripCache()
    @State private var activeHobbies: Set<AreaID> = []
    @State private var selectedSkillId: SkillID? = nil
    // Backward-chain overlay state + fade animation. See ChainTrace.
    @State private var chainTrace = ChainTrace()
    @State private var reloadToken: Int = 0
    // Flips true once the first reload completes. The initial reload is
    // the time-to-content tail of cold launch (it runs after app.launch,
    // when the store is ready but the canvas hasn't drawn yet), so the
    // `canvas.reload` event tags it `first=true` to make that slice
    // queryable alongside `app.launch`.
    @State private var didFirstReload: Bool = false
    @State private var showAddSheet: Bool = false
    // Multi-select mode: when on, taps toggle stars in/out of
    // `selectedSkillIds`, long-press-drag on a selected star moves the
    // whole group, and the inspector is suppressed so the canvas stays
    // the foreground surface. Exiting the mode (or saving) clears the
    // set automatically.
    @State private var isSelectMode: Bool = false
    @State private var selectedSkillIds: Set<SkillID> = []
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
        // App-wide import feedback. Lives here, not in the inspector, so
        // a success/failure banner shows even after the inspector that
        // started the import has been closed. Auto-dismisses; a fresh
        // toast restarts the timer via the keyed .task.
        .overlay(alignment: .bottom) {
            if let toast = context.importer.toast {
                Button {
                    if let skill = skills.first(where: { $0.id == toast.skillId }) {
                        focusOnSearchResult(skill)
                    }
                    context.importer.toast = nil
                } label: {
                    importToast(toast)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 48)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(2.5))
                    if !Task.isCancelled {
                        context.importer.toast = nil
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: context.importer.toast?.id)
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
        // An app-scoped media import finished an item — refresh so the
        // canvas picks up the new cover moons (the import may have
        // completed after the inspector was closed). This also kicks a
        // peer push via the reloadToken handler above.
        .onChange(of: context.importer.completedCount) { _, _ in
            reloadToken &+= 1
        }
        // Navigating to a different skill invalidates the chain overlay
        // (it explained the previous context, not this one). Closing
        // the inspector (newValue == nil) deliberately leaves it on —
        // the trace stays visible for a moment so the user can keep
        // referring to it, and clears on the next canvas gesture
        // via onCanvasGesture below.
        .onChange(of: selectedSkillId) { _, newValue in
            if let newValue, newValue != chainTrace.targetId {
                // Selecting a different skill is an intent change —
                // drop the previous chain instantly and pre-empt any
                // in-flight fade so the next TRACE renders crisply.
                chainTrace.clear()
            }
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
        // Leaving select mode clears the selection so re-entering
        // starts fresh, and drops any in-flight multi-drag that
        // SkyView is still rendering an override for.
        .onChange(of: isSelectMode) { _, newValue in
            if !newValue {
                selectedSkillIds = []
            } else {
                // Hide the inspector on entering — multi-select and a
                // single-skill detail sheet would fight for the bottom
                // half of the canvas.
                selectedSkillId = nil
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

    // Glass capsule banner for import success/failure, styled to match
    // the canvas chrome (reset-view / `+` buttons).
    @ViewBuilder
    private func importToast(_ toast: ImportCoordinator.Toast) -> some View {
        HStack(spacing: 8) {
            Image(
                systemName: toast.isError
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill"
            )
            .foregroundStyle(toast.isError ? Color.orange : Theme.Sky.chain)
            Text(toast.message)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(Theme.Sky.star)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Theme.Sky.bg3)
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }

    // ── iPad layout: canvas + side inspector on selection ──
    private var padLayout: some View {
        ZStack(alignment: .topLeading) {
            canvas
            VStack(alignment: .leading, spacing: 12) {
                HobbyFilterView(
                    areas: areas,
                    active: $activeHobbies,
                    skillCount: visibleSkills.count,
                    onShare: { Task { await prepareExport() } },
                    onEdit: { editingArea = $0 },
                    onSearch: { showSearchSheet = true },
                    syncStatus: context.peerSync.status,
                    onSyncTap: { showSyncSheet = true }
                )
                HStack(spacing: 10) {
                    addCanvasButton
                    selectModeButton
                }
            }
            .padding(.top, 12)
            .padding(.leading, 16)
            if isSelectMode {
                selectModeBanner
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 12)
            }
        }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .overlay(alignment: .trailing) {
            if !isSelectMode,
               let selectedSkillId,
               let skill = skills.first(where: { $0.id == selectedSkillId })
            {
                SkillDetailView(
                    skill: skill,
                    area: areas.first { $0.id == skill.areaId },
                    allSkills: skills,
                    allAreas: areas,
                    chainActive: chainTrace.targetId == skill.id,
                    store: context.store,
                    assets: context.assets,
                    importer: context.importer,
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
            VStack(alignment: .leading, spacing: 12) {
                HobbyFilterView(
                    areas: areas,
                    active: $activeHobbies,
                    skillCount: visibleSkills.count,
                    onShare: { Task { await prepareExport() } },
                    onEdit: { editingArea = $0 },
                    onSearch: { showSearchSheet = true },
                    syncStatus: context.peerSync.status,
                    onSyncTap: { showSyncSheet = true }
                )
                HStack(spacing: 10) {
                    addCanvasButton
                    selectModeButton
                }
            }
            .padding(.top, 12)
            .padding(.leading, 12)
            if isSelectMode {
                selectModeBanner
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 12)
            }
        }
        .background(Theme.Sky.bg1.ignoresSafeArea())
        .sheet(isPresented: $showAddSheet) { addSheet }
        .sheet(
            isPresented: Binding(
                get: { !isSelectMode && selectedSkillId != nil },
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
                    chainActive: chainTrace.targetId == skill.id,
                    store: context.store,
                    assets: context.assets,
                    importer: context.importer,
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
            chainSkillIds: chainTrace.litSkillIds(in: skills),
            chainHighlightOpacity: chainTrace.opacity,
            coversBySkillId: coversBySkillId,
            attachmentCountsBySkillId: attachmentCountsBySkillId,
            coverCache: coverCache,
            stripCache: stripCache,
            store: context.store,
            onMutation: { reloadToken &+= 1 },
            selectedSkillId: $selectedSkillId,
            focusRequest: $pendingFocusRequest,
            // iPhone's medium-detent inspector covers the bottom ~half
            // of the canvas; aim focus animations at the upper-half
            // centroid so the focused star isn't hidden by the sheet.
            focusVerticalBias: sizeClass == .compact ? 0.25 : 0.5,
            isSelectMode: isSelectMode,
            multiSelectedIds: $selectedSkillIds,
            // Pan or pinch clears a lingering chain trace — the
            // overlay is meant to explain a specific selection, not
            // float around indefinitely. ChainTrace fades it out over
            // 2s instead of dropping instantly (see beginFadeOut).
            onCanvasGesture: { chainTrace.beginFadeOut() }
        )
    }

    // Floating "+" button rendered below HobbyFilterView at top-leading.
    // Same glass/stroke styling as the canvas's reset-view button.
    // Primary on-canvas affordance for adding skills/hobbies; replaced
    // the header `+` in HobbyFilterView (too hidden) and the bottom-
    // leading version that lived in SkyView before 2026-05-27.
    private var addCanvasButton: some View {
        Button(action: { showAddSheet = true }) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(.black.opacity(0.30))
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add skill or hobby")
        .disabled(isSelectMode)
        .opacity(isSelectMode ? 0.45 : 1.0)
    }

    // Status pill that floats at the top while select mode is on so
    // the user can see (a) what mode they're in and (b) how many
    // stars are currently selected. Long-press-drag affordance is
    // implicit — the count crossing 2 silently unlocks group move.
    @ViewBuilder
    private var selectModeBanner: some View {
        let count = selectedSkillIds.count
        let label: String = {
            switch count {
            case 0: return "Tap stars to select"
            case 1: return "1 selected — pick more, then drag"
            default: return "\(count) selected — long-press to move"
            }
        }()
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .foregroundStyle(Theme.Sky.chain)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.black.opacity(0.40))
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Theme.Sky.chain.opacity(0.55), lineWidth: 1))
        )
        .accessibilityLabel(label)
        .allowsHitTesting(false)
    }

    // Toggle pill for entering / leaving select mode. While on, taps
    // toggle stars in/out of the selection set instead of opening the
    // inspector, and long-press-drag on a selected star translates the
    // whole group. The pill itself reads selected by inverting its
    // fill so it's obviously a mode and not a one-shot action.
    private var selectModeButton: some View {
        Button(action: { isSelectMode.toggle() }) {
            Image(systemName: isSelectMode
                ? "cursorarrow.click.2"
                : "cursorarrow.click")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelectMode
                    ? Theme.Sky.bg1
                    : .white.opacity(0.85))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isSelectMode
                            ? AnyShapeStyle(Theme.Sky.chain)
                            : AnyShapeStyle(.black.opacity(0.30)))
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelectMode ? "Exit select mode" : "Enter select mode")
    }

    private func toggleChain(for id: SkillID) {
        let chain = chainTrace.toggle(to: id, in: skills)
        // Make sure every area the chain crosses is visible — otherwise
        // a hidden hobby would silently truncate the trace and the user
        // would see a chain that doesn't actually reach where it comes from.
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
        let start = Date()
        let isFirst = !didFirstReload
        do {
            let fetchedAreas = try await context.store.allAreas()
            let fetchedSkills = try await context.store.skills()
            let fetchedAttachments = try await context.store.allAttachments()
            // Store reads done — the canvas can draw from here. The
            // thumbnail/strip prefetch below happens after the paint and
            // fills moons in progressively, so splitting fetch from
            // prefetch separates "time to stars on screen" from "time to
            // media decoded".
            let fetchMs = Date().timeIntervalSince(start) * 1000
            // Newest-N attachments per skill (allAttachments is ordered
            // newest-first). Becomes SkyView's coversBySkillId — drives
            // the zoom-LOD bloom of moons (up to 5 visible at peak zoom)
            // plus a +K more badge keyed off the total count. Photo and
            // video both flow through here; the renderer reads
            // mediaType to decide whether to look in StripCache.
            var covers: [SkillID: [AttachmentCover]] = [:]
            var counts: [SkillID: Int] = [:]
            for a in fetchedAttachments {
                counts[a.skillId, default: 0] += 1
                if (covers[a.skillId]?.count ?? 0) < 5 {
                    covers[a.skillId, default: []].append(
                        AttachmentCover(
                            id: a.id,
                            contentHash: a.contentHash,
                            mediaType: a.mediaType
                        )
                    )
                }
            }
            let coverHashes: Set<String> = Set(
                covers.values.flatMap { $0.map(\.contentHash) }
            )
            let stripHashes: Set<String> = Set(
                covers.values.flatMap {
                    $0.compactMap { $0.mediaType == .video ? $0.contentHash : nil }
                }
            )
            await MainActor.run {
                self.areas = fetchedAreas
                self.skills = fetchedSkills
                self.coversBySkillId = covers
                self.attachmentCountsBySkillId = counts
                if self.activeHobbies.isEmpty {
                    self.activeHobbies = Set(fetchedAreas.map(\.id))
                }
            }
            // Prefetch any new thumbnails / strip frames into the
            // in-memory caches, and drop any that are no longer
            // referenced — keeps both caches bounded as attachments
            // come and go.
            await coverCache.prefetch(hashes: coverHashes, from: context.assets)
            await coverCache.evict(except: coverHashes)
            await stripCache.prefetch(hashes: stripHashes, from: context.assets)
            await stripCache.evict(except: stripHashes)
            let totalMs = Date().timeIntervalSince(start) * 1000
            didFirstReload = true
            try? await context.store.emit(WideEvent(
                op: "canvas.reload",
                outcome: .ok,
                durationMs: totalMs,
                fields: [
                    "first": .bool(isFirst),
                    "fetch_ms": .double(fetchMs),
                    "prefetch_ms": .double(totalMs - fetchMs),
                    "areas": .int(Int64(fetchedAreas.count)),
                    "skills": .int(Int64(fetchedSkills.count)),
                    "attachments": .int(Int64(fetchedAttachments.count)),
                    "cover_hashes": .int(Int64(coverHashes.count)),
                    "strip_hashes": .int(Int64(stripHashes.count)),
                ]
            ))
        } catch {
            // Failure to refresh shouldn't crash the canvas — leave the
            // last good state on screen. Surface it as a wide event so a
            // silent read failure on the primary data path is at least
            // visible in the journal / Console.
            try? await context.store.emit(WideEvent(
                op: "canvas.reload",
                outcome: .error,
                durationMs: Date().timeIntervalSince(start) * 1000,
                fields: [
                    "first": .bool(isFirst),
                    "error": .string(String(describing: error)),
                ]
            ))
        }
    }
}

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
    // Source of an active chain-trace overlay (nil = no trace). Nullified
    // whenever the user navigates away from the trace source so the chain
    // can't outlive the context that explains it.
    @State private var chainSkillId: SkillID? = nil
    @State private var reloadToken: Int = 0
    @State private var showAddSheet: Bool = false

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
        // Navigating to (or closing) any skill other than the trace
        // source invalidates the overlay — a chain stranded next to an
        // unrelated inspector is just visual noise.
        .onChange(of: selectedSkillId) { _, newValue in
            if newValue != chainSkillId { chainSkillId = nil }
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
                onAdd: { showAddSheet = true }
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
                    onClose: { self.selectedSkillId = nil },
                    onSelect: { self.selectedSkillId = $0 },
                    onMutation: { reloadToken &+= 1 },
                    onToggleChain: { toggleChain(for: skill.id) }
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
                onAdd: { showAddSheet = true }
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
                    onClose: { selectedSkillId = nil },
                    onSelect: { selectedSkillId = $0 },
                    onMutation: { reloadToken &+= 1 },
                    onToggleChain: { toggleChain(for: skill.id) }
                )
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.Sky.bg2)
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
            selectedSkillId: $selectedSkillId
        )
    }

    // Resolved BFS forward chain for the active source, materialised as
    // a Set so SkyView's per-edge / per-star check is O(1). Empty when
    // no chain is active.
    private var chainSkillIds: Set<SkillID> {
        guard let id = chainSkillId else { return [] }
        return Set(SkillGraph(skills).forwardChain(from: id))
    }

    private func toggleChain(for id: SkillID) {
        if chainSkillId == id {
            chainSkillId = nil
            return
        }
        chainSkillId = id
        // Make sure every area the chain crosses is visible — otherwise
        // a hidden hobby would silently truncate the trace and the user
        // would see a chain that doesn't actually reach where it goes.
        let chain = SkillGraph(skills).forwardChain(from: id)
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
            onAdded: { areaId in
                // Make sure the just-added thing's area is visible —
                // otherwise the user "added" something they can't see.
                activeHobbies.insert(areaId)
                reloadToken &+= 1
            }
        )
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

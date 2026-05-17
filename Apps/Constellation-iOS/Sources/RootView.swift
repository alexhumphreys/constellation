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
    @State private var reloadToken: Int = 0

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
    }

    // ── iPad layout: canvas + side inspector on selection ──
    private var padLayout: some View {
        ZStack(alignment: .topLeading) {
            canvas
            HobbyFilterView(
                areas: areas,
                active: $activeHobbies,
                skillCount: visibleSkills.count
            )
            .padding(.top, 12)
            .padding(.leading, 16)
        }
        .overlay(alignment: .trailing) {
            if let selectedSkillId,
               let skill = skills.first(where: { $0.id == selectedSkillId })
            {
                SkillDetailView(
                    skill: skill,
                    area: areas.first { $0.id == skill.areaId },
                    allSkills: skills,
                    allAreas: areas,
                    store: context.store,
                    onClose: { self.selectedSkillId = nil },
                    onSelect: { self.selectedSkillId = $0 },
                    onMutation: { reloadToken &+= 1 }
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
                skillCount: visibleSkills.count
            )
            .padding(.top, 12)
            .padding(.leading, 12)
        }
        .background(Theme.Sky.bg1.ignoresSafeArea())
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
                    store: context.store,
                    onClose: { selectedSkillId = nil },
                    onSelect: { selectedSkillId = $0 },
                    onMutation: { reloadToken &+= 1 }
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
            selectedSkillId: $selectedSkillId
        )
    }

    private var visibleSkills: [Skill] {
        skills.filter { activeHobbies.contains($0.areaId) }
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

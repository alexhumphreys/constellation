import ConstellationCore
import SwiftUI

// Inverse of PrereqPickerSheet: instead of "which skills come before
// this one?", asks "which skills does this one unlock?". The data model
// has no `unlocks` field — unlocks are derived from other skills'
// prereqIds/softPrereqIds. So saving here writes to N other skills'
// prereq lists rather than to this skill, which means N upsertSkill
// calls (and N `skill.upsert` wide events). Acceptable: edits are
// user-driven so N is small, and the store stays the source of truth
// without us introducing a denormalised `unlockIds` field that would
// drift out of sync with the prereq edges.
struct UnlocksPickerSheet: View {
    let skill: Skill
    let allSkills: [Skill]
    let allAreas: [Area]
    let store: Store
    let onClose: () -> Void
    let onSaved: () -> Void
    let onSkillAdded: (AreaID, SkillID?) -> Void

    enum Kind { case hard, soft }

    @State private var picks: [SkillID: Kind] = [:]
    // Snapshot of the initial state so save can compute a diff. Needed
    // because removals (was-set, now-off) require touching the
    // candidate's prereq list too, not just additions.
    @State private var initialPicks: [SkillID: Kind] = [:]
    @State private var showAllAreas: Bool = false
    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showAddSheet: Bool = false

    private var areasById: [AreaID: Area] {
        Dictionary(uniqueKeysWithValues: allAreas.map { ($0.id, $0) })
    }

    private var candidates: [Skill] {
        allSkills
            .filter { $0.id != skill.id && !$0.isDeleted }
            .filter { showAllAreas || $0.areaId == skill.areaId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var currentAreaName: String {
        areasById[skill.areaId]?.name ?? "this hobby"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show all hobbies", isOn: $showAllAreas)
                } footer: {
                    Text("By default only skills in \(currentAreaName) are shown.")
                        .font(.caption2)
                }

                // Same chain-creation affordance as PrereqPickerSheet —
                // useful when the next-step skill doesn't exist yet.
                Section {
                    Button {
                        showAddSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Theme.Sky.chain)
                            Text("Create new skill")
                                .foregroundStyle(Theme.Sky.star)
                            Spacer()
                        }
                    }
                }

                if candidates.isEmpty {
                    Section {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                } else {
                    Section(showAllAreas ? "All skills" : currentAreaName) {
                        ForEach(candidates, id: \.id) { candidate in
                            row(for: candidate)
                        }
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
            .navigationTitle("Unlocks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear(perform: seedPicks)
            .sheet(isPresented: $showAddSheet) {
                AddSheet(
                    areas: allAreas,
                    store: store,
                    onClose: { showAddSheet = false },
                    onAdded: { areaId, newSkillId in
                        onSkillAdded(areaId, newSkillId)
                        if let newSkillId {
                            picks[newSkillId] = .hard
                            if areaId != skill.areaId {
                                showAllAreas = true
                            }
                        }
                    },
                    seedSkill: skill
                )
            }
        }
    }

    private var emptyMessage: String {
        if showAllAreas {
            return "No other skills exist yet — use 'Create new skill' above."
        }
        return "No other skills in \(currentAreaName). Toggle 'Show all hobbies' to wire cross-hobby unlocks."
    }

    private func row(for candidate: Skill) -> some View {
        HStack(spacing: 10) {
            let tint = areasById[candidate.areaId]?.color ?? .gray
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint.opacity(0.7), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(Theme.Sky.star)
                if candidate.areaId != skill.areaId,
                   let other = areasById[candidate.areaId]
                {
                    Text(other.name.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(other.color.opacity(0.8))
                }
            }
            Spacer(minLength: 8)
            kindPicker(for: candidate.id)
        }
        .padding(.vertical, 2)
    }

    private func kindPicker(for id: SkillID) -> some View {
        let current = picks[id]
        return HStack(spacing: 4) {
            pill("off", active: current == nil) {
                picks.removeValue(forKey: id)
            }
            pill("hard", active: current == .hard) {
                picks[id] = .hard
            }
            pill("soft", active: current == .soft) {
                picks[id] = .soft
            }
        }
    }

    private func pill(
        _ label: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(active ? Theme.Sky.chain.opacity(0.25) : .clear)
                )
                .overlay(
                    Capsule().stroke(
                        active ? Theme.Sky.chain : .white.opacity(0.18),
                        lineWidth: 1
                    )
                )
                .foregroundStyle(active ? Theme.Sky.chain : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    // Walk every other skill; a candidate is currently picked iff our
    // skill.id appears in its prereq list. Auto-flip the cross-area
    // toggle if any current unlock lives in another hobby — without it
    // the user would open the picker and see their cross-area unlocks
    // missing from the visible list.
    private func seedPicks() {
        var initial: [SkillID: Kind] = [:]
        var crossArea = false
        for candidate in allSkills where candidate.id != skill.id {
            if candidate.prereqIds.contains(skill.id) {
                initial[candidate.id] = .hard
                if candidate.areaId != skill.areaId { crossArea = true }
            } else if candidate.softPrereqIds.contains(skill.id) {
                initial[candidate.id] = .soft
                if candidate.areaId != skill.areaId { crossArea = true }
            }
        }
        picks = initial
        initialPicks = initial
        if crossArea { showAllAreas = true }
    }

    private func save() {
        saving = true
        errorMessage = nil
        let mySkillId = skill.id
        let before = initialPicks
        let after = picks
        // Diff: union of keys with state that differs. Each entry is
        // one candidate that needs its prereq list rewritten + a
        // single upsertSkill call.
        let changedIds = Set(before.keys).union(after.keys).filter { id in
            before[id] != after[id]
        }
        Task {
            do {
                for cid in changedIds {
                    guard var c = try await store.skill(cid) else { continue }
                    c.prereqIds.removeAll { $0 == mySkillId }
                    c.softPrereqIds.removeAll { $0 == mySkillId }
                    switch after[cid] {
                    case .hard:
                        c.prereqIds.append(mySkillId)
                    case .soft:
                        c.softPrereqIds.append(mySkillId)
                    case nil:
                        break
                    }
                    c.prereqIds.sort { $0.rawValue < $1.rawValue }
                    c.softPrereqIds.sort { $0.rawValue < $1.rawValue }
                    c.updatedAt = Date()
                    try await store.upsertSkill(c)
                }
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

import ConstellationCore
import SwiftUI

// Sheet for editing a skill's hard + soft prereqs. Mirrors the CLI's
// `skill prereqs <id> <prereq-ids...>` but adds the UI affordances a
// phone wants: a candidate list filtered to the same area by default
// (toggle for cross-hobby prereqs), and a three-way per-row picker
// (off / hard / soft) instead of forcing the user to type IDs.
//
// Save path goes through Store.upsertSkill so LWW + `skill.upsert`
// wide events behave identically to the CLI.
struct PrereqPickerSheet: View {
    let skill: Skill
    let allSkills: [Skill]
    let allAreas: [Area]
    let store: Store
    let onClose: () -> Void
    let onSaved: () -> Void

    enum Kind { case hard, soft }

    @State private var picks: [SkillID: Kind] = [:]
    @State private var showAllAreas: Bool = false
    @State private var saving: Bool = false
    @State private var errorMessage: String? = nil

    private var areasById: [AreaID: Area] {
        Dictionary(uniqueKeysWithValues: allAreas.map { ($0.id, $0) })
    }

    // Exclude self (a self-loop is meaningless) but allow cycles
    // through other skills — graph traversals are depth-bounded with
    // seen-sets, and soft "these two reinforce each other" cycles are
    // a legitimate way to model mutually-reinforcing skills.
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
            .navigationTitle("Prerequisites")
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
        }
    }

    private var emptyMessage: String {
        if showAllAreas {
            return "No other skills exist yet — add some from the '+' button."
        }
        return "No other skills in \(currentAreaName). Toggle 'Show all hobbies' to wire cross-hobby prereqs."
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

    private func seedPicks() {
        var initial: [SkillID: Kind] = [:]
        for id in skill.prereqIds { initial[id] = .hard }
        for id in skill.softPrereqIds { initial[id] = .soft }
        picks = initial
        // If any existing prereq lives outside the current area, default
        // the cross-area toggle on — otherwise the user opens the sheet
        // and can't see the prereqs they've already wired up.
        let hasCrossArea = initial.keys.contains { id in
            guard let s = allSkills.first(where: { $0.id == id }) else { return false }
            return s.areaId != skill.areaId
        }
        if hasCrossArea { showAllAreas = true }
    }

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            do {
                guard var updated = try await store.skill(skill.id) else {
                    throw FormError("skill no longer exists")
                }
                updated.prereqIds = picks
                    .filter { $0.value == .hard }
                    .map { $0.key }
                    .sorted { $0.rawValue < $1.rawValue }
                updated.softPrereqIds = picks
                    .filter { $0.value == .soft }
                    .map { $0.key }
                    .sorted { $0.rawValue < $1.rawValue }
                updated.updatedAt = Date()
                try await store.upsertSkill(updated)
                await MainActor.run { onSaved() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    saving = false
                }
            }
        }
    }

    private struct FormError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

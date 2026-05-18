import ConstellationCore
import SwiftUI

// Keyboard-first skill lookup. Opens with the keyboard up and the field
// focused; typing filters skills across every hobby (including ones the
// user has chip-toggled off — picking one activates the hobby on the
// way out, same pathway the add flow uses for freshly-created stars).
//
// Match against `name + aliases`. Scoring is intentionally coarse for
// v1: prefix > contains, name > alias; ties broken by name length so
// shorter (more specific) matches sort first. Hundreds-of-skills scale
// doesn't need a real fuzzy algorithm yet — if that changes, swap
// `match(_:against:)` for a Levenshtein-or-better implementation
// without touching the call site.
struct SearchSheet: View {
    let skills: [Skill]
    let areas: [Area]
    let onClose: () -> Void
    // Sender hands back the chosen skill — RootView turns this into
    // (activate hobby, focus canvas, open inspector). Done as a
    // callback rather than a binding so the sheet can dismiss cleanly
    // before the focus animation starts (avoids the visual fight
    // between sheet dismissal and the canvas pan-zoom).
    let onPick: (Skill) -> Void

    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool

    private var areasById: [AreaID: Area] {
        Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0) })
    }

    private var results: [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return skills
            .filter { !$0.isDeleted }
            .compactMap { skill -> Match? in
                guard let hit = bestHit(in: skill, query: q) else { return nil }
                return Match(skill: skill, hit: hit)
            }
            .sorted { a, b in
                if a.hit.score != b.hit.score { return a.hit.score > b.hit.score }
                if a.skill.name.count != b.skill.name.count {
                    return a.skill.name.count < b.skill.name.count
                }
                return a.skill.name.localizedCaseInsensitiveCompare(b.skill.name)
                    == .orderedAscending
            }
            .prefix(25)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider().background(.white.opacity(0.10))
                resultList
            }
            .background(Theme.Sky.bg2)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear { fieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.45))
            TextField("Search skills…", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    if let first = results.first {
                        commit(first.skill)
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var resultList: some View {
        if query.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("Type to search skills by name or alias.")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No matches.")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results, id: \.skill.id) { match in
                        Button { commit(match.skill) } label: {
                            row(match: match)
                        }
                        .buttonStyle(.plain)
                        Divider().background(.white.opacity(0.06))
                    }
                }
            }
        }
    }

    private func row(match: Match) -> some View {
        let area = areasById[match.skill.areaId]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(area?.color ?? .gray)
                .frame(width: 7, height: 7)
                .shadow(color: (area?.color ?? .gray).opacity(0.7), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.skill.name)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(Theme.Sky.star)
                HStack(spacing: 6) {
                    if let area {
                        Text(area.name.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(area.color.opacity(0.85))
                    }
                    Text("·")
                        .foregroundStyle(.white.opacity(0.25))
                    Text(match.skill.status.displayLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                    if case .alias(let alias) = match.hit.kind {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.25))
                        Text("via \"\(alias)\"")
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func commit(_ skill: Skill) {
        onPick(skill)
        onClose()
    }
}

// Scoring: 3 = exact-equal, 2 = prefix, 1 = substring; name +1
// over alias for the same tier. Negative means no hit. The skill
// keeps the best (highest-scoring) hit across all candidates so a
// row that matches via both name and alias renders the name match,
// not the alias.
private struct Match {
    let skill: Skill
    let hit: Hit
}

private enum HitKind {
    case name
    case alias(String)
}

private struct Hit {
    let score: Int
    let kind: HitKind
}

private func bestHit(in skill: Skill, query q: String) -> Hit? {
    var best: Hit? = nil

    if let s = score(q, against: skill.name) {
        // Name match gets a +1 nudge over alias matches at the same
        // tier so "Crochet" beats an alias "Crochet" on a different
        // skill with the same query.
        best = Hit(score: s + 1, kind: .name)
    }

    for alias in skill.aliases {
        if let s = score(q, against: alias) {
            if best == nil || s > (best?.score ?? Int.min) {
                best = Hit(score: s, kind: .alias(alias))
            }
        }
    }
    return best
}

// 3 = whole-string match, 2 = prefix, 1 = anywhere-substring, nil = no
// hit. Lowercased on both sides because the query is already
// lowercased by the caller — saves a per-skill allocation when there
// are dozens of candidates.
private func score(_ q: String, against haystack: String) -> Int? {
    let lower = haystack.lowercased()
    if lower == q { return 3 }
    if lower.hasPrefix(q) { return 2 }
    if lower.contains(q) { return 1 }
    return nil
}

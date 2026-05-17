import ConstellationCore
import SwiftUI

// The drawer / sheet shown when a star is tapped. Mirrors the design's
// SkillDrawer:
//   header (area chip + name + status pill + Save/Trace buttons)
//   prereqs / unlocks chip rows
//   sessions list
//   notes list
// v1 supports: changing the skill's status, jumping to a neighbour
// (which keeps the drawer open on the new skill), adding a session
// or note inline. Deferred: clips UI, chain tracing.
struct SkillDetailView: View {
    let skill: Skill
    let area: Area?
    let allSkills: [Skill]
    let allAreas: [Area]
    let store: Store

    private var areasById: [AreaID: Area] {
        Dictionary(uniqueKeysWithValues: allAreas.map { ($0.id, $0) })
    }

    let onClose: () -> Void
    let onSelect: (SkillID) -> Void
    let onMutation: () -> Void

    @State private var sessions: [Session] = []
    @State private var notes: [Note] = []
    @State private var draftSession: String = ""
    @State private var draftNote: String = ""
    @State private var isSaving: Bool = false
    @State private var showPrereqPicker: Bool = false

    private var graph: SkillGraph { SkillGraph(allSkills) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusPicker
                prereqsBlock(neighbours: graph.neighbours(of: skill.id))
                if let n = graph.neighbours(of: skill.id), !n.unlocks.isEmpty {
                    section("THIS UNLOCKS") {
                        chipRow(n.unlocks)
                    }
                }
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
                }
            )
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
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                        .imageScale(.large)
                }
            }
            Text(skill.name)
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Theme.Sky.star)
        }
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
            await MainActor.run {
                self.sessions = s
                self.notes = n
            }
        } catch {
            print("detail reload failed: \(error)")
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

import ConstellationCore
import SwiftUI

// Top-bar hobby filter — one chip per area, tap to toggle visibility.
// Adaptive: on regular-width (iPad) chips lay out horizontally with the
// star count to the side; on compact (iPhone) the chips wrap so even
// the long names ("Springboard Diving") stay legible without
// horizontal scroll.
struct HobbyFilterView: View {
    let areas: [Area]
    @Binding var active: Set<AreaID>
    let skillCount: Int
    let onAdd: () -> Void
    let onShare: () -> Void
    // Long-press on a chip → contextMenu → "Edit hobby" hands the area
    // off to RootView, which opens EditHobbySheet. Kept as a callback
    // rather than presenting the sheet from here so the parent owns
    // sheet state alongside the other top-level sheets.
    let onEdit: (Area) -> Void
    let onSearch: () -> Void
    let syncStatus: PeerSync.Status
    let onSyncTap: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("MY SKY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))
                Button(action: onSyncTap) {
                    SyncPill(status: syncStatus)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync settings")
                Spacer(minLength: 8)
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search skills")
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share snapshot via AirDrop")
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add skill or hobby")
            }
            Text("\(skillCount) stars · \(areas.count) hobbies")
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(Theme.Sky.star)
            chips
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.30))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                )
        )
    }

    private var chips: some View {
        // FlowLayout would be ideal here but it's iOS 16-only / awkward;
        // a wrapped HStack via LazyVGrid keeps the chip set on one or
        // two lines without requiring a custom layout.
        let columns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 4)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(areas, id: \.id) { area in
                Chip(
                    area: area,
                    on: active.contains(area.id),
                    toggle: { toggle(area.id) },
                    onEdit: { onEdit(area) }
                )
            }
        }
        .padding(.top, 4)
    }

    private func toggle(_ id: AreaID) {
        if active.contains(id) {
            active.remove(id)
        } else {
            active.insert(id)
        }
    }
}

// Compact peer-sync indicator. Kept terse on purpose — it sits next to
// MY SKY and shouldn't crowd the title. Tappable target deferred until
// we know we want a settings sheet; for now it's pure status. Pill
// switches between "SEARCHING", "PAIRED N", and "SYNCED N · 5s" so the
// user can tell at a glance whether the other device is reachable.
private struct SyncPill: View {
    let status: PeerSync.Status
    // TimelineView so "SYNCED · 2m" ticks forward without RootView
    // having to bump state every minute. 30s schedule is finer than the
    // labels need but cheap enough.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var icon: String {
        switch status {
        case .off:                  return "wifi.slash"
        case .idle, .searching:     return "magnifyingglass"
        case .connected:            return "personalhotspot"
        case .synced:               return "checkmark.circle"
        case .error:                return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch status {
        case .off:                  return .white.opacity(0.35)
        case .idle, .searching:     return .white.opacity(0.55)
        case .connected:            return .white.opacity(0.75)
        case .synced:               return Theme.Sky.star.opacity(0.9)
        case .error:                return .red.opacity(0.85)
        }
    }

    private var label: String {
        switch status {
        case .off:                          return "OFF"
        case .idle:                         return "IDLE"
        case .searching:                    return "SEARCHING"
        case .connected(let n):             return "PAIRED \(n)"
        case .synced(let at, let n):        return "SYNCED \(n) \(Self.relative(at))"
        case .error:                        return "ERROR"
        }
    }

    // Compact relative-time formatter. Avoids RelativeDateTimeFormatter's
    // verbose "2 minutes ago" wording — at 9pt we need single-token
    // labels ("2m", "5s", "1h") so the pill stays narrow.
    private static func relative(_ date: Date) -> String {
        let secs = max(0, Int(-date.timeIntervalSinceNow))
        if secs < 5 { return "NOW" }
        if secs < 60 { return "\(secs)S" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)M" }
        let hours = mins / 60
        return "\(hours)H"
    }
}

private struct Chip: View {
    let area: Area
    let on: Bool
    let toggle: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(area.color)
                    .frame(width: 6, height: 6)
                    .shadow(color: area.color.opacity(on ? 0.8 : 0),
                            radius: 4)
                Text(area.id.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(on ? .white.opacity(0.10) : .clear)
            )
            .overlay(
                Capsule().stroke(
                    on ? .white.opacity(0.30) : .white.opacity(0.10),
                    lineWidth: 1
                )
            )
            .foregroundStyle(on ? .white : .white.opacity(0.45))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit hobby", systemImage: "pencil")
            }
        }
    }
}

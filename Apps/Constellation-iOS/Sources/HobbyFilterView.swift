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

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MY SKY")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.4))
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
                    toggle: { toggle(area.id) }
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

private struct Chip: View {
    let area: Area
    let on: Bool
    let toggle: () -> Void

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
    }
}

import SwiftUI

// Ported from the design's PALETTES.night — the dark "actual sky" palette
// the user picked over the alternatives. Other palettes (dusk, ink) live
// in the prototype's sky-utils.js if we want a toggle later; v1 ships
// night only.
enum Theme {
    enum Sky {
        static let bg1 = Color(red: 0.027, green: 0.039, blue: 0.094)  // #070a18
        static let bg2 = Color(red: 0.047, green: 0.071, blue: 0.157)  // #0c1228
        static let bg3 = Color(red: 0.086, green: 0.106, blue: 0.227)  // #161b3a
        static let star = Color(red: 0.965, green: 0.953, blue: 0.910) // #f6f3e8
        static let starDim = Color(red: 0.737, green: 0.725, blue: 0.659) // #bcb9a8
        static let chain = Color(red: 0.969, green: 0.835, blue: 0.420)  // #f7d56b
        static let asterism = Color.white.opacity(0.10)
    }
}

// Per-status visual treatment matching the design's STATUS table.
// `glow` is the radius of the soft halo behind the star; `size` is the
// star's radius. `ringStyle` is reserved for the dashed/pulse rings —
// v1 just renders the dashed ring for `.next`; pulse for `.drill` is
// deferred so the canvas stays simple.
struct StatusVisual: Hashable {
    let size: CGFloat
    let glow: CGFloat
    let opacity: Double
    let ring: Ring

    enum Ring: Hashable { case none, dashed, pulse }

    static func of(_ status: SkillStatus) -> StatusVisual {
        switch status {
        case .master: StatusVisual(size: 4.5, glow: 18, opacity: 1.00, ring: .none)
        case .got:    StatusVisual(size: 3.5, glow: 10, opacity: 0.95, ring: .none)
        case .drill:  StatusVisual(size: 4.0, glow: 22, opacity: 1.00, ring: .pulse)
        case .next:   StatusVisual(size: 3.2, glow: 14, opacity: 0.90, ring: .dashed)
        case .wish:   StatusVisual(size: 2.4, glow: 6,  opacity: 0.75, ring: .none)
        case .locked: StatusVisual(size: 1.8, glow: 0,  opacity: 0.45, ring: .none)
        }
    }
}

import ConstellationCore

// Parse the area's 6-digit hex tint into a SwiftUI Color. Falls back to
// gray on garbage input rather than throwing — the canvas should keep
// rendering even if one area's tint is malformed.
extension Area {
    var color: Color {
        var hex = tint
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return .gray
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

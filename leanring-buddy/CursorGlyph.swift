//
//  CursorGlyph.swift
//  leanring-buddy
//
//  The cursor triangle and its shading, which every view that draws the triangle shares. The Quick Look extensions compile
//  this file too, so Finder's preview of a theme file draws the same triangle the overlay does, and it uses no app-only type.
//

import SwiftUI

/// The cursor's triangle: equilateral, with its top vertex up.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

/// The triangle's gradient: light at the tip, the accent in the middle, deeper at the base. A color as three channels.
struct CursorGlyphShade: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// The accent mixed `share` of the way toward `other`.
    func mixed(toward other: CursorGlyphShade, share: Double) -> CursorGlyphShade {
        CursorGlyphShade(
            red: red + (other.red - red) * share,
            green: green + (other.green - green) * share,
            blue: blue + (other.blue - blue) * share
        )
    }

    static let white = CursorGlyphShade(red: 1, green: 1, blue: 1)
    static let black = CursorGlyphShade(red: 0, green: 0, blue: 0)

    static let lightShare = 0.28
    static let deepShare = 0.25

    /// The light, middle, and deep shades of an accent. Nil when the accent is not a `#RRGGBB` color.
    static func shades(accentHex: String) -> (light: CursorGlyphShade, middle: CursorGlyphShade, deep: CursorGlyphShade)? {
        guard let accent = ThemeRGBColor(hex: accentHex) else { return nil }
        let middle = CursorGlyphShade(red: accent.red, green: accent.green, blue: accent.blue)
        return (
            light: middle.mixed(toward: .white, share: lightShare),
            middle: middle,
            deep: middle.mixed(toward: .black, share: deepShare)
        )
    }

    /// The glow behind the cursor stays this strong, so it reads on a dark page and does not smudge a white one.
    static let glowOpacity = 0.25
    static let glowRadiusInPoints: CGFloat = 8
    /// The glow grows by this much at the fastest point of a flight.
    static let glowRadiusGrowthAtFullSpeedInPoints: CGFloat = 6
    /// A small offset shadow that sits the cursor on the page, drawn under every cursor kind.
    static let contactShadowOpacity = 0.3
    static let contactShadowRadiusInPoints: CGFloat = 1.5
    static let contactShadowOffsetInPoints: CGFloat = 1.5
}

/// The triangle: the accent shaded light at the tip to deep at the base, with a light edge along its top, so it reads as an object
/// on a page and not a flat shape. An accent that is not a `#RRGGBB` color draws flat.
struct CursorTriangleGlyph: View {
    let accentHex: String

    var body: some View {
        if let shades = CursorGlyphShade.shades(accentHex: accentHex) {
            Triangle()
                .fill(LinearGradient(colors: [shades.light.color, shades.middle.color, shades.deep.color], startPoint: .top, endPoint: .bottom))
                .overlay {
                    // The edge is stroked on the outline and clipped to the triangle, so only its inner half shows.
                    Triangle()
                        .stroke(
                            LinearGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6)),
                            lineWidth: 1.2
                        )
                        .clipShape(Triangle())
                }
        } else {
            Triangle().fill(Color(hex: accentHex))
        }
    }
}

//
//  TetherMaterials.swift
//  leanring-buddy
//
//  The two materials of the Tether redesign. The Card is Clicky's box (the panel, the agent list, the approval card, the
//  studio, the dial, the experiment panel). The Callout is anything Clicky says near the cursor (speech, status lines,
//  tool chips, agent endings, errors). Both read only the theme's accent for color, which the caller passes in, so a
//  surface never names a team or a theme. Their values were measured in the phase-zero prototype
//  (`prototype/tether/materials` on the `prototype/tether-phase-zero` branch).
//

import AppKit
import SwiftUI

// MARK: - Ink

extension Color {
    /// Each fill's ink once it has been worked out. The fills are the themes' accents, the agent colors, and the status
    /// lines' hues, all fixed colors, so an entry never goes out of date and the dictionary stays small.
    static var inksByFill: [Color: Color] = [:]

    /// The color of text and icons drawn on a fill of this color: near-black or white, whichever reads better on it
    /// (`ThemeRGBColor.inkHexOnThisFill`). A status line's Callout reads it 30 times a second, so each fill's ink is
    /// worked out once and kept.
    var inkOnThisFill: Color {
        if let keptInk = Self.inksByFill[self] { return keptInk }
        let ink = workedOutInkOnThisFill
        Self.inksByFill[self] = ink
        return ink
    }

    /// Bridges to AppKit for the color's channels and compares both inks' contrast.
    private var workedOutInkOnThisFill: Color {
        guard let fill = NSColor(self).usingColorSpace(.sRGB) else { return Color(hex: ThemeRGBColor.darkInkHex) }
        let fillColor = ThemeRGBColor(red: fill.redComponent, green: fill.greenComponent, blue: fill.blueComponent)
        return Color(hex: fillColor.inkHexOnThisFill)
    }
}

// MARK: - Card

extension View {
    /// Draws this view on the Card: a surface from `#121419` to `#171a21`, a 1 point white edge at 8%, an inner top
    /// highlight, a two-layer shadow, and a 14 point corner radius. It adds no padding, so the content sets its own.
    /// The edge is what separates a Card from a near-black page, where the surface is only about 1.1 contrast, so keep it.
    /// The accent belongs only on the Card's selected item and its primary button.
    func tetherCard() -> some View {
        modifier(TetherCardMaterial())
    }
}

struct TetherCardMaterial: ViewModifier {
    private let cardShape = RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)

    func body(content: Content) -> some View {
        content
            .background(cardShape.fill(LinearGradient(
                colors: [DS.Colors.cardSurfaceTop, DS.Colors.cardSurfaceBottom],
                startPoint: .top,
                endPoint: .bottom
            )))
            .overlay(cardShape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            // The inner top highlight: the edge is brighter along the top quarter and fades out going down.
            .overlay(cardShape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)),
                lineWidth: 1
            ))
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 14)
    }
}

// MARK: - Callout

/// How thick a Callout's accent rim is.
enum TetherCalloutRim {
    /// Speech and status lines, which are large and stay up a while.
    case speech
    /// A tool chip or an agent ending, which may be thinner and still read on a busy page.
    case chip

    var lineWidth: CGFloat {
        switch self {
        case .speech: return 1.5
        case .chip: return 1
        }
    }
}

/// The Callout's outline: a pill with a tail at its bottom left that points down at the cursor. The fill and the rim share
/// this one path, so the rim follows the tail.
struct TetherCalloutShape: Shape {
    /// How far the tail reaches below the pill.
    static let tailHeight: CGFloat = 9
    /// The width of the tail where it leaves the pill.
    private static let tailBaseWidth: CGFloat = 13
    /// The pill's corner radius stops growing here, so a Callout of several lines keeps round corners, not round ends.
    private static let largestCornerRadius: CGFloat = 22

    /// Insets the outline, so a rim stroked on it stays inside the fill.
    var inset: CGFloat = 0

    /// The tip of the tail in a Callout of this size, from its top-left corner (y grows down). A Pop or a Recall scales
    /// the Callout about this point, so the tail stays on the cursor while the pill grows or shrinks.
    static func tailTip(inCalloutOfSize calloutSize: CGSize) -> CGPoint {
        let bodyHeight = calloutSize.height - tailHeight
        let cornerRadius = min(bodyHeight / 2, largestCornerRadius)
        return CGPoint(x: cornerRadius + 4 - 5, y: calloutSize.height)
    }

    func path(in rect: CGRect) -> Path {
        let outline = rect.insetBy(dx: inset, dy: inset)
        let bodyBottom = outline.maxY - Self.tailHeight
        let cornerRadius = min((bodyBottom - outline.minY) / 2, Self.largestCornerRadius)
        let tailBaseLeft = outline.minX + cornerRadius + 4
        let tailBaseRight = tailBaseLeft + Self.tailBaseWidth
        let tailTip = CGPoint(x: tailBaseLeft - 5, y: outline.maxY)

        var path = Path()
        path.move(to: CGPoint(x: outline.minX + cornerRadius, y: outline.minY))
        path.addArc(tangent1End: CGPoint(x: outline.maxX, y: outline.minY), tangent2End: CGPoint(x: outline.maxX, y: bodyBottom), radius: cornerRadius)
        path.addArc(tangent1End: CGPoint(x: outline.maxX, y: bodyBottom), tangent2End: CGPoint(x: tailBaseRight, y: bodyBottom), radius: cornerRadius)
        path.addLine(to: CGPoint(x: tailBaseRight, y: bodyBottom))
        path.addLine(to: tailTip)
        path.addLine(to: CGPoint(x: tailBaseLeft, y: bodyBottom))
        path.addArc(tangent1End: CGPoint(x: outline.minX, y: bodyBottom), tangent2End: CGPoint(x: outline.minX, y: outline.minY), radius: cornerRadius)
        path.addArc(tangent1End: CGPoint(x: outline.minX, y: outline.minY), tangent2End: CGPoint(x: outline.maxX, y: outline.minY), radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}

/// The Callout: a solid `#14171e` pill with an accent rim and a soft accent halo, an accent icon disc with its icon in the
/// ink that reads on that accent (`Color.inkOnThisFill`), a tail toward the cursor, and its words in white at 15/700
/// rounded (`DS.TypeScale.voice`).
///
///     TetherCallout(accent: theme.cursorColor, rim: .chip) {
///         Image(systemName: "arrow.counterclockwise")
///     } content: {
///         Text("Turning it left")
///     }
///
/// `accent` is the theme's accent, or a status line's fixed hue, which says what kind of work runs. The content may set its
/// own font or color for a second part, such as a 60% white hint, which reads at 7.0 contrast on the surface.
struct TetherCallout<Icon: View, Content: View>: View {
    let accent: Color
    var rim: TetherCalloutRim = .speech
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content

    /// The icon disc's diameter.
    static var iconDiscDiameter: CGFloat { 26 }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle().fill(accent)
                icon
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent.inkOnThisFill)
            }
            .frame(width: Self.iconDiscDiameter, height: Self.iconDiscDiameter)
            content
                .font(DS.TypeScale.voice.font)
                .foregroundStyle(Color.white)
        }
        .padding(.leading, 7)
        .padding(.trailing, 15)
        .padding(.vertical, 7)
        .padding(.bottom, TetherCalloutShape.tailHeight)
        .background(TetherCalloutShape().fill(DS.Colors.calloutSurface))
        .overlay(TetherCalloutShape(inset: rim.lineWidth / 2).stroke(accent, style: StrokeStyle(lineWidth: rim.lineWidth, lineJoin: .round)))
        .compositingGroup()
        .shadow(color: accent.opacity(0.32), radius: 9)
        .shadow(color: .black.opacity(0.4), radius: 5, x: 0, y: 3)
    }
}

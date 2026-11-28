//
//  PaperMaterial.swift
//  leanring-buddy
//
//  Paper, the third Tether material, for what the learner keeps: the quiz recap Card and the Save photo receipt. The rule
//  is "dark is live, paper is kept". Live controls, approvals, status lines, and labels over a video stay on the dark Card
//  and Callout, and a thing the learner takes away with them is printed on paper.
//
//  Paper is an opaque warm off-white with near-black ink, and it stays light in dark mode. It is never tilted and carries no
//  grid or texture. Its one accent is a flat highlight behind a short phrase, in the theme's accent with the ink that reads
//  on it (`paperInk(onAccent:)`). The accent is never body text on paper, since Clicky blue on paper is only 3.39 contrast.
//  Its serif is New York, the system serif (`DS.PaperType`), and its colors are `DS.Colors.paper...`.
//

import AppKit
import SwiftUI

// MARK: - Card

extension View {
    /// Draws this view on paper: the opaque `paperSurface`, a half point edge in `paperEdge`, an 8 point corner
    /// (`DS.CornerRadius.paper`), and the Card's two shadow layers. It adds no padding, so the content sets its own. The
    /// content is always drawn in the light color scheme, so a scroll bar or a control inside never turns dark on it.
    func paperCard() -> some View {
        modifier(PaperCardMaterial())
    }
}

struct PaperCardMaterial: ViewModifier {
    private let paperShape = RoundedRectangle(cornerRadius: DS.CornerRadius.paper, style: .continuous)

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .light)
            .background(paperShape.fill(DS.Colors.paperSurface))
            .overlay(paperShape.strokeBorder(DS.Colors.paperEdge, lineWidth: 0.5).allowsHitTesting(false))
            .compositingGroup()
            // The Card's two layers, so a paper Card lifts off a dark or a bright page the way the Card does.
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 14)
    }
}

/// A section's top rule, one hairline across the Card.
struct PaperRule: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.paperHairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Highlight

/// `color` as a `ThemeRGBColor`, read in sRGB. Nil when AppKit cannot convert it.
private func paperThemeRGBColor(of color: Color) -> ThemeRGBColor? {
    guard let channels = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    return ThemeRGBColor(red: channels.redComponent, green: channels.greenComponent, blue: channels.blueComponent)
}

/// Whether a highlight in `accent` needs a hairline edge to show on paper: when its contrast with `paperSurface` is under 3,
/// the least a boundary needs. Clicky blue reads at 3.39 and needs none. A pale accent such as Inarizaki's `#F4F4F5` is 1.0.
func paperHighlightNeedsAnEdge(accent: Color) -> Bool {
    guard let accentColor = paperThemeRGBColor(of: accent), let paperColor = paperThemeRGBColor(of: DS.Colors.paperSurface) else { return false }
    return accentColor.contrastRatio(against: paperColor) < paperHighlightLeastContrastWithPaper
}

/// The least contrast a highlight's fill needs against paper to show with no edge.
let paperHighlightLeastContrastWithPaper = 3.0

/// The least contrast the ink of a printed highlight needs against its fill (WCAG AA for text).
let paperInkLeastContrastOnAnAccent = 4.5

/// The ink for letters and a check on `accent` where paper prints it. It is the ink that reads on any accent
/// (`Color.inkOnThisFill`), unless that ink is under 4.5 on this accent. A mid gray such as `#787878` reads at 4.43 with the
/// near-black ink and 4.42 with white, so there the ink is pure black or pure white, whichever is higher (4.76 for black).
/// This is paper's own rule, and the other surfaces keep `inkOnThisFill`.
func paperInk(onAccent accent: Color) -> Color {
    guard let accentColor = paperThemeRGBColor(of: accent) else { return accent.inkOnThisFill }
    let black = ThemeRGBColor(red: 0, green: 0, blue: 0)
    let white = ThemeRGBColor(red: 1, green: 1, blue: 1)
    let usualInk = ThemeRGBColor(hex: accentColor.inkHexOnThisFill) ?? black
    guard accentColor.contrastRatio(against: usualInk) < paperInkLeastContrastOnAnAccent else { return accent.inkOnThisFill }
    return accentColor.contrastRatio(against: black) >= accentColor.contrastRatio(against: white) ? .black : .white
}

/// A short phrase on a flat highlight in the theme's accent, the one place paper takes the accent. Its letters are the ink
/// that reads on that accent, and a pale accent gets a hairline edge so the highlight still shows on paper.
struct PaperHighlight: View {
    let text: String
    let accent: Color

    var body: some View {
        let highlightShape = RoundedRectangle(cornerRadius: DS.CornerRadius.swatch, style: .continuous)
        Text(verbatim: text)
            .font(DS.TypeScale.title.font)
            .foregroundStyle(paperInk(onAccent: accent))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(highlightShape.fill(accent))
            .overlay {
                if paperHighlightNeedsAnEdge(accent: accent) {
                    highlightShape.strokeBorder(DS.Colors.paperHairlineHover, lineWidth: 1)
                }
            }
    }
}

// MARK: - Save photo receipt

/// The receipt's outline: a rounded rectangle on paper's own corner with the Callout's tail at its bottom left, pointing at the
/// cursor. Its tail's tip is where `TetherCalloutShape.tailTip` puts it for the same size, so the chip's pop and its placement
/// treat the receipt as they treat any Callout.
struct PaperReceiptShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerRadius = DS.CornerRadius.paper
        let bodyBottom = rect.maxY - TetherCalloutShape.tailHeight
        let tailTip = TetherCalloutShape.tailTip(inCalloutOfSize: rect.size)
        let tailBaseLeft = tailTip.x + 5
        let tailBaseRight = tailBaseLeft + 13

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: bodyBottom), radius: cornerRadius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bodyBottom), tangent2End: CGPoint(x: tailBaseRight, y: bodyBottom), radius: cornerRadius)
        path.addLine(to: CGPoint(x: tailBaseRight, y: bodyBottom))
        path.addLine(to: CGPoint(x: tailTip.x, y: rect.maxY))
        path.addLine(to: CGPoint(x: tailBaseLeft, y: bodyBottom))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: bodyBottom), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: cornerRadius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}

/// The receipt after Save photo worked: a small paper card with the saved photo's thumbnail, a check on an accent disc, "Saved
/// to Pictures" in the serif, and where the file went in monospaced caption, cut with an ellipsis when it is long.
struct PaperPhotoReceipt: View {
    /// The saved photo, small. Nil when it could not be made, which shows a plain tile.
    let thumbnail: CGImage?
    /// "Clicky folder · <file name>".
    let locationLine: String
    let accent: Color

    static let maxWidth: CGFloat = 340
    static let thumbnailSize = CGSize(width: 34, height: 26)
    /// What the receipt stands at with its tail, which the chip stack uses as the space it takes (`voiceToolCallChipRise`). A
    /// test holds it to the receipt's drawn height.
    static let height: CGFloat = 58
    /// The most the receipt may stand at, with room to spare, so the chip's panel is tall enough for it.
    static let greatestHeight: CGFloat = 64
    private static let checkDiscDiameter: CGFloat = 16

    var body: some View {
        HStack(spacing: 10) {
            thumbnailTile
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(accent)
                        Image(systemName: "checkmark")
                            .font(DS.glyphFont(pointSize: 9, weight: .heavy))
                            .foregroundStyle(paperInk(onAccent: accent))
                    }
                    // A pale accent is as light as the paper, so its disc gets the highlight's hairline edge.
                    .overlay {
                        if paperHighlightNeedsAnEdge(accent: accent) {
                            Circle().strokeBorder(DS.Colors.paperHairlineHover, lineWidth: 1)
                        }
                    }
                    .frame(width: Self.checkDiscDiameter, height: Self.checkDiscDiameter)
                    Text("Saved to Pictures")
                        .font(DS.PaperType.receiptTitle.font)
                        .foregroundStyle(DS.Colors.paperInk)
                        .lineLimit(1)
                }
                Text(verbatim: locationLine)
                    .font(DS.TypeScale.data.font.weight(.medium))
                    .foregroundStyle(DS.Colors.paperInkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8 + TetherCalloutShape.tailHeight, trailing: 14))
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .fixedSize()
        .background(PaperReceiptShape().fill(DS.Colors.paperSurface))
        .overlay(PaperReceiptShape().stroke(DS.Colors.paperEdge, style: StrokeStyle(lineWidth: 0.5, lineJoin: .round)))
        .compositingGroup()
        .tetherCalloutDropShadow()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thumbnailTile: some View {
        let tileShape = RoundedRectangle(cornerRadius: DS.CornerRadius.swatch, style: .continuous)
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                DS.Colors.paperWash
            }
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .clipShape(tileShape)
        .overlay(tileShape.strokeBorder(DS.Colors.paperHairline, lineWidth: 1))
    }
}

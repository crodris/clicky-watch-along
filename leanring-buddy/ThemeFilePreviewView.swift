//
//  ThemeFilePreviewView.swift
//  leanring-buddy
//
//  What Finder's Quick Look shows for a `.clickytheme` file: the theme's cursor, its name, how it moves, its accent and
//  contrast colors, and how its agents look, on the Tether Card. The Quick Look extension (ClickyThemeQuickLook/) compiles
//  this file with the theme's own sources and renders it to a PNG, so the app's tests render the same view at 2x.
//  The thumbnail extension (ClickyThemeThumbnail/) compiles the same files and draws `ThemeFileThumbnailView`, the file's
//  icon in Finder: the cursor on its disc over the theme's colors. Both read the file with `readThemeFileForQuickLook`.
//  The preview is one still picture, so it draws the cursor still and has no motion, and no Reduce Motion form is needed.
//  The extension cannot reach most of the app's views, so the cursor is drawn here from the theme's fields: the app's shaded
//  triangle (`CursorTriangleGlyph`, CursorGlyph.swift) at its pointer angle, the shapes in the 24 point box, or the picture
//  with its fit, outline, and tint.
//

import AppKit
import SwiftUI

struct ThemeFilePreviewView: View {
    let theme: ClickyTheme
    /// The package's picture.jpg, when the theme's cursor or faces use it.
    let picture: NSImage?

    static let size = CGSize(width: 520, height: 260)
    private static let cursorDiscDiameter: CGFloat = 132
    /// The 24 point box drawn about four times its size, so a school's volleyball fills the disc as the triangle does.
    private static let cursorDrawingSide: CGFloat = 96

    /// The colors under Clicky blue's `perKind` ring, in the order agents take them: task teal, study guide amber, 3D model
    /// violet, experiment lime, then sky and pink. The app's `AgentPaletteColor.fixedPalette` lists the same six, and lives
    /// in a file the extension does not compile.
    static let perKindAgentColors: [Color] = [
        DS.Colors.backgroundAgentTaskTeal,
        DS.Colors.backgroundAgentStudyGuideAmber,
        DS.Colors.backgroundAgentThreeDModelViolet,
        DS.Colors.backgroundAgentExperimentLime,
        DS.Colors.sky400,
        DS.Colors.pink400,
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            ThemeFilePreviewCursor(theme: theme, picture: picture, drawingSide: Self.cursorDrawingSide)
                .frame(width: Self.cursorDiscDiameter, height: Self.cursorDiscDiameter)
                .background(Circle().fill(DS.Colors.surface1))
                .overlay(Circle().strokeBorder(Color(hex: theme.accentHex).opacity(0.5), lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.name)
                        .font(DS.TypeScale.headline.font)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(themeInstallCardSummary(for: theme))
                        .font(DS.TypeScale.body.font)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                swatchRow(title: "Colors", colors: [Color(hex: theme.accentHex), Color(hex: theme.contrastHex)])
                swatchRow(title: "Agents", colors: agentColors, note: agentsNote)
                Text("Double-click to add it to Clicky")
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height)
        .tetherCard()
        .environment(\.colorScheme, .dark)
    }

    private var agentColors: [Color] { quickLookAgentColors(of: theme) }

    /// What the agents' faces are, in words, since a roster's portraits never travel in a file.
    private var agentsNote: String {
        switch theme.agents.faces {
        case .triangle: return "Triangle faces"
        case .picture: return "Picture faces"
        case .roster(let players): return players.count == 1 ? "1 named face" : "\(players.count) named faces"
        }
    }

    private func swatchRow(title: String, colors: [Color], note: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 46, alignment: .leading)
            ForEach(colors.indices, id: \.self) { colorIndex in
                RoundedRectangle(cornerRadius: DS.CornerRadius.swatch)
                    .fill(colors[colorIndex])
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.swatch).strokeBorder(DS.Colors.edge, lineWidth: 1))
            }
            if let note {
                Text(note)
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        }
    }
}

/// The colors a theme's agents wear, in the order they take them.
func quickLookAgentColors(of theme: ClickyTheme) -> [Color] {
    switch theme.agents.ring {
    case .perKind: return ThemeFilePreviewView.perKindAgentColors
    case .perAgent(let colorHexes): return colorHexes.map { Color(hex: $0) }
    case .accent: return [Color(hex: theme.accentHex)]
    }
}

/// A `.clickytheme` file as both Quick Look extensions read it: the theme, and its picture when it uses one.
nonisolated struct ThemeFileForQuickLook: Sendable {
    let theme: ClickyTheme
    let pictureJPEG: Data?
}

/// Reads a `.clickytheme` package with `CustomThemeStore.previewPackage`, the same read and the same `ClickyTheme.parse`
/// rules an install applies, so a file Clicky would refuse shows Quick Look's plain fallback instead of a theme.
/// `previewPackage` reads only the package, so the store's own folder is never touched. An extension's sandbox has no folder
/// of Clicky's, so the store points at the temporary folder.
nonisolated func readThemeFileForQuickLook(at packageURL: URL) throws -> ThemeFileForQuickLook {
    let store = CustomThemeStore(themesDirectoryURL: FileManager.default.temporaryDirectory)
    let packagePreview = try store.previewPackage(at: packageURL)
    return ThemeFileForQuickLook(theme: packagePreview.theme, pictureJPEG: packagePreview.pictureJPEG)
}

/// What Finder shows as a `.clickytheme` file's icon: the theme's cursor, still, on a dark disc in its accent rim, over a
/// row of its accent, contrast, and first agent colors, on a square of the Card's surface. Everything scales with `side`,
/// since Finder asks for sizes from 16 to 1024 points. It has no words, since Finder writes the file's name under it.
struct ThemeFileThumbnailView: View {
    let theme: ClickyTheme
    let picture: NSImage?
    let side: CGFloat

    /// The swatches under the disc: the accent and contrast colors, then up to three agent colors.
    private var swatchColors: [Color] {
        [Color(hex: theme.accentHex), Color(hex: theme.contrastHex)] + quickLookAgentColors(of: theme).prefix(3)
    }

    var body: some View {
        let accentColor = Color(hex: theme.accentHex)
        VStack(spacing: side * 0.07) {
            ThemeFilePreviewCursor(theme: theme, picture: picture, drawingSide: side * 0.42)
                .frame(width: side * 0.6, height: side * 0.6)
                .background(Circle().fill(DS.Colors.surface1))
                .overlay(Circle().strokeBorder(accentColor.opacity(0.6), lineWidth: max(1, side * 0.015)))
            HStack(spacing: side * 0.03) {
                ForEach(swatchColors.indices, id: \.self) { swatchIndex in
                    // The faint edge the preview's swatches have, so a black or near-black color shows on the dark card.
                    RoundedRectangle(cornerRadius: side * 0.02)
                        .fill(swatchColors[swatchIndex])
                        .overlay(RoundedRectangle(cornerRadius: side * 0.02).strokeBorder(Color.white.opacity(0.2), lineWidth: max(0.5, side * 0.006)))
                        .frame(width: side * 0.09, height: side * 0.09)
                }
            }
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                .fill(LinearGradient(colors: [DS.Colors.cardSurfaceTop, DS.Colors.cardSurfaceBottom], startPoint: .top, endPoint: .bottom))
        )
        .environment(\.colorScheme, .dark)
    }
}

/// The thumbnail as an image `side` points square at `scale` pixels per point. Nil when the renderer gives no image.
@MainActor
func themeFileThumbnailImage(theme: ClickyTheme, picture: NSImage?, side: CGFloat, scale: CGFloat) -> CGImage? {
    let renderer = ImageRenderer(content: ThemeFileThumbnailView(theme: theme, picture: picture, side: side))
    renderer.scale = scale
    return renderer.cgImage
}

/// The theme's cursor, still, drawn to fill `drawingSide`.
struct ThemeFilePreviewCursor: View {
    let theme: ClickyTheme
    let picture: NSImage?
    let drawingSide: CGFloat

    var body: some View {
        switch theme.cursor {
        case .triangle:
            triangle
        case .shapes(let shapes):
            ZStack {
                ForEach(shapes.indices, id: \.self) { shapeIndex in
                    shapeLayers(shapes[shapeIndex])
                }
            }
            .frame(width: drawingSide, height: drawingSide)
        case .picture(let pictureStyle):
            if let picture {
                pictureCursor(picture, style: pictureStyle)
            } else {
                // A picture the package lacks never parses, but a picture.jpg that does not decode draws the triangle.
                triangle
            }
        }
    }

    /// The triangle at its pointer angle, shaded as the overlay draws it.
    private var triangle: some View {
        CursorTriangleGlyph(accentHex: theme.accentHex)
            .frame(width: drawingSide * 0.66, height: drawingSide * 0.66)
            .rotationEffect(.degrees(-35))
    }

    private func shapeLayers(_ shape: CustomCursorShape) -> some View {
        // The stroke width is in the 24 point box's units, so it scales with the drawing.
        let boxScale = drawingSide / CursorDrawingBox.sideLength
        return ZStack {
            if let fillHex = shape.fillHex {
                SVGPathShape(pathData: shape.path).fill(Color(hex: fillHex))
            }
            if let strokeHex = shape.strokeHex, shape.strokeWidth > 0 {
                SVGPathShape(pathData: shape.path)
                    .stroke(Color(hex: strokeHex), style: StrokeStyle(lineWidth: shape.strokeWidth * boxScale, lineCap: .round, lineJoin: .round))
            }
        }
    }

    @ViewBuilder private func pictureCursor(_ picture: NSImage, style: CustomCursorPictureStyle) -> some View {
        // 4 points of outline on the preview's 96 point drawing, scaled with the drawing, so a 16 point Finder thumbnail's
        // 7 point picture is not all outline.
        let outlineWidth = drawingSide / 24
        let imageLayers = ZStack {
            Image(nsImage: picture).resizable().scaledToFill()
            if let tintHex = style.tintHex {
                Color(hex: tintHex).opacity(style.tintStrength)
            }
        }
        .frame(width: drawingSide, height: drawingSide)
        switch style.fit {
        case .whole:
            let cornerShape = RoundedRectangle(cornerRadius: drawingSide * 0.125, style: .continuous)
            imageLayers.clipShape(cornerShape).overlay(cornerShape.strokeBorder(Color(hex: style.outlineHex), lineWidth: outlineWidth))
        case .circle:
            imageLayers.clipShape(Circle()).overlay(Circle().strokeBorder(Color(hex: style.outlineHex), lineWidth: outlineWidth))
        }
    }
}

/// The preview as PNG data at 2x, which the Quick Look extension returns to Finder. Nil when the renderer gives no image.
@MainActor
func themeFilePreviewPNGData(theme: ClickyTheme, picture: NSImage?) -> Data? {
    let renderer = ImageRenderer(content: ThemeFilePreviewView(theme: theme, picture: picture))
    renderer.scale = 2
    guard let cgImage = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
}

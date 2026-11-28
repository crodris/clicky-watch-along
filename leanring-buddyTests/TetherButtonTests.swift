//
//  TetherButtonTests.swift
//  leanring-buddyTests
//
//  The one button every Tether surface uses: its size, its resting and hover looks, the ink on a fill, the disabled
//  look, that it draws no shadow, and that it keeps the pointing hand. Renders are at 2x and read their raw bytes.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

/// A button look rendered at 2x over an opaque backdrop, with a margin of that backdrop around it so a shadow would show.
private struct RenderedButton {
    let widthInPoints: CGFloat
    let heightInPoints: CGFloat
    let margin: CGFloat
    private let pixelsWide: Int
    private let bytes: [UInt8]

    @MainActor
    init(_ look: some View, backdrop: Color = Color(hex: "#808080"), margin: CGFloat = 8) throws {
        let renderer = ImageRenderer(content: look.padding(margin).background(backdrop))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var rendered = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &rendered, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bytes = rendered
        pixelsWide = image.width
        widthInPoints = CGFloat(image.width) / 2 - 2 * margin
        heightInPoints = CGFloat(image.height) / 2 - 2 * margin
        self.margin = margin
    }

    /// The color at a point measured from the button's own top left corner.
    func color(atX x: CGFloat, y: CGFloat) -> [Int] {
        let column = Int(((x + margin) * 2).rounded(.down))
        let row = Int(((y + margin) * 2).rounded(.down))
        let firstByte = (row * pixelsWide + column) * 4
        return (0..<3).map { Int(bytes[firstByte + $0]) }
    }

    /// How many pixels of the margin around the button differ from `backdrop` by more than `tolerance` in any channel.
    func marginPixelsThatDiffer(from backdrop: [Int], tolerance: Int = 1) -> Int {
        let pixelsHigh = bytes.count / 4 / pixelsWide
        let marginPixels = Int(margin * 2)
        var count = 0
        for row in 0..<pixelsHigh {
            for column in 0..<pixelsWide {
                let isInTheMargin = row < marginPixels || row >= pixelsHigh - marginPixels || column < marginPixels || column >= pixelsWide - marginPixels
                guard isInTheMargin else { continue }
                let firstByte = (row * pixelsWide + column) * 4
                if (0..<3).contains(where: { abs(Int(bytes[firstByte + $0]) - backdrop[$0]) > tolerance }) { count += 1 }
            }
        }
        return count
    }

    /// How many pixels inside the button are within 12 levels of `ink` in every channel.
    func pixelsNear(_ ink: [Int]) -> Int {
        let pixelsHigh = bytes.count / 4 / pixelsWide
        var count = 0
        for row in 0..<pixelsHigh {
            for column in 0..<pixelsWide {
                let firstByte = (row * pixelsWide + column) * 4
                if (0..<3).allSatisfy({ abs(Int(bytes[firstByte + $0]) - ink[$0]) <= 12 }) { count += 1 }
            }
        }
        return count
    }
}

private func channels(of color: Color) -> [Int] {
    let srgbColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return [srgbColor.redComponent, srgbColor.greenComponent, srgbColor.blueComponent].map { Int(($0 * 255).rounded()) }
}

private func close(_ first: [Int], _ second: [Int], within tolerance: Int = 3) -> Bool {
    zip(first, second).allSatisfy { abs($0 - $1) <= tolerance }
}

@MainActor
struct TetherButtonTests {
    @Test(arguments: [(TetherButtonSize.compact, CGFloat(24)), (.standard, 28), (.prominent, 32)])
    func eachSizeHasItsHeight(size: TetherButtonSize, expectedHeight: CGFloat) {
        let titled = NSHostingView(rootView: TetherButton("Save", role: .secondary, size: size) {})
        #expect(titled.fittingSize.height == expectedHeight)
        #expect(size.height == expectedHeight)
        let withIcon = NSHostingView(rootView: TetherButton("Place", systemImage: "checkmark", role: .secondary, shape: .capsule, size: size) {})
        #expect(withIcon.fittingSize.height == expectedHeight)
    }

    @Test(arguments: [TetherButtonSize.compact, .standard, .prominent])
    func aCircleIsAsWideAsItIsTall(size: TetherButtonSize) {
        let circle = NSHostingView(rootView: TetherButton(systemImage: "xmark", role: .secondary, shape: .circle, size: size, accessibilityLabel: "Close") {})
        #expect(circle.fittingSize == CGSize(width: size.height, height: size.height))
    }

    @Test func aSecondaryButtonRestsOnSurface3AndHoversToSurface4WithABrighterEdge() throws {
        func look(isHovered: Bool) throws -> RenderedButton {
            try RenderedButton(TetherButtonLook(title: "Cancel", role: .secondary, size: .standard, isHovered: isHovered))
        }
        let resting = try look(isHovered: false)
        let hovered = try look(isHovered: true)
        // Clear of the label and the 1 point edge, inside the left padding.
        let restingFill = resting.color(atX: 5, y: 14)
        let hoveredFill = hovered.color(atX: 5, y: 14)
        #expect(close(restingFill, channels(of: DS.Colors.surface3)), "resting fill \(restingFill)")
        #expect(close(hoveredFill, channels(of: DS.Colors.surface4)), "hovered fill \(hoveredFill)")
        // The edge is the 1 point line at the button's left end, over the fill.
        let restingEdge = resting.color(atX: 0.5, y: 14)
        let hoveredEdge = hovered.color(atX: 0.5, y: 14)
        #expect(hoveredEdge.reduce(0, +) > restingEdge.reduce(0, +), "resting edge \(restingEdge), hovered edge \(hoveredEdge)")
        #expect(restingEdge.reduce(0, +) > restingFill.reduce(0, +), "the resting edge \(restingEdge) is not lighter than its fill \(restingFill)")
    }

    @Test func aQuietButtonHasNoFillAtRestAndAWashOnHover() throws {
        let backdrop = channels(of: Color(hex: "#808080"))
        let resting = try RenderedButton(TetherButtonLook(title: "Setup", role: .quiet, size: .compact))
        let hovered = try RenderedButton(TetherButtonLook(title: "Setup", role: .quiet, size: .compact, isHovered: true))
        #expect(close(resting.color(atX: 3, y: 12), backdrop, within: 1))
        #expect(hovered.color(atX: 3, y: 12).reduce(0, +) > backdrop.reduce(0, +))
    }

    @Test(arguments: ["#E5484D", "#3380FF", "#E0313B", "#A0457F", "#F4F4F5"])
    func aFilledButtonsLabelIsTheInkThatReadsOnItsFill(fillHex: String) throws {
        let inkHex = ThemeRGBColor.inkHex(onFillHex: fillHex)
        let ink = channels(of: Color(hex: inkHex))
        let otherInk = channels(of: Color(hex: inkHex == ThemeRGBColor.lightInkHex ? ThemeRGBColor.darkInkHex : ThemeRGBColor.lightInkHex))
        let primary = try RenderedButton(TetherButtonLook(title: "Allow", role: .primary(accent: Color(hex: fillHex)), size: .prominent))
        #expect(primary.pixelsNear(ink) > 20)
        // A fill within a few levels of the other ink would count as that ink, so only a fill apart from it is checked.
        if !close(channels(of: Color(hex: fillHex)), otherInk, within: 24) {
            #expect(primary.pixelsNear(otherInk) == 0)
        }
    }

    @Test func theDestructiveButtonTakesTheInkThatReadsOnItsRed() throws {
        let inkHex = ThemeRGBColor.inkHex(onFillHex: "#E5484D")
        let ink = channels(of: Color(hex: inkHex))
        let otherInk = channels(of: Color(hex: inkHex == ThemeRGBColor.lightInkHex ? ThemeRGBColor.darkInkHex : ThemeRGBColor.lightInkHex))
        let destructive = try RenderedButton(TetherButtonLook(title: "Delete", role: .destructive, size: .compact))
        #expect(destructive.pixelsNear(ink) > 20)
        #expect(destructive.pixelsNear(otherInk) == 0)
        let hovered = try RenderedButton(TetherButtonLook(title: "Delete", role: .destructive, size: .compact, isHovered: true))
        #expect(close(hovered.color(atX: 4, y: 12), channels(of: DS.Colors.destructiveHover)))
    }

    @Test func aDisabledButtonDrawsAtFortyPercentAndShowsNoHover() throws {
        let backdrop = channels(of: Color(hex: "#808080"))
        let fill = channels(of: DS.Colors.surface3)
        let disabled = try RenderedButton(TetherButtonLook(title: "Allow once", role: .secondary, isHovered: true, isEnabled: false))
        let expected = zip(fill, backdrop).map { Int((Double($0) * 0.4 + Double($1) * 0.6).rounded()) }
        #expect(close(disabled.color(atX: 5, y: 14), expected, within: 4), "disabled fill \(disabled.color(atX: 5, y: 14)), expected \(expected)")
    }

    @Test func aDisabledButtonHasNoHoverViewAndAnEnabledOneHasExactlyOne() {
        let enabled = NSHostingView(rootView: TetherButton("Save", role: .secondary) {})
        enabled.layoutSubtreeIfNeeded()
        #expect(hoverAndPointerViews(in: enabled).count == 1)
        let disabled = NSHostingView(rootView: TetherButton("Save", role: .secondary, isEnabled: false) {})
        disabled.layoutSubtreeIfNeeded()
        #expect(hoverAndPointerViews(in: disabled).isEmpty)
    }

    @Test(arguments: [TetherButtonShape.rounded, .capsule, .circle])
    func noRoleDrawsAShadowOrAnythingOutsideItsShape(shape: TetherButtonShape) throws {
        let backdrop = channels(of: Color(hex: "#808080"))
        let roles: [TetherButtonRole] = [
            .primary(accent: Color(hex: "#3380FF")), .secondary, .secondaryDestructive, .quiet, .destructive,
        ]
        for role in roles {
            for isHovered in [false, true] {
                let look = shape == .circle
                    ? TetherButtonLook(systemImage: "xmark", role: role, shape: shape, size: .prominent, isHovered: isHovered)
                    : TetherButtonLook(title: "Place", role: role, shape: shape, size: .prominent, isHovered: isHovered)
                let drawn = try RenderedButton(look)
                // The hover ring is drawn inside the shape, so the margin must be the backdrop, not a darker halo.
                #expect(drawn.marginPixelsThatDiffer(from: backdrop) == 0, "\(shape) \(role) hovered \(isHovered) draws outside its shape")
            }
        }
    }

    @Test func aCapsuleAndACircleRoundTheirCorners() throws {
        let backdrop = channels(of: Color(hex: "#808080"))
        let capsule = try RenderedButton(TetherButtonLook(title: "Replay", role: .primary(accent: Color(hex: "#3380FF")), shape: .capsule, size: .standard))
        // A capsule's corner pixel is the page, and a rounded button of 8 points keeps more of its corner.
        #expect(close(capsule.color(atX: 1, y: 1), backdrop, within: 2), "the capsule's corner is \(capsule.color(atX: 1, y: 1))")
        let rounded = try RenderedButton(TetherButtonLook(title: "Replay", role: .primary(accent: Color(hex: "#3380FF")), shape: .rounded, size: .standard))
        #expect(!close(rounded.color(atX: 2.5, y: 2.5), backdrop, within: 8), "the rounded button's corner is \(rounded.color(atX: 2.5, y: 2.5))")
        let circle = try RenderedButton(TetherButtonLook(systemImage: "xmark", role: .secondary, shape: .circle, size: .compact))
        #expect(close(circle.color(atX: 1, y: 1), backdrop, within: 2))
        #expect(!close(circle.color(atX: 12, y: 12), backdrop, within: 8))
    }

    /// The approval card's three equal buttons sit in a 300 point card with 14 points of padding on each side and 6 points
    /// between them. "For this task" is the longest label, and it must keep all of its room in its third at the standard size.
    @Test func theApprovalCardsLongestLabelFitsItsThirdOfTheCard() {
        let contentWidth = AgentListPanelController.panelWidth - 2 * 14
        let thirdOfTheRow = (contentWidth - 2 * 6) / 3
        for title in ["Don't allow", "Allow once", "For this task"] {
            // With the width filled the button has no side padding, so its ideal width is the label's own.
            let labelWidth = NSHostingView(rootView: Text(verbatim: title).font(TetherButtonSize.standard.labelFont).fixedSize()).fittingSize.width
            #expect(labelWidth <= thirdOfTheRow, "\"\(title)\" is \(labelWidth) points wide, and a third of the card is \(thirdOfTheRow)")
        }
    }

    @Test func aFullWidthButtonFillsItsContainer() {
        let row = HStack(spacing: 6) {
            TetherButton("Don't allow", role: .secondary, fillsTheWidth: true) {}
            TetherButton("For this task", role: .secondary, fillsTheWidth: true) {}
        }
        .frame(width: 200)
        #expect(NSHostingView(rootView: row).fittingSize.width == 200)
    }
}

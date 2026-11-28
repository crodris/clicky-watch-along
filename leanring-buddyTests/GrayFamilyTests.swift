//
//  GrayFamilyTests.swift
//  leanring-buddyTests
//
//  Every gray token sits on the Card's blue-gray, so a panel, a card, a button, and a track read as one set of surfaces.
//  The old grays were green-gray (hue 150 to 160), which sat next to the Card's blue-gray (hue about 222) as a visible
//  tint difference. Each test reads the colors through sRGB, the space the hex values are written in.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

struct GrayFamilyTests {
    private func hueInDegrees(of color: Color) throws -> Double {
        let srgbColor = try #require(NSColor(color).usingColorSpace(.sRGB))
        return Double(srgbColor.hueComponent) * 360
    }

    /// The gap between the strongest and the weakest channel, from 0 (a pure gray) to 1.
    private func chroma(of color: Color) throws -> Double {
        let srgbColor = try #require(NSColor(color).usingColorSpace(.sRGB))
        let channels = [srgbColor.redComponent, srgbColor.greenComponent, srgbColor.blueComponent].map(Double.init)
        return (channels.max() ?? 0) - (channels.min() ?? 0)
    }

    /// WCAG relative luminance, so the order of the surfaces is the order a reader sees.
    private func luminance(of color: Color) throws -> Double {
        let srgbColor = try #require(NSColor(color).usingColorSpace(.sRGB))
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgbColor.redComponent) + 0.7152 * linear(srgbColor.greenComponent) + 0.0722 * linear(srgbColor.blueComponent)
    }

    private var everyGray: [(name: String, color: Color)] {
        [
            ("ground", DS.Colors.ground),
            ("surface1", DS.Colors.surface1),
            ("surface2", DS.Colors.surface2),
            ("surface3", DS.Colors.surface3),
            ("surface4", DS.Colors.surface4),
            ("border", DS.Colors.border),
            ("textPrimary", DS.Colors.textPrimary),
            ("textSecondary", DS.Colors.textSecondary),
            ("textTertiary", DS.Colors.textTertiary),
        ]
    }

    @Test func everyGrayHasTheCardsBlueGrayHue() throws {
        let cardHue = try hueInDegrees(of: DS.Colors.cardSurfaceTop)
        #expect(abs(cardHue - 222) < 5, "the Card's own hue is the family's anchor")
        for (name, color) in everyGray {
            let hue = try hueInDegrees(of: color)
            #expect(abs(hue - cardHue) <= 10, "DS.Colors.\(name) has hue \(hue), more than 10 degrees from the Card's \(cardHue)")
        }
    }

    @Test func everyGrayStaysAGrayAndNotAColor() throws {
        for (name, color) in everyGray {
            let colorfulness = try chroma(of: color)
            #expect(colorfulness < 0.15, "DS.Colors.\(name) has chroma \(colorfulness), which is a color and not a gray")
        }
    }

    @Test func theSurfacesRiseInLightnessToTheBorder() throws {
        let surfaces = [DS.Colors.ground, DS.Colors.surface1, DS.Colors.surface2, DS.Colors.surface3, DS.Colors.surface4, DS.Colors.border]
        let luminances = try surfaces.map(luminance(of:))
        for index in luminances.indices.dropFirst() {
            #expect(luminances[index] > luminances[index - 1], "surface number \(index) is not lighter than the one under it")
        }
    }

    @Test func theTextColorsKeepTheirOrderAndReadOnTheSurfaces() throws {
        let primary = try luminance(of: DS.Colors.textPrimary)
        let secondary = try luminance(of: DS.Colors.textSecondary)
        let tertiary = try luminance(of: DS.Colors.textTertiary)
        #expect(primary > secondary && secondary > tertiary)
        // Contrast against the lightest surface a label sits on, which is a hovered secondary button.
        let hoveredButton = try luminance(of: DS.Colors.surface4)
        #expect((primary + 0.05) / (hoveredButton + 0.05) >= 7, "primary text on surface4 is under 7:1")
        #expect((secondary + 0.05) / (hoveredButton + 0.05) >= 4.5, "secondary text on surface4 is under 4.5:1")
    }

    @Test func theCardsBottomColorIsTheFirstSurface() throws {
        #expect(try luminance(of: DS.Colors.cardSurfaceBottom) == luminance(of: DS.Colors.surface1))
    }

    @Test func theEdgeIsTheCardsEightPercentWhiteAndTheHoverEdgeIsBrighter() throws {
        let edge = try #require(NSColor(DS.Colors.edge).usingColorSpace(.sRGB))
        let edgeHover = try #require(NSColor(DS.Colors.edgeHover).usingColorSpace(.sRGB))
        #expect(abs(edge.alphaComponent - 0.08) < 0.005)
        #expect(edgeHover.alphaComponent > edge.alphaComponent)
    }
}

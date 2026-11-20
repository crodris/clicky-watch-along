//
//  CustomThemeTests.swift
//  leanring-buddyTests
//
//  The SVG path parser and the boundary function that turns a Worker idea or a saved theme.json into a CustomTheme.
//  Each rule the Worker's checkThemeIdeas applies is pinned here too, since the app applies it again to a saved file.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

// MARK: - A good idea, and one change at a time

/// A copy of `value` with the field at `path` replaced. A path part that is a number picks an array item.
nonisolated func replacingField(in value: JSONValue, at path: [String], with newValue: JSONValue) -> JSONValue {
    guard let firstPart = path.first else { return newValue }
    let remainingPath = Array(path.dropFirst())
    switch value {
    case .object(var fields):
        fields[firstPart] = replacingField(in: fields[firstPart] ?? .null, at: remainingPath, with: newValue)
        return .object(fields)
    case .array(var items):
        if let itemIndex = Int(firstPart), items.indices.contains(itemIndex) {
            items[itemIndex] = replacingField(in: items[itemIndex], at: remainingPath, with: newValue)
        }
        return .array(items)
    default:
        return value
    }
}

/// An idea that follows every rule, in the shape the Worker sends.
nonisolated let goodThemeIdea: JSONValue = .object([
    "name": .string("Moonlit"),
    "accent": .string("#7DD3FC"),
    "contrast": .string("#1E1B4B"),
    "agentColors": .array([.string("#7DD3FC"), .string("#C4B5FD"), .string("#FDE68A")]),
    "cursor": .object([
        "kind": .string("shapes"),
        "shapes": .array([
            .object([
                "d": .string("M12 2 L14.8 8.6 L22 9.2 L16.5 14 L18.2 21.5 L12 17.6 L5.8 21.5 L7.5 14 L2 9.2 L9.2 8.6 Z"),
                "fill": .string("#7DD3FC"),
                "stroke": .string("#FFFFFF"),
                "strokeWidth": .number(1.4),
            ]),
        ]),
        "picture": .null,
    ]),
    "motion": .object([
        "turnsTowardMovement": .bool(true),
        "trailStreaks": .number(3),
        "whileThinking": .string("spin"),
        "whileListening": .string("pulse"),
    ]),
    "sounds": .object(["done": .string("Purr"), "correct": .string("Glass"), "needsYourOK": .string("Pop")]),
    "usesPicture": .bool(false),
])

/// An idea whose cursor is the picture itself.
nonisolated let goodPictureCursorThemeIdea: JSONValue = {
    var idea = replacingField(in: goodThemeIdea, at: ["cursor"], with: .object([
        "kind": .string("picture"),
        "shapes": .array([]),
        "picture": .object([
            "fit": .string("whole"),
            "outline": .string("#FFFFFF"),
            "tint": .string("#7DD3FC"),
            "tintStrength": .number(0.3),
        ]),
    ]))
    idea = replacingField(in: idea, at: ["usesPicture"], with: .bool(true))
    return idea
}()

nonisolated func parsedThemeIdea(_ idea: JSONValue = goodThemeIdea, pictureIsAvailable: Bool = false) throws -> CustomTheme {
    try CustomTheme.parse(idea: idea, id: "idea-1", pictureIsAvailable: pictureIsAvailable)
}

/// What rule an idea breaks, or nil when it parses.
nonisolated func reasonAThemeIdeaIsRefused(_ idea: JSONValue, pictureIsAvailable: Bool = false) -> String? {
    do {
        _ = try parsedThemeIdea(idea, pictureIsAvailable: pictureIsAvailable)
        return nil
    } catch let parseError as CustomThemeParseError {
        return parseError.reason
    } catch {
        return "an unexpected error: \(error)"
    }
}

// MARK: - SVG paths

struct SVGPathDataTests {
    private func commands(_ pathText: String) -> [SVGPathCommand]? {
        SVGPathData(parsing: pathText)?.commands
    }

    @Test func movesLinesAndCloseParseIntoAbsoluteCommands() {
        #expect(commands("M2 3 L10 3 L10 10 Z") == [
            .move(to: CGPoint(x: 2, y: 3)),
            .line(to: CGPoint(x: 10, y: 3)),
            .line(to: CGPoint(x: 10, y: 10)),
            .close,
        ])
    }

    @Test func horizontalAndVerticalLinesKeepTheOtherCoordinate() {
        #expect(commands("M2 3 H10 V8") == [
            .move(to: CGPoint(x: 2, y: 3)),
            .line(to: CGPoint(x: 10, y: 3)),
            .line(to: CGPoint(x: 10, y: 8)),
        ])
    }

    @Test func cubicAndQuadraticCurvesKeepTheirControlPoints() {
        #expect(commands("M1 1 C2 2 3 3 4 4 Q5 5 6 6") == [
            .move(to: CGPoint(x: 1, y: 1)),
            .cubicCurve(control1: CGPoint(x: 2, y: 2), control2: CGPoint(x: 3, y: 3), to: CGPoint(x: 4, y: 4)),
            .quadraticCurve(control: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 6)),
        ])
    }

    @Test func smoothCurvesMirrorThePreviousControlPoint() {
        // The S curve's first control point is the last cubic's second one, mirrored around the current point (4, 4).
        #expect(commands("M1 1 C2 2 3 3 4 4 S6 6 8 8") == [
            .move(to: CGPoint(x: 1, y: 1)),
            .cubicCurve(control1: CGPoint(x: 2, y: 2), control2: CGPoint(x: 3, y: 3), to: CGPoint(x: 4, y: 4)),
            .cubicCurve(control1: CGPoint(x: 5, y: 5), control2: CGPoint(x: 6, y: 6), to: CGPoint(x: 8, y: 8)),
        ])
        // The T curve mirrors the last quadratic's control point around the current point (6, 6).
        #expect(commands("M1 1 Q3 3 6 6 T9 9") == [
            .move(to: CGPoint(x: 1, y: 1)),
            .quadraticCurve(control: CGPoint(x: 3, y: 3), to: CGPoint(x: 6, y: 6)),
            .quadraticCurve(control: CGPoint(x: 9, y: 9), to: CGPoint(x: 9, y: 9)),
        ])
    }

    @Test func aSmoothCurveWithNoCurveBeforeItStartsFromTheCurrentPoint() {
        #expect(commands("M4 4 S6 6 8 8") == [
            .move(to: CGPoint(x: 4, y: 4)),
            .cubicCurve(control1: CGPoint(x: 4, y: 4), control2: CGPoint(x: 6, y: 6), to: CGPoint(x: 8, y: 8)),
        ])
    }

    @Test func lowercaseCommandsAreRelativeToTheCurrentPoint() {
        #expect(commands("m2 3 l4 5 h1 v-2 c1 1 2 2 3 3 z") == [
            .move(to: CGPoint(x: 2, y: 3)),
            .line(to: CGPoint(x: 6, y: 8)),
            .line(to: CGPoint(x: 7, y: 8)),
            .line(to: CGPoint(x: 7, y: 6)),
            .cubicCurve(control1: CGPoint(x: 8, y: 7), control2: CGPoint(x: 9, y: 8), to: CGPoint(x: 10, y: 9)),
            .close,
        ])
    }

    @Test func extraNumbersAfterAMoveDrawLinesAndAfterOtherCommandsRepeatThem() {
        #expect(commands("M1 1 5 5 L6 6 7 7") == [
            .move(to: CGPoint(x: 1, y: 1)),
            .line(to: CGPoint(x: 5, y: 5)),
            .line(to: CGPoint(x: 6, y: 6)),
            .line(to: CGPoint(x: 7, y: 7)),
        ])
    }

    @Test func aMinusSignOrASecondPointStartsTheNextNumber() {
        #expect(commands("M10-1 L1.5.5") == [
            .move(to: CGPoint(x: 10, y: -1)),
            .line(to: CGPoint(x: 1.5, y: 0.5)),
        ])
    }

    @Test func numbersWithAMinusSignAndNoSpaceParse() {
        #expect(commands("M10 -1.5L5-1") == [
            .move(to: CGPoint(x: 10, y: -1.5)),
            .line(to: CGPoint(x: 5, y: -1)),
        ])
    }

    @Test func anArcIsRefused() {
        #expect(SVGPathData(parsing: "M2 2 A5 5 0 0 1 10 10") == nil)
        #expect(SVGPathData(parsing: "M2 2 a5 5 0 0 1 10 10") == nil)
    }

    @Test func aCoordinateOutsideTheBoxIsRefused() {
        #expect(SVGPathData(parsing: "M-2 -2 L26 26") != nil)
        #expect(SVGPathData(parsing: "M-2.1 5 L10 10") == nil)
        #expect(SVGPathData(parsing: "M5 5 L26.1 10") == nil)
        // A relative command is checked by where it lands.
        #expect(SVGPathData(parsing: "M20 20 l7 0") == nil)
        // H and V check the one coordinate they write.
        #expect(SVGPathData(parsing: "M5 5 H27") == nil)
        #expect(SVGPathData(parsing: "M5 5 V-3") == nil)
        // A control point counts too.
        #expect(SVGPathData(parsing: "M5 5 Q40 5 10 10") == nil)
    }

    @Test func aPathMustStartWithAMoveAndHaveOnlyKnownCharacters() {
        #expect(SVGPathData(parsing: "L5 5") == nil)
        #expect(SVGPathData(parsing: "") == nil)
        #expect(SVGPathData(parsing: "M5 5 X6 6") == nil)
        #expect(SVGPathData(parsing: "M5 5 L1e1 5") == nil)
        #expect(SVGPathData(parsing: "M5 5 L+6 6") == nil)
        #expect(SVGPathData(parsing: "M5 5 L6") == nil)
        #expect(SVGPathData(parsing: "M5 5 L6 6 7") == nil)
        #expect(SVGPathData(parsing: "M5 5 ß6 6") == nil)
    }

    @Test func aPathOver600CharactersIsRefused() {
        // 599 characters of path, then one trailing space makes exactly 600, which the Worker allows.
        let pathOfExactlyTheLimit = "M5 5" + String(repeating: " L6 6", count: 119) + " "
        #expect(pathOfExactlyTheLimit.count == SVGPathData.longestPathText)
        #expect(SVGPathData(parsing: pathOfExactlyTheLimit) != nil)
        #expect(SVGPathData(parsing: pathOfExactlyTheLimit + " ") == nil)
    }
}

// MARK: - The idea parser

struct CustomThemeParserTests {
    @Test func aGoodIdeaParsesIntoATheme() throws {
        let theme = try parsedThemeIdea()
        #expect(theme.id == "idea-1")
        #expect(theme.name == "Moonlit")
        #expect(theme.accentHex == "#7DD3FC")
        #expect(theme.contrastHex == "#1E1B4B")
        #expect(theme.agentColorHexes == ["#7DD3FC", "#C4B5FD", "#FDE68A"])
        #expect(theme.motion == CustomCursorMotion(turnsTowardMovement: true, trailStreaks: 3, whileThinking: .spin, whileListening: .pulse))
        #expect(theme.sounds == CustomThemeSounds(done: .purr, correct: .glass, needsYourOK: .pop))
        #expect(theme.usesPicture == false)
        guard case .shapes(let shapes) = theme.cursor else {
            Issue.record("expected a shapes cursor")
            return
        }
        #expect(shapes.count == 1)
        #expect(shapes[0].fillHex == "#7DD3FC")
        #expect(shapes[0].strokeHex == "#FFFFFF")
        #expect(shapes[0].strokeWidth == 1.4)
    }

    @Test func colorsAreUppercasedAndMustBeSixDigitHex() throws {
        let lowercaseIdea = replacingField(in: goodThemeIdea, at: ["accent"], with: .string("#7dd3fc"))
        #expect(try parsedThemeIdea(lowercaseIdea).accentHex == "#7DD3FC")
        for badColor in ["7DD3FC", "#7DD3F", "#7DD3FCC", "#GGGGGG", "blue", ""] {
            #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["contrast"], with: .string(badColor)))?.contains("contrast") == true)
        }
    }

    @Test func aNameMustBeOneToTwentyFourCharacters() {
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["name"], with: .string(""))) != nil)
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["name"], with: .string(String(repeating: "a", count: 25)))) != nil)
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["name"], with: .string(String(repeating: "a", count: 24)))) == nil)
    }

    @Test func anAccentTooDarkToReadOnTheOverlayIsRefused() {
        let darkAccentIdea = replacingField(in: goodThemeIdea, at: ["accent"], with: .string("#1E1B4B"))
        #expect(reasonAThemeIdeaIsRefused(darkAccentIdea)?.contains("accent") == true)
    }

    @Test func contrastIsMeasuredTheWcagWay() throws {
        let surfaceColor = try #require(ThemeRGBColor(hex: ThemeRGBColor.overlaySurfaceHex))
        let white = try #require(ThemeRGBColor(hex: "#FFFFFF"))
        #expect(white.contrastRatio(against: surfaceColor) > 15)
        #expect(abs(try #require(ThemeRGBColor(hex: "#000000")).contrastRatio(against: white) - 21) < 0.001)
        // The Worker's own example accent has to pass, since its example reply is the shape this parses.
        #expect(try #require(ThemeRGBColor(hex: "#7DD3FC")).contrastRatio(against: surfaceColor) >= ThemeRGBColor.leastContrastAgainstTheSurface)
    }

    @Test func agentColorsNeedThreeToSix() {
        let twoColors = replacingField(in: goodThemeIdea, at: ["agentColors"], with: .array([.string("#7DD3FC"), .string("#C4B5FD")]))
        #expect(reasonAThemeIdeaIsRefused(twoColors)?.contains("agentColors") == true)
        let sevenColors = replacingField(in: goodThemeIdea, at: ["agentColors"], with: .array(Array(repeating: .string("#7DD3FC"), count: 7)))
        #expect(reasonAThemeIdeaIsRefused(sevenColors)?.contains("agentColors") == true)
    }

    @Test func anAgentColorThatLooksRedOrGreenIsRefusedBecauseThoseMeanFailedAndDone() {
        let redAgentIdea = replacingField(in: goodThemeIdea, at: ["agentColors", "1"], with: .string("#F87171"))
        #expect(reasonAThemeIdeaIsRefused(redAgentIdea)?.contains("red or green") == true)
        let greenAgentIdea = replacingField(in: goodThemeIdea, at: ["agentColors", "2"], with: .string("#4ADE80"))
        #expect(reasonAThemeIdeaIsRefused(greenAgentIdea)?.contains("red or green") == true)
    }

    /// `#RRGGBB` for a bright color at `hueDegrees`, with HSL saturation 0.9 and lightness 0.6, so it reads on the dark surface.
    private func hex(atHue hueDegrees: Double) -> String {
        let saturation = 0.9
        let lightness = 0.6
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let huePart = hueDegrees / 60
        let secondLargest = chroma * (1 - abs(huePart.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch huePart {
        case ..<1: (red, green, blue) = (chroma, secondLargest, 0)
        case ..<2: (red, green, blue) = (secondLargest, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, secondLargest)
        case ..<4: (red, green, blue) = (0, secondLargest, chroma)
        case ..<5: (red, green, blue) = (secondLargest, 0, chroma)
        default: (red, green, blue) = (chroma, 0, secondLargest)
        }
        let lightnessMatch = lightness - chroma / 2
        func byte(_ value: Double) -> Int { Int(((value + lightnessMatch) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    @Test func theRedAndGreenHueRangesStartAndEndWhereTheWorkerSays() throws {
        func looksLikeAStateColor(atHue hueDegrees: Double) throws -> Bool {
            let themeColor = try #require(ThemeRGBColor(hex: hex(atHue: hueDegrees)))
            #expect(abs(themeColor.hueDegrees - hueDegrees) < 1.5, "the test color for hue \(hueDegrees) came out at \(themeColor.hueDegrees)")
            return themeColor.looksLikeAStateColor
        }
        // Red runs from 340 through 0 to 20 degrees, and green from 95 to 165.
        #expect(try looksLikeAStateColor(atHue: 345))
        #expect(try looksLikeAStateColor(atHue: 5))
        #expect(try looksLikeAStateColor(atHue: 18))
        #expect(try !looksLikeAStateColor(atHue: 336))
        #expect(try !looksLikeAStateColor(atHue: 24))
        #expect(try looksLikeAStateColor(atHue: 100))
        #expect(try looksLikeAStateColor(atHue: 160))
        #expect(try !looksLikeAStateColor(atHue: 90))
        #expect(try !looksLikeAStateColor(atHue: 170))
        // Orange, cyan, and violet are fine.
        #expect(try !looksLikeAStateColor(atHue: 35))
        #expect(try !looksLikeAStateColor(atHue: 190))
        #expect(try !looksLikeAStateColor(atHue: 270))
    }

    @Test func aPaleOrGrayColorIsNotAStateColorEvenWithARedOrGreenHue() throws {
        // Saturation 0.35 and under reads as pastel or gray, so a soft pink stays allowed.
        let palePinkIdea = replacingField(in: goodThemeIdea, at: ["agentColors", "1"], with: .string("#E5D0D0"))
        #expect(try parsedThemeIdea(palePinkIdea).agentColorHexes[1] == "#E5D0D0")
        #expect(try #require(ThemeRGBColor(hex: "#9CA3AF")).looksLikeAStateColor == false)
    }

    @Test func anAgentColorTooDarkToReadIsRefused() {
        let darkAgentIdea = replacingField(in: goodThemeIdea, at: ["agentColors", "0"], with: .string("#1E1B4B"))
        #expect(reasonAThemeIdeaIsRefused(darkAgentIdea)?.contains("agentColors[0]") == true)
    }

    @Test func aCursorNeedsOneToSixShapes() {
        let noShapesIdea = replacingField(in: goodThemeIdea, at: ["cursor", "shapes"], with: .array([]))
        #expect(reasonAThemeIdeaIsRefused(noShapesIdea)?.contains("cursor.shapes") == true)
        let shape = goodThemeIdea["cursor"]?["shapes"]?.arrayValue?[0] ?? .null
        let sevenShapesIdea = replacingField(in: goodThemeIdea, at: ["cursor", "shapes"], with: .array(Array(repeating: shape, count: 7)))
        #expect(reasonAThemeIdeaIsRefused(sevenShapesIdea)?.contains("cursor.shapes") == true)
        let sixShapesIdea = replacingField(in: goodThemeIdea, at: ["cursor", "shapes"], with: .array(Array(repeating: shape, count: 6)))
        #expect(reasonAThemeIdeaIsRefused(sixShapesIdea) == nil)
    }

    @Test func aShapeWithABadPathIsRefused() {
        for badPath in ["M2 2 A5 5 0 0 1 10 10", "M2 2 L40 40", "L5 5", "M2 2 L"] {
            let badPathIdea = replacingField(in: goodThemeIdea, at: ["cursor", "shapes", "0", "d"], with: .string(badPath))
            #expect(reasonAThemeIdeaIsRefused(badPathIdea)?.contains("cursor.shapes[0].d") == true)
        }
    }

    @Test func aShapeNeedsAFillOrAStrokeAndASmallStrokeWidth() {
        var noPaintIdea = replacingField(in: goodThemeIdea, at: ["cursor", "shapes", "0", "fill"], with: .null)
        noPaintIdea = replacingField(in: noPaintIdea, at: ["cursor", "shapes", "0", "stroke"], with: .null)
        #expect(reasonAThemeIdeaIsRefused(noPaintIdea)?.contains("fill or a stroke") == true)
        let strokeOnlyIdea = replacingField(in: goodThemeIdea, at: ["cursor", "shapes", "0", "fill"], with: .null)
        #expect(reasonAThemeIdeaIsRefused(strokeOnlyIdea) == nil)
        let thickStrokeIdea = replacingField(in: goodThemeIdea, at: ["cursor", "shapes", "0", "strokeWidth"], with: .number(3.5))
        #expect(reasonAThemeIdeaIsRefused(thickStrokeIdea)?.contains("strokeWidth") == true)
    }

    @Test func motionRulesAreChecked() {
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["motion", "trailStreaks"], with: .number(4)))?.contains("trailStreaks") == true)
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["motion", "trailStreaks"], with: .number(1.5)))?.contains("trailStreaks") == true)
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["motion", "whileThinking"], with: .string("bounce")))?.contains("whileThinking") == true)
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["motion", "whileListening"], with: .string("spin")))?.contains("whileListening") == true)
    }

    @Test func everyMacOSSystemSoundTheWorkerAllowsParsesAndAnyOtherIsRefused() {
        let workerSoundNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
        #expect(Set(ThemeSound.allCases.map(\.rawValue)) == Set(workerSoundNames))
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["sounds", "done"], with: .string("Airhorn")))?.contains("sounds.done") == true)
    }

    @Test func usesPictureNeedsAPicture() throws {
        let usesPictureIdea = replacingField(in: goodThemeIdea, at: ["usesPicture"], with: .bool(true))
        #expect(reasonAThemeIdeaIsRefused(usesPictureIdea, pictureIsAvailable: false)?.contains("no picture") == true)
        #expect(try parsedThemeIdea(usesPictureIdea, pictureIsAvailable: true).usesPicture)
    }

    @Test func aPictureCursorParsesAndSetsUsesPictureEvenWhenTheIdeaSaidFalse() throws {
        let theme = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
        #expect(theme.cursor == .picture(CustomCursorPictureStyle(fit: .whole, outlineHex: "#FFFFFF", tintHex: "#7DD3FC", tintStrength: 0.3)))
        #expect(theme.usesPicture)
        let saidFalseIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["usesPicture"], with: .bool(false))
        #expect(try parsedThemeIdea(saidFalseIdea, pictureIsAvailable: true).usesPicture)
    }

    @Test func aPictureCursorWithoutAPictureIsRefused() {
        #expect(reasonAThemeIdeaIsRefused(goodPictureCursorThemeIdea, pictureIsAvailable: false)?.contains("picture cursor needs a picture") == true)
    }

    @Test func aPictureCursorMustHaveNoShapesAndAShapesCursorMustHaveNoPicture() {
        let shape = goodThemeIdea["cursor"]?["shapes"]?.arrayValue?[0] ?? .null
        let pictureKindWithShapes = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "shapes"], with: .array([shape]))
        #expect(reasonAThemeIdeaIsRefused(pictureKindWithShapes, pictureIsAvailable: true)?.contains("shapes must be empty") == true)
        let shapesKindWithPicture = replacingField(in: goodThemeIdea, at: ["cursor", "picture"], with: .object(["fit": .string("whole"), "outline": .string("#FFFFFF"), "tint": .null, "tintStrength": .number(0)]))
        #expect(reasonAThemeIdeaIsRefused(shapesKindWithPicture, pictureIsAvailable: true)?.contains("cursor.picture must be null") == true)
    }

    @Test func aPictureCursorNeedsItsPictureObject() {
        let missingPictureIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture"], with: .null)
        #expect(reasonAThemeIdeaIsRefused(missingPictureIdea, pictureIsAvailable: true)?.contains("cursor.picture is missing") == true)
    }

    @Test func aTintStrengthOverPointSixIsRefused() throws {
        let strongTintIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture", "tintStrength"], with: .number(0.61))
        #expect(reasonAThemeIdeaIsRefused(strongTintIdea, pictureIsAvailable: true)?.contains("tintStrength") == true)
        let negativeTintIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture", "tintStrength"], with: .number(-0.1))
        #expect(reasonAThemeIdeaIsRefused(negativeTintIdea, pictureIsAvailable: true)?.contains("tintStrength") == true)
        let limitTintIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture", "tintStrength"], with: .number(0.6))
        #expect(try parsedThemeIdea(limitTintIdea, pictureIsAvailable: true).usesPicture)
    }

    @Test func aPictureFitMustBeWholeOrCircleAndItsOutlineAColor() throws {
        let squareFitIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture", "fit"], with: .string("square"))
        #expect(reasonAThemeIdeaIsRefused(squareFitIdea, pictureIsAvailable: true)?.contains("fit") == true)
        let circleFitIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture", "fit"], with: .string("circle"))
        guard case .picture(let circleStyle) = try parsedThemeIdea(circleFitIdea, pictureIsAvailable: true).cursor else {
            Issue.record("expected a picture cursor")
            return
        }
        #expect(circleStyle.fit == .circle)
        let badOutlineIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture", "outline"], with: .string("white"))
        #expect(reasonAThemeIdeaIsRefused(badOutlineIdea, pictureIsAvailable: true)?.contains("outline") == true)
    }

    @Test func aPictureCursorMayHaveNoTint() throws {
        let noTintIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture", "tint"], with: .null)
        guard case .picture(let style) = try parsedThemeIdea(noTintIdea, pictureIsAvailable: true).cursor else {
            Issue.record("expected a picture cursor")
            return
        }
        #expect(style.tintHex == nil)
    }

    @Test func anUnknownCursorKindIsRefused() {
        let unknownKindIdea = replacingField(in: goodThemeIdea, at: ["cursor", "kind"], with: .string("emoji"))
        #expect(reasonAThemeIdeaIsRefused(unknownKindIdea)?.contains("cursor.kind") == true)
    }

    @Test func aMissingOrWronglyTypedFieldIsRefusedByName() {
        #expect(reasonAThemeIdeaIsRefused(.object([:]))?.contains("name") == true)
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["usesPicture"], with: .string("no")))?.contains("usesPicture") == true)
        #expect(reasonAThemeIdeaIsRefused(replacingField(in: goodThemeIdea, at: ["motion"], with: .null))?.contains("motion") == true)
    }

    @Test func theIdeaJSONRoundTripsThroughTheParser() throws {
        let shapesTheme = try parsedThemeIdea()
        #expect(try parsedThemeIdea(shapesTheme.ideaJSON) == shapesTheme)
        let pictureTheme = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
        #expect(try parsedThemeIdea(pictureTheme.ideaJSON, pictureIsAvailable: true) == pictureTheme)
    }
}

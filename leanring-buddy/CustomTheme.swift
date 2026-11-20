//
//  CustomTheme.swift
//  leanring-buddy
//
//  A theme the learner designed with Clicky in the Theme Studio: a cursor (SVG shapes, or the picture the learner
//  pointed at), its motion, an accent and contrast color, agent token colors, and sounds. This file holds the data and
//  the one boundary function that turns an idea from the Worker's `/theme-ideas` reply, or a saved theme.json, into a
//  `CustomTheme`. Everything past that function trusts the type, so no view re-checks a color or a path.
//  The rules match the Worker's `checkThemeIdeas` (worker/src/themeIdeas.ts), and the app applies them again because a
//  saved file can be edited by hand.
//

import CoreGraphics
import Foundation

// MARK: - Data

nonisolated struct CustomTheme: Equatable, Sendable {
    /// Assigned when the theme is saved, such as "moonlit-3f9a", and also its folder name. An idea on the studio card has a
    /// temporary id, "idea-1" to "idea-3".
    let id: String
    let name: String
    /// The cursor's glow, ring, loop, bubble, and chip color, `#RRGGBB`. Bright enough to read on the dark overlay surfaces.
    let accentHex: String
    /// For letters drawn on an accent fill, such as the navigation bubble's text.
    let contrastHex: String
    /// 3 to 6 colors the agent tokens take in turn, none of them red (failed) or green (done).
    let agentColorHexes: [String]
    let cursor: CustomCursorDrawing
    let motion: CustomCursorMotion
    let sounds: CustomThemeSounds
    /// True when the theme keeps the picture the learner pointed at, as the cursor, as the agent tokens' faces, or both.
    /// A picture cursor always uses the picture.
    let usesPicture: Bool
}

/// What the cursor looks like.
nonisolated enum CustomCursorDrawing: Equatable, Sendable {
    /// 1 to 6 SVG shapes drawn in the cursor's 24 point box.
    case shapes([CustomCursorShape])
    /// The picture itself, drawn from the theme's picture.jpg.
    case picture(CustomCursorPictureStyle)
}

nonisolated struct CustomCursorShape: Equatable, Sendable {
    /// Already parsed once at the boundary, so a view never meets a bad path.
    let path: SVGPathData
    /// The path as the model wrote it, which a saved theme.json keeps.
    let pathText: String
    let fillHex: String?
    let strokeHex: String?
    let strokeWidth: Double
}

nonisolated enum CursorPictureFit: String, Equatable, Sendable {
    /// The entire image, aspect fit, with rounded corners.
    case whole
    /// A round crop of the image's center.
    case circle
}

nonisolated struct CustomCursorPictureStyle: Equatable, Sendable {
    let fit: CursorPictureFit
    /// Drawn as a 1.5 point line around the picture, so it reads on any page.
    let outlineHex: String
    /// A color mixed over the picture, or nil for the picture as it is.
    let tintHex: String?
    /// 0 to 0.6, how strongly the tint covers the picture.
    let tintStrength: Double

    static let largestTintStrength = 0.6
}

nonisolated enum CursorThinkingMotion: String, Equatable, Sendable {
    case none, spin, pulse, wobble
}

nonisolated enum CursorListeningMotion: String, Equatable, Sendable {
    case none, pulse
}

nonisolated struct CustomCursorMotion: Equatable, Sendable {
    /// The cursor faces the mouse's movement while it follows, as the volleyball does.
    let turnsTowardMovement: Bool
    /// 0 to 3 streaks behind the cursor while it moves.
    let trailStreaks: Int
    let whileThinking: CursorThinkingMotion
    let whileListening: CursorListeningMotion
}

/// The macOS system sounds a theme may pick, which are the names `NSSound(named:)` plays.
nonisolated enum ThemeSound: String, CaseIterable, Equatable, Sendable {
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"
}

/// The three sounds a theme sets: an agent finishing, a quiz answer that is right, and an agent waiting for the learner's OK.
nonisolated struct CustomThemeSounds: Equatable, Sendable {
    let done: ThemeSound
    let correct: ThemeSound
    let needsYourOK: ThemeSound

    /// What the built-in themes play, which is what Clicky played before themes had sounds.
    static let builtIn = CustomThemeSounds(done: .tink, correct: .glass, needsYourOK: .pop)
}

// MARK: - Colors

/// A `#RRGGBB` color as numbers, for the contrast and hue rules.
nonisolated struct ThemeRGBColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// The dark surface the overlay draws the cursor, ring, and tokens on. The accent and every agent color must read on it.
    static let overlaySurfaceHex = "#101211"
    static let leastContrastAgainstTheSurface = 3.0

    /// Nil unless the text is exactly `#` and six hex digits, in either case.
    init?(hex: String) {
        guard hex.count == 7, hex.first == "#" else { return nil }
        let digits = hex.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }), let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    /// The same color the way a theme stores it, `#RRGGBB` in capitals.
    static func normalizedHex(_ hex: String) -> String? {
        ThemeRGBColor(hex: hex) == nil ? nil : hex.uppercased()
    }

    /// WCAG relative luminance, from 0 (black) to 1 (white).
    var relativeLuminance: Double {
        func linearized(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    /// WCAG contrast ratio against another color, from 1 to 21.
    func contrastRatio(against other: ThemeRGBColor) -> Double {
        let lighterLuminance = max(relativeLuminance, other.relativeLuminance)
        let darkerLuminance = min(relativeLuminance, other.relativeLuminance)
        return (lighterLuminance + 0.05) / (darkerLuminance + 0.05)
    }

    /// HSL hue in degrees, 0 to 360, and 0 for a gray.
    var hueDegrees: Double {
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let spread = highest - lowest
        guard spread > 0 else { return 0 }
        let rawHue: Double
        if highest == red {
            rawHue = ((green - blue) / spread).truncatingRemainder(dividingBy: 6)
        } else if highest == green {
            rawHue = (blue - red) / spread + 2
        } else {
            rawHue = (red - green) / spread + 4
        }
        let degrees = rawHue * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    var hslSaturation: Double {
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let lightness = (highest + lowest) / 2
        let spread = highest - lowest
        guard spread > 0 else { return 0 }
        return spread / (1 - abs(2 * lightness - 1))
    }

    /// Red means failed and green means done on a token, so an agent color may not look like either: a hue from 340 to 20
    /// degrees, or from 95 to 165 degrees, with an HSL saturation over 0.35.
    var looksLikeAStateColor: Bool {
        guard hslSaturation > 0.35 else { return false }
        let hue = hueDegrees
        let looksRed = hue >= 340 || hue <= 20
        let looksGreen = hue >= 95 && hue <= 165
        return looksRed || looksGreen
    }
}

// MARK: - The boundary

nonisolated struct CustomThemeParseError: Error, Equatable, Sendable {
    /// What rule the idea broke, in one plain sentence, for the log.
    let reason: String
}

nonisolated extension CustomTheme {
    static let longestName = 24

    /// The one place an idea becomes a `CustomTheme`. It reads the Worker's idea shape, which is also the shape of a saved
    /// theme.json, and throws `CustomThemeParseError` naming the first rule it breaks.
    ///
    /// - `id`: the temporary id of an idea on the card, or the folder name of a saved theme.
    /// - `pictureIsAvailable`: whether the request carried a picture, or whether the saved folder holds a picture.jpg.
    ///   A theme that uses the picture, or draws it as the cursor, is refused without one.
    static func parse(idea: JSONValue, id: String, pictureIsAvailable: Bool) throws -> CustomTheme {
        let reader = IdeaReader(idea, location: "idea")
        let name = try reader.string("name", lengths: 1...longestName)
        let accentHex = try reader.color("accent")
        guard let accentColor = ThemeRGBColor(hex: accentHex),
              let surfaceColor = ThemeRGBColor(hex: ThemeRGBColor.overlaySurfaceHex),
              accentColor.contrastRatio(against: surfaceColor) >= ThemeRGBColor.leastContrastAgainstTheSurface else {
            throw CustomThemeParseError(reason: "accent \(accentHex) is too dark to read on the overlay surface")
        }
        let contrastHex = try reader.color("contrast")

        let agentColorHexes = try reader.array("agentColors", counts: 3...6).enumerated().map { colorIndex, colorValue in
            guard let colorText = colorValue.stringValue, let agentHex = ThemeRGBColor.normalizedHex(colorText),
                  let agentColor = ThemeRGBColor(hex: agentHex) else {
                throw CustomThemeParseError(reason: "agentColors[\(colorIndex)] is not a #RRGGBB color")
            }
            guard agentColor.contrastRatio(against: surfaceColor) >= ThemeRGBColor.leastContrastAgainstTheSurface else {
                throw CustomThemeParseError(reason: "agentColors[\(colorIndex)] \(agentHex) is too dark to read on the overlay surface")
            }
            guard !agentColor.looksLikeAStateColor else {
                throw CustomThemeParseError(reason: "agentColors[\(colorIndex)] \(agentHex) looks red or green, which mean failed and done")
            }
            return agentHex
        }

        let cursor = try parseCursor(reader.object("cursor"), pictureIsAvailable: pictureIsAvailable)
        let motion = try parseMotion(reader.object("motion"))
        let sounds = try parseSounds(reader.object("sounds"))

        let declaredUsesPicture = try reader.bool("usesPicture")
        // A picture cursor draws the picture, so it uses it whether or not the idea said so.
        var cursorIsAPicture = false
        if case .picture = cursor { cursorIsAPicture = true }
        let usesPicture = declaredUsesPicture || cursorIsAPicture
        if usesPicture && !pictureIsAvailable {
            throw CustomThemeParseError(reason: "usesPicture is true but there is no picture")
        }

        return CustomTheme(
            id: id,
            name: name,
            accentHex: accentHex,
            contrastHex: contrastHex,
            agentColorHexes: agentColorHexes,
            cursor: cursor,
            motion: motion,
            sounds: sounds,
            usesPicture: usesPicture
        )
    }

    private static func parseCursor(_ cursorReader: IdeaReader, pictureIsAvailable: Bool) throws -> CustomCursorDrawing {
        let kind = try cursorReader.string("kind", lengths: 1...20)
        let shapeValues = try cursorReader.array("shapes", counts: 0...6)
        let pictureValue = cursorReader.optionalValue("picture")
        switch kind {
        case "shapes":
            guard !shapeValues.isEmpty else { throw CustomThemeParseError(reason: "cursor.shapes needs 1 to 6 shapes") }
            guard pictureValue == nil || pictureValue == .null else {
                throw CustomThemeParseError(reason: "cursor.picture must be null when kind is shapes")
            }
            let shapes = try shapeValues.enumerated().map { shapeIndex, shapeValue in
                try parseShape(IdeaReader(shapeValue, location: "cursor.shapes[\(shapeIndex)]"))
            }
            return .shapes(shapes)
        case "picture":
            guard shapeValues.isEmpty else { throw CustomThemeParseError(reason: "cursor.shapes must be empty when kind is picture") }
            guard pictureIsAvailable else { throw CustomThemeParseError(reason: "a picture cursor needs a picture") }
            guard let pictureValue, pictureValue != .null else { throw CustomThemeParseError(reason: "cursor.picture is missing") }
            return .picture(try parsePictureStyle(IdeaReader(pictureValue, location: "cursor.picture")))
        default:
            throw CustomThemeParseError(reason: "cursor.kind must be shapes or picture")
        }
    }

    private static func parseShape(_ shapeReader: IdeaReader) throws -> CustomCursorShape {
        let pathText = try shapeReader.string("d", lengths: 1...SVGPathData.longestPathText)
        guard let path = SVGPathData(parsing: pathText) else {
            throw CustomThemeParseError(reason: "\(shapeReader.location).d is not a path of M L H V C S Q T Z commands inside the 24 by 24 box")
        }
        let fillHex = try shapeReader.optionalColor("fill")
        let strokeHex = try shapeReader.optionalColor("stroke")
        guard fillHex != nil || strokeHex != nil else {
            throw CustomThemeParseError(reason: "\(shapeReader.location) needs a fill or a stroke")
        }
        let strokeWidth = try shapeReader.number("strokeWidth", range: 0...3)
        return CustomCursorShape(path: path, pathText: pathText, fillHex: fillHex, strokeHex: strokeHex, strokeWidth: strokeWidth)
    }

    private static func parsePictureStyle(_ pictureReader: IdeaReader) throws -> CustomCursorPictureStyle {
        let fitText = try pictureReader.string("fit", lengths: 1...20)
        guard let fit = CursorPictureFit(rawValue: fitText) else {
            throw CustomThemeParseError(reason: "cursor.picture.fit must be whole or circle")
        }
        return CustomCursorPictureStyle(
            fit: fit,
            outlineHex: try pictureReader.color("outline"),
            tintHex: try pictureReader.optionalColor("tint"),
            tintStrength: try pictureReader.number("tintStrength", range: 0...CustomCursorPictureStyle.largestTintStrength)
        )
    }

    private static func parseMotion(_ motionReader: IdeaReader) throws -> CustomCursorMotion {
        let trailStreaks = try motionReader.number("trailStreaks", range: 0...3)
        guard trailStreaks == trailStreaks.rounded() else {
            throw CustomThemeParseError(reason: "motion.trailStreaks must be a whole number from 0 to 3")
        }
        guard let whileThinking = CursorThinkingMotion(rawValue: try motionReader.string("whileThinking", lengths: 1...20)) else {
            throw CustomThemeParseError(reason: "motion.whileThinking must be none, spin, pulse, or wobble")
        }
        guard let whileListening = CursorListeningMotion(rawValue: try motionReader.string("whileListening", lengths: 1...20)) else {
            throw CustomThemeParseError(reason: "motion.whileListening must be none or pulse")
        }
        return CustomCursorMotion(
            turnsTowardMovement: try motionReader.bool("turnsTowardMovement"),
            trailStreaks: Int(trailStreaks),
            whileThinking: whileThinking,
            whileListening: whileListening
        )
    }

    private static func parseSounds(_ soundsReader: IdeaReader) throws -> CustomThemeSounds {
        func sound(_ key: String) throws -> ThemeSound {
            guard let themeSound = ThemeSound(rawValue: try soundsReader.string(key, lengths: 1...20)) else {
                throw CustomThemeParseError(reason: "sounds.\(key) is not a macOS system sound the theme may use")
            }
            return themeSound
        }
        return CustomThemeSounds(done: try sound("done"), correct: try sound("correct"), needsYourOK: try sound("needsYourOK"))
    }
}

/// Reads typed fields out of one JSON object and names the field in the error, so each rule above is one line.
private nonisolated struct IdeaReader {
    let value: JSONValue
    let location: String

    init(_ value: JSONValue, location: String) {
        self.value = value
        self.location = location
    }

    func optionalValue(_ key: String) -> JSONValue? {
        value[key]
    }

    private func required(_ key: String) throws -> JSONValue {
        guard let fieldValue = value[key] else { throw CustomThemeParseError(reason: "\(location).\(key) is missing") }
        return fieldValue
    }

    func object(_ key: String) throws -> IdeaReader {
        let fieldValue = try required(key)
        guard fieldValue.objectValue != nil else { throw CustomThemeParseError(reason: "\(location).\(key) must be an object") }
        return IdeaReader(fieldValue, location: "\(location).\(key)")
    }

    func string(_ key: String, lengths: ClosedRange<Int>) throws -> String {
        guard let text = try required(key).stringValue, lengths.contains(text.count) else {
            throw CustomThemeParseError(reason: "\(location).\(key) must be text of \(lengths.lowerBound) to \(lengths.upperBound) characters")
        }
        return text
    }

    func bool(_ key: String) throws -> Bool {
        guard let flag = try required(key).boolValue else { throw CustomThemeParseError(reason: "\(location).\(key) must be true or false") }
        return flag
    }

    func number(_ key: String, range: ClosedRange<Double>) throws -> Double {
        guard let number = try required(key).numberValue, number.isFinite, range.contains(number) else {
            throw CustomThemeParseError(reason: "\(location).\(key) must be a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }

    func array(_ key: String, counts: ClosedRange<Int>) throws -> [JSONValue] {
        guard let items = try required(key).arrayValue, counts.contains(items.count) else {
            throw CustomThemeParseError(reason: "\(location).\(key) must be a list of \(counts.lowerBound) to \(counts.upperBound) items")
        }
        return items
    }

    func color(_ key: String) throws -> String {
        guard let text = try required(key).stringValue, let normalizedHex = ThemeRGBColor.normalizedHex(text) else {
            throw CustomThemeParseError(reason: "\(location).\(key) must be a #RRGGBB color")
        }
        return normalizedHex
    }

    /// A color, or null for none. A missing key reads as none too.
    func optionalColor(_ key: String) throws -> String? {
        guard let fieldValue = value[key], fieldValue != .null else { return nil }
        guard let text = fieldValue.stringValue, let normalizedHex = ThemeRGBColor.normalizedHex(text) else {
            throw CustomThemeParseError(reason: "\(location).\(key) must be a #RRGGBB color or null")
        }
        return normalizedHex
    }
}

// MARK: - Back to the idea shape

nonisolated extension CustomTheme {
    /// The idea shape the Worker sends and a saved theme.json holds, so `parse(idea:)` reads back what this writes.
    /// The studio sends it as `currentIdeas` when the learner refines the ideas on the card.
    var ideaJSON: JSONValue {
        let cursorJSON: JSONValue
        switch cursor {
        case .shapes(let shapes):
            cursorJSON = .object([
                "kind": .string("shapes"),
                "shapes": .array(shapes.map { shape in
                    .object([
                        "d": .string(shape.pathText),
                        "fill": shape.fillHex.map(JSONValue.string) ?? .null,
                        "stroke": shape.strokeHex.map(JSONValue.string) ?? .null,
                        "strokeWidth": .number(shape.strokeWidth),
                    ])
                }),
                "picture": .null,
            ])
        case .picture(let style):
            cursorJSON = .object([
                "kind": .string("picture"),
                "shapes": .array([]),
                "picture": .object([
                    "fit": .string(style.fit.rawValue),
                    "outline": .string(style.outlineHex),
                    "tint": style.tintHex.map(JSONValue.string) ?? .null,
                    "tintStrength": .number(style.tintStrength),
                ]),
            ])
        }
        return .object([
            "name": .string(name),
            "accent": .string(accentHex),
            "contrast": .string(contrastHex),
            "agentColors": .array(agentColorHexes.map(JSONValue.string)),
            "cursor": cursorJSON,
            "motion": .object([
                "turnsTowardMovement": .bool(motion.turnsTowardMovement),
                "trailStreaks": .number(Double(motion.trailStreaks)),
                "whileThinking": .string(motion.whileThinking.rawValue),
                "whileListening": .string(motion.whileListening.rawValue),
            ]),
            "sounds": .object([
                "done": .string(sounds.done.rawValue),
                "correct": .string(sounds.correct.rawValue),
                "needsYourOK": .string(sounds.needsYourOK.rawValue),
            ]),
            "usesPicture": .bool(usesPicture),
        ])
    }
}

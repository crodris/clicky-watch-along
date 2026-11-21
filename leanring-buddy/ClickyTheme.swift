//
//  ClickyTheme.swift
//  leanring-buddy
//
//  Every theme Clicky wears is a `ClickyTheme` read from one theme.json: the `.clickytheme` packages the app bundles
//  (Clicky blue and the volleyball schools, kept in themes/ of the repository), the themes the learner designed in the
//  Theme Studio or installed by double-clicking a file, and the ideas on the studio card. A theme sets a cursor (the
//  triangle, SVG shapes, or the picture the learner pointed at), its motion, an accent and a contrast color, how agents
//  look (their ring color and their faces), and three sounds. This file holds the data and the one boundary function that
//  turns a theme.json or a Worker idea into a `ClickyTheme`. Everything past that function trusts the type, so no view
//  re-checks a color or a path.
//  The rules match the Worker's `checkThemeIdeas` (worker/src/themeIdeas.ts), and the app applies them again because a
//  saved file can be edited by hand. Version 1 files, which the Theme Studio wrote before version 2, still parse.
//

import CoreGraphics
import Foundation

// MARK: - Data

nonisolated struct ClickyTheme: Equatable, Sendable {
    /// A bundled theme's id is written in its theme.json, such as "school-karasuno". A saved theme's id is its folder name,
    /// such as "moonlit-3f9a". An idea on the studio card has a temporary id, "idea-1" to "idea-3".
    let id: String
    let name: String
    /// The cursor's glow, ring, loop, bubble, and chip color, `#RRGGBB`. Bright enough to read on the dark overlay surfaces.
    let accentHex: String
    /// For letters drawn on an accent fill, such as the navigation bubble's text.
    let contrastHex: String
    let cursor: CustomCursorDrawing
    let motion: CustomCursorMotion
    /// The ring color and the face each agent that starts under this theme takes.
    let agents: ThemeAgents
    let sounds: CustomThemeSounds
    /// Where the theme came from, which decides how the settings name it and where its images are.
    let origin: ThemeOrigin

    /// True when the theme needs the picture the learner pointed at (picture.jpg), as the cursor, as the agents' faces, or
    /// both.
    var usesPicture: Bool {
        if case .picture = cursor { return true }
        return agents.faces == .picture
    }
}

/// Where a theme came from.
nonisolated enum ThemeOrigin: Equatable, Sendable {
    /// One of the `.clickytheme` packages in the app bundle. Its roster portraits are files in `imagesFolderURL`.
    case bundled(imagesFolderURL: URL)
    /// A theme in ~/Library/Application Support/Clicky/Themes, which the Theme Studio saved or a double-click installed.
    /// Its picture.jpg and its roster portraits are files in its folder.
    case saved(folderURL: URL)
    /// An idea on the Theme Studio card, not saved yet.
    case idea
}

/// How every agent that starts under a theme looks. An agent keeps its look for its whole life.
nonisolated struct ThemeAgents: Equatable, Sendable {
    let ring: ThemeAgentRing
    let faces: ThemeAgentFaces
}

/// The color of an agent's progress ring, triangle, chip, and list row. The color never says the agent's state: a check
/// badge says done, a cross badge says failed, and a "!" badge says it waits for the learner's OK.
nonisolated enum ThemeAgentRing: Equatable, Sendable {
    /// Each agent kind's own color while no other agent has it (study guide amber, 3D model violet, experiment lime, task
    /// teal), then the first free color of Clicky's fixed palette. Clicky blue uses this.
    case perKind
    /// 3 to 6 colors the agents take in turn, none of them red (failed) or green (done).
    case perAgent(colorHexes: [String])
    /// Every agent in the theme's accent color, as a team in its jersey color.
    case accent
}

/// What fills an agent's token, chip, and list row.
nonisolated enum ThemeAgentFaces: Equatable, Sendable {
    /// A triangle in the agent's color.
    case triangle
    /// The picture the learner pointed at, as a round face.
    case picture
    /// Named faces handed out in order, first the ones the agent list does not show (`rosterPlayerForANewAgent`).
    case roster([ThemeRosterPlayer])
}

/// One face of a roster, such as a team's player.
nonisolated struct ThemeRosterPlayer: Equatable, Hashable, Sendable {
    /// The short name the agent list and the chip show, such as "Hinata".
    let name: String
    /// The whole name, such as "Shōyō Hinata", whose first letters are the initials drawn when no portrait file is there.
    /// tools/fetch-haikyu-portraits.py looks the bundled rosters' full names up on the wiki.
    let fullName: String
    /// A jersey number the agent list shows after the name, or nil for none.
    let number: Int?
    /// The portrait's file name in the theme's images folder, or nil for initials only. A missing file falls back to the
    /// initials too, so a roster still works where the portraits are not there, as in CI or a fresh clone.
    let portraitFileName: String?

    /// The first letter of each word of the full name.
    var initials: String {
        fullName.split(separator: " ").compactMap { $0.first }.map(String.init).joined()
    }
}

/// What the cursor looks like.
nonisolated enum CustomCursorDrawing: Equatable, Sendable {
    /// Clicky's own triangle in the accent color, 16 points, which keeps its pointer angle while it follows the mouse.
    case triangle
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

    var hslLightness: Double {
        (max(red, green, blue) + min(red, green, blue)) / 2
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
    /// degrees, or from 95 to 165 degrees, with an HSL saturation over 0.35 and an HSL lightness of 0.75 or less.
    var looksLikeAStateColor: Bool {
        // A light pastel such as #F4A6C0 has a red hue but cannot be mistaken for the failed red. The Worker's
        // agentColorProblem uses the same 0.75 line.
        guard hslLightness <= 0.75, hslSaturation > 0.35 else { return false }
        let hue = hueDegrees
        let looksRed = hue >= 340 || hue <= 20
        let looksGreen = hue >= 95 && hue <= 165
        return looksRed || looksGreen
    }
}

// MARK: - The boundary

nonisolated struct CustomThemeParseError: Error, Equatable, Sendable {
    /// What rule the theme broke, in one plain sentence, for the log.
    let reason: String
}

nonisolated extension ClickyTheme {
    static let longestName = 24
    /// The theme.json version this app writes. A file with no version is version 1.
    static let newestFileVersion = 2
    static let mostRosterPlayers = 60
    static let longestPortraitFileName = 120

    /// The rule `parse` applies to a name, for a name the learner types: trimmed, then 1 to `longestName` characters. Nil when
    /// the name breaks it.
    static func validName(from typedName: String) -> String? {
        let trimmedName = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...longestName).contains(trimmedName.count) ? trimmedName : nil
    }

    /// The same theme under another name. The id stays, so everything that refers to the theme still finds it.
    func renamed(to newName: String) -> ClickyTheme {
        ClickyTheme(id: id, name: newName, accentHex: accentHex, contrastHex: contrastHex, cursor: cursor, motion: motion, agents: agents, sounds: sounds, origin: origin)
    }

    /// The same theme with another id and origin, for a theme the store saves or installs.
    func with(id newID: String, origin newOrigin: ThemeOrigin) -> ClickyTheme {
        ClickyTheme(id: newID, name: name, accentHex: accentHex, contrastHex: contrastHex, cursor: cursor, motion: motion, agents: agents, sounds: sounds, origin: newOrigin)
    }

    /// The one place a theme.json or a Worker idea becomes a `ClickyTheme`. It reads version 1 (the Theme Studio's files
    /// before version 2, with `agentColors` and `usesPicture`) and version 2 (with `agents`), and throws
    /// `CustomThemeParseError` naming the first rule it breaks.
    ///
    /// - `id`: the temporary id of an idea on the card, a saved theme's folder name, or a bundled theme's own id.
    /// - `origin`: where the theme came from, which the result keeps.
    /// - `pictureIsAvailable`: whether the request carried a picture, or whether the saved folder holds a picture.jpg.
    ///   A theme that uses the picture is refused without one.
    static func parse(themeJSON: JSONValue, id: String, origin: ThemeOrigin = .idea, pictureIsAvailable: Bool) throws -> ClickyTheme {
        let reader = IdeaReader(themeJSON, location: "theme")
        let fileVersion = try reader.optionalWholeNumber("version", range: 1...newestFileVersion) ?? 1
        let name = try reader.string("name", lengths: 1...longestName)
        let accentHex = try reader.color("accent")
        guard try readsOnTheOverlaySurface(accentHex) else {
            throw CustomThemeParseError(reason: "accent \(accentHex) is too dark to read on the overlay surface")
        }
        let contrastHex = try reader.color("contrast")
        let cursor = try parseCursor(reader.object("cursor"), pictureIsAvailable: pictureIsAvailable)
        let motion = try parseMotion(reader.object("motion"))
        let sounds = try parseSounds(reader.object("sounds"))

        let agents: ThemeAgents
        if fileVersion == 1 {
            let agentColorHexes = try parseAgentColors(reader.array("agentColors", counts: 3...6), location: "agentColors")
            // Version 1 had one switch for the picture: a theme that used it showed it as the agents' faces too, and a
            // picture cursor always used it.
            var cursorIsAPicture = false
            if case .picture = cursor { cursorIsAPicture = true }
            let facesArePictures = try reader.bool("usesPicture") || cursorIsAPicture
            agents = ThemeAgents(ring: .perAgent(colorHexes: agentColorHexes), faces: facesArePictures ? .picture : .triangle)
        } else {
            agents = try parseAgents(reader.object("agents"))
        }

        let theme = ClickyTheme(id: id, name: name, accentHex: accentHex, contrastHex: contrastHex, cursor: cursor, motion: motion, agents: agents, sounds: sounds, origin: origin)
        if theme.usesPicture && !pictureIsAvailable {
            throw CustomThemeParseError(reason: "the theme uses the picture but there is no picture")
        }
        return theme
    }

    private static func readsOnTheOverlaySurface(_ colorHex: String) throws -> Bool {
        guard let color = ThemeRGBColor(hex: colorHex), let surfaceColor = ThemeRGBColor(hex: ThemeRGBColor.overlaySurfaceHex) else {
            throw CustomThemeParseError(reason: "\(colorHex) is not a #RRGGBB color")
        }
        return color.contrastRatio(against: surfaceColor) >= ThemeRGBColor.leastContrastAgainstTheSurface
    }

    /// Agent colors must read on the dark track and never look like the failed red or the done green.
    private static func parseAgentColors(_ colorValues: [JSONValue], location: String) throws -> [String] {
        try colorValues.enumerated().map { colorIndex, colorValue in
            guard let colorText = colorValue.stringValue, let agentHex = ThemeRGBColor.normalizedHex(colorText),
                  let agentColor = ThemeRGBColor(hex: agentHex) else {
                throw CustomThemeParseError(reason: "\(location)[\(colorIndex)] is not a #RRGGBB color")
            }
            guard try readsOnTheOverlaySurface(agentHex) else {
                throw CustomThemeParseError(reason: "\(location)[\(colorIndex)] \(agentHex) is too dark to read on the overlay surface")
            }
            guard !agentColor.looksLikeAStateColor else {
                throw CustomThemeParseError(reason: "\(location)[\(colorIndex)] \(agentHex) looks red or green, which mean failed and done")
            }
            return agentHex
        }
    }

    private static func parseAgents(_ agentsReader: IdeaReader) throws -> ThemeAgents {
        let ringText = try agentsReader.string("ring", lengths: 1...20)
        let colorValues = try agentsReader.optionalArray("colors", counts: 0...6) ?? []
        let ring: ThemeAgentRing
        switch ringText {
        case "perAgent":
            guard colorValues.count >= 3 else { throw CustomThemeParseError(reason: "agents.colors needs 3 to 6 colors when ring is perAgent") }
            ring = .perAgent(colorHexes: try parseAgentColors(colorValues, location: "agents.colors"))
        case "accent", "perKind":
            // These rings never read a color list, so one in the file would be a color the learner expects and never sees.
            guard colorValues.isEmpty else { throw CustomThemeParseError(reason: "agents.colors must be empty when ring is \(ringText)") }
            ring = ringText == "accent" ? .accent : .perKind
        default:
            throw CustomThemeParseError(reason: "agents.ring must be perAgent, accent, or perKind")
        }

        let facesReader = try agentsReader.object("faces")
        let faces: ThemeAgentFaces
        switch try facesReader.string("kind", lengths: 1...20) {
        case "triangle":
            faces = .triangle
        case "picture":
            faces = .picture
        case "roster":
            if let orderText = try facesReader.optionalString("order", lengths: 1...20), orderText != "firstUnused" {
                throw CustomThemeParseError(reason: "agents.faces.order must be firstUnused")
            }
            let playerValues = try facesReader.array("players", counts: 1...mostRosterPlayers)
            let players = try playerValues.enumerated().map { playerIndex, playerValue in
                try parseRosterPlayer(IdeaReader(playerValue, location: "agents.faces.players[\(playerIndex)]"))
            }
            // The agent list tells agents apart by their player's name, so two players of one name would look like one.
            var namesSeen: Set<String> = []
            for (playerIndex, player) in players.enumerated() where !namesSeen.insert(player.name).inserted {
                throw CustomThemeParseError(reason: "agents.faces.players[\(playerIndex)].name \(player.name) is already a player's name")
            }
            faces = .roster(players)
        default:
            throw CustomThemeParseError(reason: "agents.faces.kind must be triangle, picture, or roster")
        }
        return ThemeAgents(ring: ring, faces: faces)
    }

    private static func parseRosterPlayer(_ playerReader: IdeaReader) throws -> ThemeRosterPlayer {
        let name = try playerReader.string("name", lengths: 1...longestName)
        let portraitFileName = try playerReader.optionalString("portrait", lengths: 1...longestPortraitFileName)
        if let portraitFileName, !isAPortraitPathInsideTheTheme(portraitFileName) {
            throw CustomThemeParseError(reason: "\(playerReader.location).portrait must be a file inside the theme, such as portraits/10.jpg")
        }
        return ThemeRosterPlayer(
            name: name,
            fullName: try playerReader.optionalString("fullName", lengths: 1...60) ?? name,
            number: try playerReader.optionalWholeNumber("number", range: 0...999),
            portraitFileName: portraitFileName
        )
    }

    /// A portrait path is joined onto the theme's folder, so it may only name a file below it: letters, digits, dots,
    /// hyphens, and underscores in segments split by "/", with no empty segment and none that starts with a dot, which
    /// rules out ".." and hidden files.
    static func isAPortraitPathInsideTheTheme(_ portraitPath: String) -> Bool {
        let segments = portraitPath.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.first != "." && segment.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
            }
        }
    }

    private static func parseCursor(_ cursorReader: IdeaReader, pictureIsAvailable: Bool) throws -> CustomCursorDrawing {
        let kind = try cursorReader.string("kind", lengths: 1...20)
        let shapeValues = try cursorReader.optionalArray("shapes", counts: 0...6) ?? []
        let pictureValue = cursorReader.optionalValue("picture")
        let pictureIsAbsent = pictureValue == nil || pictureValue == .null
        switch kind {
        case "triangle":
            guard shapeValues.isEmpty else { throw CustomThemeParseError(reason: "cursor.shapes must be empty when kind is triangle") }
            guard pictureIsAbsent else { throw CustomThemeParseError(reason: "cursor.picture must be null when kind is triangle") }
            return .triangle
        case "shapes":
            guard !shapeValues.isEmpty else { throw CustomThemeParseError(reason: "cursor.shapes needs 1 to 6 shapes") }
            guard pictureIsAbsent else { throw CustomThemeParseError(reason: "cursor.picture must be null when kind is shapes") }
            let shapes = try shapeValues.enumerated().map { shapeIndex, shapeValue in
                try parseShape(IdeaReader(shapeValue, location: "cursor.shapes[\(shapeIndex)]"))
            }
            return .shapes(shapes)
        case "picture":
            guard shapeValues.isEmpty else { throw CustomThemeParseError(reason: "cursor.shapes must be empty when kind is picture") }
            guard pictureIsAvailable else { throw CustomThemeParseError(reason: "a picture cursor needs a picture") }
            guard let pictureValue, !pictureIsAbsent else { throw CustomThemeParseError(reason: "cursor.picture is missing") }
            return .picture(try parsePictureStyle(IdeaReader(pictureValue, location: "cursor.picture")))
        default:
            throw CustomThemeParseError(reason: "cursor.kind must be triangle, shapes, or picture")
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
        // With no fill, the stroke is all there is to see, so a width of 0 would draw nothing.
        guard fillHex != nil || strokeWidth > 0 else {
            throw CustomThemeParseError(reason: "\(shapeReader.location) has no fill and a strokeWidth of 0, so it draws nothing")
        }
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
    /// A missing key or null reads as nil.
    func optionalString(_ key: String, lengths: ClosedRange<Int>) throws -> String? {
        guard let fieldValue = value[key], fieldValue != .null else { return nil }
        return try string(key, lengths: lengths)
    }

    /// A whole number in the range, or nil for a missing key or null.
    func optionalWholeNumber(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let fieldValue = value[key], fieldValue != .null else { return nil }
        guard let number = fieldValue.numberValue, number.isFinite, number == number.rounded(), range.contains(Int(number)) else {
            throw CustomThemeParseError(reason: "\(location).\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(number)
    }

    /// A list, or nil for a missing key or null.
    func optionalArray(_ key: String, counts: ClosedRange<Int>) throws -> [JSONValue]? {
        guard let fieldValue = value[key], fieldValue != .null else { return nil }
        return try array(key, counts: counts)
    }
}


// MARK: - Back to theme.json

nonisolated extension ClickyTheme {
    /// The version 2 theme.json shape, which the Worker also sends for an idea, so `parse(themeJSON:)` reads back what this
    /// writes. The store writes it to a saved theme's folder, and the studio sends it as `currentIdeas` when the learner
    /// refines the ideas on the card. The id is not in it: a saved theme's id is its folder name.
    var themeJSON: JSONValue {
        let cursorJSON: JSONValue
        switch cursor {
        case .triangle:
            cursorJSON = .object(["kind": .string("triangle"), "shapes": .array([]), "picture": .null])
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
            "version": .number(Double(Self.newestFileVersion)),
            "name": .string(name),
            "accent": .string(accentHex),
            "contrast": .string(contrastHex),
            "cursor": cursorJSON,
            "motion": .object([
                "turnsTowardMovement": .bool(motion.turnsTowardMovement),
                "trailStreaks": .number(Double(motion.trailStreaks)),
                "whileThinking": .string(motion.whileThinking.rawValue),
                "whileListening": .string(motion.whileListening.rawValue),
            ]),
            "agents": agents.themeJSON,
            "sounds": .object([
                "done": .string(sounds.done.rawValue),
                "correct": .string(sounds.correct.rawValue),
                "needsYourOK": .string(sounds.needsYourOK.rawValue),
            ]),
        ])
    }
}

nonisolated extension ThemeAgents {
    var themeJSON: JSONValue {
        let ringFields: [String: JSONValue]
        switch ring {
        case .perKind: ringFields = ["ring": .string("perKind"), "colors": .array([])]
        case .accent: ringFields = ["ring": .string("accent"), "colors": .array([])]
        case .perAgent(let colorHexes): ringFields = ["ring": .string("perAgent"), "colors": .array(colorHexes.map(JSONValue.string))]
        }
        let facesJSON: JSONValue
        switch faces {
        case .triangle:
            facesJSON = .object(["kind": .string("triangle")])
        case .picture:
            facesJSON = .object(["kind": .string("picture")])
        case .roster(let players):
            facesJSON = .object([
                "kind": .string("roster"),
                "order": .string("firstUnused"),
                "players": .array(players.map { player in
                    var playerFields: [String: JSONValue] = ["name": .string(player.name), "fullName": .string(player.fullName)]
                    if let number = player.number { playerFields["number"] = .number(Double(number)) }
                    if let portraitFileName = player.portraitFileName { playerFields["portrait"] = .string(portraitFileName) }
                    return .object(playerFields)
                }),
            ])
        }
        return .object(ringFields.merging(["faces": facesJSON]) { ringField, _ in ringField })
    }
}

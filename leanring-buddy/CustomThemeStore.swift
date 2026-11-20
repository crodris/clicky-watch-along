//
//  CustomThemeStore.swift
//  leanring-buddy
//
//  Saves the themes the learner designs. Each theme is a folder in ~/Library/Application Support/Clicky/Themes named by
//  the theme's id, holding theme.json (the Worker's idea shape) and, when the theme uses the picture the learner pointed
//  at, picture.jpg. A folder that does not parse is skipped with a log line, so a hand edit that breaks one theme never
//  loses the others.
//

import Foundation

nonisolated enum CustomThemeStoreError: Error, Equatable {
    /// The theme uses the picture, so saving it needs the picture's JPEG.
    case themeUsesAPictureButNoneWasGiven
    case couldNotChooseAFreeFolderName
}

nonisolated struct CustomThemeStore: Sendable {
    let themesDirectoryURL: URL

    static let themeFileName = "theme.json"
    static let pictureFileName = "picture.jpg"

    /// ~/Library/Application Support/Clicky/Themes, next to the learner's skills and mcp.json.
    static func standard() -> CustomThemeStore {
        CustomThemeStore(themesDirectoryURL: TaskAgentFolders.clickyApplicationSupportURL().appendingPathComponent("Themes", isDirectory: true))
    }

    // MARK: - Ids

    /// "moonlit-3f9a": the name as lowercase letters, digits, and hyphens, then a short suffix so two themes with one name
    /// get two folders. The id is a folder name, so it only ever holds these characters.
    static func themeID(forName themeName: String, suffix: String) -> String {
        var nameSlug = ""
        for character in themeName.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                nameSlug.append(character)
            } else if nameSlug.last != "-" {
                nameSlug.append("-")
            }
        }
        let trimmedSlug = nameSlug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmedSlug.isEmpty ? "theme" : trimmedSlug)-\(suffix)"
    }

    /// Whether a folder name is something this store made. A hand-made folder named "../x" is not.
    static func isAValidThemeID(_ themeID: String) -> Bool {
        !themeID.isEmpty && themeID.count <= 60 && themeID.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "-")
        }
    }

    // MARK: - Saving and loading

    func pictureURL(forThemeID themeID: String) -> URL {
        themesDirectoryURL
            .appendingPathComponent(themeID, isDirectory: true)
            .appendingPathComponent(Self.pictureFileName)
    }

    /// Writes the idea to its own folder and returns it with its saved id. The picture goes first and theme.json last, so a
    /// folder with a theme.json is a whole theme, and a failed save removes the folder it started.
    func save(_ idea: CustomTheme, pictureJPEG: Data?) throws -> CustomTheme {
        if idea.usesPicture && (pictureJPEG?.isEmpty ?? true) {
            throw CustomThemeStoreError.themeUsesAPictureButNoneWasGiven
        }
        let fileManager = FileManager.default
        var themeID: String?
        for _ in 0..<8 {
            let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
            let candidateID = Self.themeID(forName: idea.name, suffix: suffix)
            if !fileManager.fileExists(atPath: themesDirectoryURL.appendingPathComponent(candidateID).path) {
                themeID = candidateID
                break
            }
        }
        guard let themeID else { throw CustomThemeStoreError.couldNotChooseAFreeFolderName }

        let savedTheme = CustomTheme(
            id: themeID,
            name: idea.name,
            accentHex: idea.accentHex,
            contrastHex: idea.contrastHex,
            agentColorHexes: idea.agentColorHexes,
            cursor: idea.cursor,
            motion: idea.motion,
            sounds: idea.sounds,
            usesPicture: idea.usesPicture
        )
        let themeDirectoryURL = themesDirectoryURL.appendingPathComponent(themeID, isDirectory: true)
        try fileManager.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: true)
        do {
            if idea.usesPicture, let pictureJPEG {
                try pictureJPEG.write(to: themeDirectoryURL.appendingPathComponent(Self.pictureFileName))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(savedTheme.ideaJSON).write(to: themeDirectoryURL.appendingPathComponent(Self.themeFileName))
        } catch {
            try? fileManager.removeItem(at: themeDirectoryURL)
            throw error
        }
        return savedTheme
    }

    /// Every theme that parses, sorted by name. Anything else in the folder is skipped with a log line.
    func loadSavedThemes() -> [CustomTheme] {
        let fileManager = FileManager.default
        guard let themeDirectoryURLs = try? fileManager.contentsOfDirectory(
            at: themesDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var savedThemes: [CustomTheme] = []
        for themeDirectoryURL in themeDirectoryURLs {
            let folderName = themeDirectoryURL.lastPathComponent
            guard (try? themeDirectoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            do {
                savedThemes.append(try loadTheme(inFolderNamed: folderName))
            } catch let parseError as CustomThemeParseError {
                print("Custom themes: skipped \(folderName): \(parseError.reason)")
            } catch {
                print("Custom themes: skipped \(folderName): \(error)")
            }
        }
        return savedThemes.sorted { firstTheme, secondTheme in
            let nameOrder = firstTheme.name.localizedCaseInsensitiveCompare(secondTheme.name)
            return nameOrder == .orderedSame ? firstTheme.id < secondTheme.id : nameOrder == .orderedAscending
        }
    }

    private func loadTheme(inFolderNamed folderName: String) throws -> CustomTheme {
        guard Self.isAValidThemeID(folderName) else {
            throw CustomThemeParseError(reason: "the folder name is not a theme id")
        }
        let themeFileData = try Data(contentsOf: themesDirectoryURL
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(Self.themeFileName))
        let ideaJSON = try JSONDecoder().decode(JSONValue.self, from: themeFileData)
        let pictureIsThere = FileManager.default.fileExists(atPath: pictureURL(forThemeID: folderName).path)
        return try CustomTheme.parse(idea: ideaJSON, id: folderName, pictureIsAvailable: pictureIsThere)
    }
}

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
    /// The id is joined onto the Themes folder as a folder name, so one that is not a theme id could write outside it.
    case themeIDIsNotAValidFolderName
    /// A rename or delete named a theme id that has no folder, such as a theme already deleted.
    case noThemeHasThatID
    /// A new name is empty after trimming, or longer than `CustomTheme.longestName`.
    case themeNameIsNotValid
}

/// A theme read back from the Themes folder, with when it was saved.
nonisolated struct SavedCustomTheme: Equatable, Sendable {
    let theme: CustomTheme
    /// The modification date of the theme's theme.json, which `write` creates last, so it is the moment of the save. A hand
    /// edit moves it too. A file system that reports no date gives `.distantPast`, so that theme counts as the oldest.
    /// The settings dial's Team fan lists the newest saved themes first by this date.
    let savedDate: Date
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
        try write(savedTheme, pictureJPEG: pictureJPEG)
        return savedTheme
    }

    /// Creates the theme's own folder, which must not exist yet, and writes its files. The Themes folder is created first
    /// with its parents, and the theme's folder after it with none: `createDirectory` with intermediate folders succeeds on a
    /// folder that is already there, so a folder made between the free-name check and this call would be written into, and
    /// the cleanup below would then delete it. This way an existing folder throws before any write, and the cleanup removes
    /// only a folder this call created. An id that is not a theme id, such as "../x", throws before any folder is made,
    /// since it would put the theme outside the Themes folder.
    func write(_ savedTheme: CustomTheme, pictureJPEG: Data?) throws {
        guard Self.isAValidThemeID(savedTheme.id) else { throw CustomThemeStoreError.themeIDIsNotAValidFolderName }
        let fileManager = FileManager.default
        let themeDirectoryURL = themesDirectoryURL.appendingPathComponent(savedTheme.id, isDirectory: true)
        try fileManager.createDirectory(at: themesDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: themeDirectoryURL, withIntermediateDirectories: false)
        do {
            if savedTheme.usesPicture, let pictureJPEG {
                try pictureJPEG.write(to: themeDirectoryURL.appendingPathComponent(Self.pictureFileName))
            }
            try writeThemeFile(of: savedTheme, inFolderAt: themeDirectoryURL)
        } catch {
            try? fileManager.removeItem(at: themeDirectoryURL)
            throw error
        }
    }

    /// Writes theme.json in one step, so a crash halfway through never leaves a half-written file where a theme was.
    private func writeThemeFile(of savedTheme: CustomTheme, inFolderAt themeDirectoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(savedTheme.ideaJSON).write(
            to: themeDirectoryURL.appendingPathComponent(Self.themeFileName),
            options: .atomic
        )
    }

    // MARK: - Renaming and deleting

    /// Rewrites only the name in the theme's theme.json and returns the renamed theme. The id and the folder stay, since the
    /// saved `companionTheme` setting and the agents that wear the theme's picture refer to the id. The name follows the
    /// rule `CustomTheme.parse` applies to a saved name, after trimming the spaces a typed name often carries.
    @discardableResult
    func rename(themeID: String, to typedName: String) throws -> CustomTheme {
        let themeDirectoryURL = try existingThemeDirectoryURL(forThemeID: themeID)
        guard let newName = CustomTheme.validName(from: typedName) else { throw CustomThemeStoreError.themeNameIsNotValid }
        let renamedTheme = try loadTheme(inFolderNamed: themeID).theme.renamed(to: newName)
        try writeThemeFile(of: renamedTheme, inFolderAt: themeDirectoryURL)
        return renamedTheme
    }

    /// Removes the theme's folder with its theme.json and picture.jpg. Only a folder this store could have made goes: the id
    /// check is what keeps this inside the Themes folder, since an empty id would name the Themes folder itself, and
    /// "../x" a sibling of it.
    func delete(themeID: String) throws {
        let themeDirectoryURL = try existingThemeDirectoryURL(forThemeID: themeID)
        try FileManager.default.removeItem(at: themeDirectoryURL)
    }

    /// The folder of a saved theme. The id check comes first, before any file call, for the reason `delete` gives.
    private func existingThemeDirectoryURL(forThemeID themeID: String) throws -> URL {
        guard Self.isAValidThemeID(themeID) else { throw CustomThemeStoreError.themeIDIsNotAValidFolderName }
        let themeDirectoryURL = themesDirectoryURL.appendingPathComponent(themeID, isDirectory: true)
        var themeDirectoryIsAFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: themeDirectoryURL.path, isDirectory: &themeDirectoryIsAFolder),
              themeDirectoryIsAFolder.boolValue else {
            throw CustomThemeStoreError.noThemeHasThatID
        }
        return themeDirectoryURL
    }

    /// Every theme that parses, with its saved date, sorted by name. Anything else in the folder is skipped with a log line.
    func loadSavedThemes() -> [SavedCustomTheme] {
        let fileManager = FileManager.default
        guard let themeDirectoryURLs = try? fileManager.contentsOfDirectory(
            at: themesDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var savedThemes: [SavedCustomTheme] = []
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
        return savedThemes.sorted { firstSavedTheme, secondSavedTheme in
            let firstTheme = firstSavedTheme.theme
            let secondTheme = secondSavedTheme.theme
            let nameOrder = firstTheme.name.localizedCaseInsensitiveCompare(secondTheme.name)
            return nameOrder == .orderedSame ? firstTheme.id < secondTheme.id : nameOrder == .orderedAscending
        }
    }

    private func loadTheme(inFolderNamed folderName: String) throws -> SavedCustomTheme {
        guard Self.isAValidThemeID(folderName) else {
            throw CustomThemeParseError(reason: "the folder name is not a theme id")
        }
        let themeFileURL = themesDirectoryURL
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(Self.themeFileName)
        let themeFileData = try Data(contentsOf: themeFileURL)
        let ideaJSON = try JSONDecoder().decode(JSONValue.self, from: themeFileData)
        let pictureIsThere = FileManager.default.fileExists(atPath: pictureURL(forThemeID: folderName).path)
        let theme = try CustomTheme.parse(idea: ideaJSON, id: folderName, pictureIsAvailable: pictureIsThere)
        let savedDate = (try? themeFileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return SavedCustomTheme(theme: theme, savedDate: savedDate)
    }
}

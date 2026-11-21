//
//  CustomThemeStore.swift
//  leanring-buddy
//
//  Saves the themes the learner designs or installs. Each theme is a folder in ~/Library/Application Support/Clicky/Themes
//  named by the theme's id, holding theme.json and, when the theme uses the picture the learner pointed at, picture.jpg.
//  A folder that does not parse is skipped with a log line, so a hand edit that breaks one theme never loses the others.
//  The same folder layout is a `.clickytheme` package: the app bundles its own (`loadBundledThemes`), and a package the
//  learner double-clicks is parsed and copied in as a new saved theme (`install`).
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
    /// A new name is empty after trimming, or longer than `ClickyTheme.longestName`.
    case themeNameIsNotValid
    /// An opened file is not a `.clickytheme` folder with a theme.json in it.
    case packageIsNotAThemeFolder
}

/// A theme read back from the Themes folder, with when it was saved.
nonisolated struct SavedCustomTheme: Equatable, Sendable {
    let theme: ClickyTheme
    /// The modification date of the theme's theme.json, which `write` creates last, so it is the moment of the save. A hand
    /// edit moves it too. A file system that reports no date gives `.distantPast`, so that theme counts as the oldest.
    /// The settings dial's Team fan lists the newest saved themes first by this date.
    let savedDate: Date
}

nonisolated struct CustomThemeStore: Sendable {
    let themesDirectoryURL: URL

    static let themeFileName = "theme.json"
    static let pictureFileName = "picture.jpg"
    static let packageExtension = "clickytheme"

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

    func folderURL(forThemeID themeID: String) -> URL {
        themesDirectoryURL.appendingPathComponent(themeID, isDirectory: true)
    }

    func pictureURL(forThemeID themeID: String) -> URL {
        folderURL(forThemeID: themeID).appendingPathComponent(Self.pictureFileName)
    }

    /// Writes the idea to its own folder and returns it with its saved id. The picture goes first and theme.json last, so a
    /// folder with a theme.json is a whole theme, and a failed save removes the folder it started.
    func save(_ idea: ClickyTheme, pictureJPEG: Data?) throws -> ClickyTheme {
        if idea.usesPicture && (pictureJPEG?.isEmpty ?? true) {
            throw CustomThemeStoreError.themeUsesAPictureButNoneWasGiven
        }
        let themeID = try freeThemeID(forName: idea.name)
        let savedTheme = idea.with(id: themeID, origin: .saved(folderURL: folderURL(forThemeID: themeID)))
        try write(savedTheme, pictureJPEG: pictureJPEG)
        return savedTheme
    }

    /// "moonlit-3f9a", with a suffix no folder in the Themes folder has yet.
    private func freeThemeID(forName themeName: String) throws -> String {
        for _ in 0..<8 {
            let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
            let candidateID = Self.themeID(forName: themeName, suffix: suffix)
            if !FileManager.default.fileExists(atPath: folderURL(forThemeID: candidateID).path) {
                return candidateID
            }
        }
        throw CustomThemeStoreError.couldNotChooseAFreeFolderName
    }

    /// Creates the theme's own folder, which must not exist yet, and writes its files. The Themes folder is created first
    /// with its parents, and the theme's folder after it with none: `createDirectory` with intermediate folders succeeds on a
    /// folder that is already there, so a folder made between the free-name check and this call would be written into, and
    /// the cleanup below would then delete it. This way an existing folder throws before any write, and the cleanup removes
    /// only a folder this call created. An id that is not a theme id, such as "../x", throws before any folder is made,
    /// since it would put the theme outside the Themes folder.
    func write(_ savedTheme: ClickyTheme, pictureJPEG: Data?) throws {
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
    private func writeThemeFile(of savedTheme: ClickyTheme, inFolderAt themeDirectoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(savedTheme.themeJSON).write(
            to: themeDirectoryURL.appendingPathComponent(Self.themeFileName),
            options: .atomic
        )
    }

    // MARK: - Installing a package

    /// Parses a `.clickytheme` package the learner opened and copies it in as a new saved theme with an id of its own,
    /// which it returns. Only theme.json, picture.jpg when the theme uses it, and the roster's portrait files are copied,
    /// so nothing else in the package reaches the Themes folder. A theme.json that does not parse throws its
    /// `CustomThemeParseError` before any folder is made. A portrait the roster names but the package lacks is left out,
    /// and that face shows its initials.
    @discardableResult
    func install(packageAt packageURL: URL) throws -> ClickyTheme {
        let fileManager = FileManager.default
        var packageIsAFolder: ObjCBool = false
        let packageThemeFileURL = packageURL.appendingPathComponent(Self.themeFileName)
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &packageIsAFolder), packageIsAFolder.boolValue,
              fileManager.fileExists(atPath: packageThemeFileURL.path) else {
            throw CustomThemeStoreError.packageIsNotAThemeFolder
        }
        let packageThemeJSON = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: packageThemeFileURL))
        let packagePictureURL = packageURL.appendingPathComponent(Self.pictureFileName)
        let packagedTheme = try ClickyTheme.parse(
            themeJSON: packageThemeJSON,
            id: "installing",
            origin: .saved(folderURL: packageURL),
            pictureIsAvailable: fileManager.fileExists(atPath: packagePictureURL.path)
        )

        let themeID = try freeThemeID(forName: packagedTheme.name)
        let installedFolderURL = folderURL(forThemeID: themeID)
        let installedTheme = packagedTheme.with(id: themeID, origin: .saved(folderURL: installedFolderURL))
        let pictureJPEG = installedTheme.usesPicture ? try Data(contentsOf: packagePictureURL) : nil
        try write(installedTheme, pictureJPEG: pictureJPEG)
        if case .roster(let players) = installedTheme.agents.faces {
            do {
                for portraitFileName in Set(players.compactMap(\.portraitFileName)) {
                    // The parser kept each name to a path below the theme's folder, so neither end leaves its folder.
                    let packagedPortraitURL = packageURL.appendingPathComponent(portraitFileName)
                    guard fileManager.fileExists(atPath: packagedPortraitURL.path) else { continue }
                    let installedPortraitURL = installedFolderURL.appendingPathComponent(portraitFileName)
                    try fileManager.createDirectory(at: installedPortraitURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: packagedPortraitURL, to: installedPortraitURL)
                }
            } catch {
                // A theme that is only half there would show up in the panel, so a failed copy takes the folder back out.
                try? fileManager.removeItem(at: installedFolderURL)
                throw error
            }
        }
        return installedTheme
    }

    // MARK: - Bundled themes

    /// Every `.clickytheme` package in `directoryURL` that parses, sorted by folder name, so the number a folder name starts
    /// with sets the order the menu bar panel and the settings dial's Team fan show. A bundled theme names its own id in
    /// theme.json, and its roster portraits are files in `imagesFolderURL`. One that does not parse is skipped with a log line.
    static func loadBundledThemes(inDirectoryAt directoryURL: URL, imagesFolderURL: URL) -> [ClickyTheme] {
        let packageURLs = ((try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == packageExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return packageURLs.compactMap { packageURL in
            do {
                let themeFileData = try Data(contentsOf: packageURL.appendingPathComponent(themeFileName))
                let themeJSON = try JSONDecoder().decode(JSONValue.self, from: themeFileData)
                guard let themeID = themeJSON["id"]?.stringValue, isAValidThemeID(themeID) else {
                    throw CustomThemeParseError(reason: "a bundled theme needs an id of lowercase letters, digits, and hyphens")
                }
                return try ClickyTheme.parse(
                    themeJSON: themeJSON,
                    id: themeID,
                    origin: .bundled(imagesFolderURL: imagesFolderURL),
                    pictureIsAvailable: false
                )
            } catch let parseError as CustomThemeParseError {
                print("Themes: skipped the bundled \(packageURL.lastPathComponent): \(parseError.reason)")
            } catch {
                print("Themes: skipped the bundled \(packageURL.lastPathComponent): \(error)")
            }
            return nil
        }
    }

    // MARK: - Renaming and deleting

    /// Rewrites only the name in the theme's theme.json and returns the renamed theme. The id and the folder stay, since the
    /// saved `companionTheme` setting and the agents that wear the theme's picture refer to the id. The name follows the
    /// rule `ClickyTheme.parse` applies to a saved name, after trimming the spaces a typed name often carries.
    /// The saved date stays too when the file system allows it, since the settings dial's Team fan lists the most recently saved themes, and a renamed
    /// theme was not saved again.
    @discardableResult
    func rename(themeID: String, to typedName: String) throws -> ClickyTheme {
        let themeDirectoryURL = try existingThemeDirectoryURL(forThemeID: themeID)
        guard let newName = ClickyTheme.validName(from: typedName) else { throw CustomThemeStoreError.themeNameIsNotValid }
        let savedTheme = try loadTheme(inFolderNamed: themeID)
        let renamedTheme = savedTheme.theme.renamed(to: newName)
        try writeThemeFile(of: renamedTheme, inFolderAt: themeDirectoryURL)
        // The new name is already written, so this does not throw: a date that fails to go back only moves the theme to
        // the front of the dial's Team fan, and the panel must still show the new name.
        try? FileManager.default.setAttributes(
            [.modificationDate: savedTheme.savedDate],
            ofItemAtPath: themeDirectoryURL.appendingPathComponent(Self.themeFileName).path
        )
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
        let themeJSON = try JSONDecoder().decode(JSONValue.self, from: themeFileData)
        let pictureIsThere = FileManager.default.fileExists(atPath: pictureURL(forThemeID: folderName).path)
        let theme = try ClickyTheme.parse(
            themeJSON: themeJSON,
            id: folderName,
            origin: .saved(folderURL: folderURL(forThemeID: folderName)),
            pictureIsAvailable: pictureIsThere
        )
        let savedDate = (try? themeFileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return SavedCustomTheme(theme: theme, savedDate: savedDate)
    }
}

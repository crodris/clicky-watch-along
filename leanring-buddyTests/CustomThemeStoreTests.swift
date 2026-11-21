//
//  CustomThemeStoreTests.swift
//  leanring-buddyTests
//
//  Saving and loading the themes a learner designed, each in its own folder with theme.json and an optional picture.jpg.
//

import Foundation
import Testing
@testable import Clicky

/// A store in its own temporary folder, removed when the test ends, so a test never touches the learner's real themes.
nonisolated func withATemporaryThemeStore<Result>(_ body: (CustomThemeStore) throws -> Result) rethrows -> Result {
    let temporaryDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-theme-store-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
    return try body(CustomThemeStore(themesDirectoryURL: temporaryDirectoryURL))
}

/// The same for a test that awaits inside, which runs on the main actor with the rest of the studio.
@MainActor
func withATemporaryThemeStore<Result>(_ body: @MainActor (CustomThemeStore) async throws -> Result) async rethrows -> Result {
    let temporaryDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-theme-store-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
    return try await body(CustomThemeStore(themesDirectoryURL: temporaryDirectoryURL))
}

struct CustomThemeStoreTests {
    private let pictureBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    @Test func aSavedThemeLoadsBackEqualWithItsSavedId() throws {
        try withATemporaryThemeStore { store in
            let idea = try parsedThemeIdea()
            let savedTheme = try store.save(idea, pictureJPEG: nil)
            #expect(savedTheme.id.hasPrefix("moonlit-"))
            #expect(CustomThemeStore.isAValidThemeID(savedTheme.id))
            #expect(store.loadSavedThemes().map(\.theme) == [savedTheme])
        }
    }

    @Test func aThemeThatUsesThePictureKeepsItBesideTheThemeFile() throws {
        try withATemporaryThemeStore { store in
            let idea = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
            let savedTheme = try store.save(idea, pictureJPEG: pictureBytes)
            #expect(try Data(contentsOf: store.pictureURL(forThemeID: savedTheme.id)) == pictureBytes)
            #expect(store.loadSavedThemes().map(\.theme) == [savedTheme])
        }
    }

    @Test func aThemeThatDoesNotUseThePictureLeavesItOutEvenWhenTheStudioHasOne() throws {
        try withATemporaryThemeStore { store in
            let savedTheme = try store.save(try parsedThemeIdea(), pictureJPEG: pictureBytes)
            #expect(!FileManager.default.fileExists(atPath: store.pictureURL(forThemeID: savedTheme.id).path))
            #expect(store.loadSavedThemes().map(\.theme) == [savedTheme])
        }
    }

    @Test func aThemeThatUsesThePictureCannotBeSavedWithoutOne() throws {
        try withATemporaryThemeStore { store in
            let idea = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
            #expect(throws: CustomThemeStoreError.themeUsesAPictureButNoneWasGiven) {
                try store.save(idea, pictureJPEG: nil)
            }
            #expect(store.loadSavedThemes().isEmpty)
        }
    }

    @Test func aSavedThemeWhoseFolderLostItsPictureIsSkipped() throws {
        try withATemporaryThemeStore { store in
            let idea = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
            let savedTheme = try store.save(idea, pictureJPEG: pictureBytes)
            try FileManager.default.removeItem(at: store.pictureURL(forThemeID: savedTheme.id))
            #expect(store.loadSavedThemes().isEmpty)
        }
    }

    @Test func writingIntoAFolderThatAlreadyExistsThrowsAndLeavesItsFilesUntouched() throws {
        try withATemporaryThemeStore { store in
            let existingTheme = try store.save(try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true), pictureJPEG: pictureBytes)
            let existingFolderURL = store.themesDirectoryURL.appendingPathComponent(existingTheme.id, isDirectory: true)
            let themeFileURL = existingFolderURL.appendingPathComponent(CustomThemeStore.themeFileName)
            let themeFileBeforeTheWrite = try Data(contentsOf: themeFileURL)

            // A folder made after the free-name check holds a theme of the same id, and a second write must not touch it.
            let otherTheme = existingTheme.renamed(to: "Other")
            #expect(throws: (any Error).self) {
                try store.write(otherTheme, pictureJPEG: nil)
            }

            #expect(try Data(contentsOf: themeFileURL) == themeFileBeforeTheWrite)
            #expect(try Data(contentsOf: store.pictureURL(forThemeID: existingTheme.id)) == pictureBytes)
            #expect(store.loadSavedThemes().map(\.theme) == [existingTheme])
        }
    }

    @Test func aThemeWhoseIdIsNotAFolderNameThrowsAndCreatesNothingOutsideTheThemesFolder() throws {
        try withATemporaryThemeStore { store in
            let idea = try parsedThemeIdea()
            let escapingFolderName = "clicky-escaped-\(UUID().uuidString.lowercased())"
            // "../name" would resolve to a sibling of the Themes folder.
            let escapedFolderURL = store.themesDirectoryURL.deletingLastPathComponent().appendingPathComponent(escapingFolderName, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: escapedFolderURL) }

            for badThemeID in ["../\(escapingFolderName)", "a/b", "Moonlit", ""] {
                let themeWithABadID = idea.with(id: badThemeID, origin: .idea)
                #expect(throws: CustomThemeStoreError.themeIDIsNotAValidFolderName) {
                    try store.write(themeWithABadID, pictureJPEG: nil)
                }
            }

            #expect(!FileManager.default.fileExists(atPath: escapedFolderURL.path))
            // The guard comes first, so not even the Themes folder was made.
            #expect(!FileManager.default.fileExists(atPath: store.themesDirectoryURL.path))
        }
    }

    @Test func twoThemesWithOneNameGetTwoFolders() throws {
        try withATemporaryThemeStore { store in
            let idea = try parsedThemeIdea()
            let firstTheme = try store.save(idea, pictureJPEG: nil)
            let secondTheme = try store.save(idea, pictureJPEG: nil)
            #expect(firstTheme.id != secondTheme.id)
            #expect(store.loadSavedThemes().count == 2)
        }
    }

    @Test func themesListSortedByNameIgnoringCase() throws {
        try withATemporaryThemeStore { store in
            for themeName in ["ember", "Zen", "Aurora"] {
                _ = try store.save(try parsedThemeIdea(replacingField(in: goodThemeIdea, at: ["name"], with: .string(themeName))), pictureJPEG: nil)
            }
            #expect(store.loadSavedThemes().map(\.theme.name) == ["Aurora", "ember", "Zen"])
        }
    }

    @Test func eachLoadedThemeCarriesTheModificationDateOfItsThemeFile() throws {
        try withATemporaryThemeStore { store in
            let olderTheme = try store.save(try parsedThemeIdea(replacingField(in: goodThemeIdea, at: ["name"], with: .string("Older"))), pictureJPEG: nil)
            let newerTheme = try store.save(try parsedThemeIdea(replacingField(in: goodThemeIdea, at: ["name"], with: .string("Newer"))), pictureJPEG: nil)
            // Whole seconds, so the dates are exact on any file system, and a day ahead of the clock. APFS moves a file's
            // creation date back to match a modification date set earlier than it, which would make the two dates equal and
            // hide a read of the wrong one.
            let dayFromNow = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded() + 86_400)
            let olderSavedDate = dayFromNow
            let newerSavedDate = dayFromNow.addingTimeInterval(3600)
            for (savedTheme, savedDate) in [(olderTheme, olderSavedDate), (newerTheme, newerSavedDate)] {
                let themeFilePath = store.themesDirectoryURL
                    .appendingPathComponent(savedTheme.id, isDirectory: true)
                    .appendingPathComponent(CustomThemeStore.themeFileName).path
                try FileManager.default.setAttributes([.modificationDate: savedDate], ofItemAtPath: themeFilePath)
            }
            let savedDatesByName = Dictionary(uniqueKeysWithValues: store.loadSavedThemes().map { ($0.theme.name, $0.savedDate) })
            #expect(savedDatesByName == ["Older": olderSavedDate, "Newer": newerSavedDate])
        }
    }

    @Test func aThemeJustSavedIsDatedAtTheMomentOfTheSave() throws {
        try withATemporaryThemeStore { store in
            let momentBeforeTheSave = Date()
            _ = try store.save(try parsedThemeIdea(), pictureJPEG: nil)
            let savedDate = try #require(store.loadSavedThemes().first?.savedDate)
            // File systems round to a fraction of a second, so allow a little either way.
            #expect(abs(savedDate.timeIntervalSince(momentBeforeTheSave)) < 5)
        }
    }

    @Test func aFolderThatDoesNotParseIsSkippedAndTheOthersStillLoad() throws {
        try withATemporaryThemeStore { store in
            let goodTheme = try store.save(try parsedThemeIdea(), pictureJPEG: nil)
            // A hand edit that breaks the accent color, and a folder with no theme file at all.
            let brokenIdeaText = try String(decoding: JSONEncoder().encode(replacingField(in: goodThemeIdea, at: ["accent"], with: .string("blue"))), as: UTF8.self)
            let brokenFolderURL = store.themesDirectoryURL.appendingPathComponent("broken-0000", isDirectory: true)
            try FileManager.default.createDirectory(at: brokenFolderURL, withIntermediateDirectories: true)
            try brokenIdeaText.write(to: brokenFolderURL.appendingPathComponent(CustomThemeStore.themeFileName), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: store.themesDirectoryURL.appendingPathComponent("empty-0000", isDirectory: true), withIntermediateDirectories: true)
            #expect(store.loadSavedThemes().map(\.theme) == [goodTheme])
        }
    }

    @Test func aFolderNameThatIsNotAThemeIdIsSkipped() throws {
        try withATemporaryThemeStore { store in
            _ = try store.save(try parsedThemeIdea(), pictureJPEG: nil)
            let oddFolderURL = store.themesDirectoryURL.appendingPathComponent("Odd Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: oddFolderURL, withIntermediateDirectories: true)
            let goodIdeaText = try String(decoding: JSONEncoder().encode(goodThemeIdea), as: UTF8.self)
            try goodIdeaText.write(to: oddFolderURL.appendingPathComponent(CustomThemeStore.themeFileName), atomically: true, encoding: .utf8)
            #expect(store.loadSavedThemes().count == 1)
        }
    }

    @Test func aMissingThemesFolderLoadsNothing() {
        withATemporaryThemeStore { store in
            #expect(store.loadSavedThemes().isEmpty)
        }
    }

    @Test func idsAreLowercaseWordsWithHyphensAndASuffix() {
        #expect(CustomThemeStore.themeID(forName: "Moonlit", suffix: "3f9a") == "moonlit-3f9a")
        #expect(CustomThemeStore.themeID(forName: "Cozy  Night! Owl", suffix: "0001") == "cozy-night-owl-0001")
        #expect(CustomThemeStore.themeID(forName: "!!!", suffix: "0002") == "theme-0002")
        #expect(CustomThemeStore.themeID(forName: "Süße", suffix: "0003") == "s-e-0003")
        #expect(CustomThemeStore.isAValidThemeID("moonlit-3f9a"))
        #expect(!CustomThemeStore.isAValidThemeID("../x"))
        #expect(!CustomThemeStore.isAValidThemeID("Moonlit"))
        #expect(!CustomThemeStore.isAValidThemeID(""))
    }
}

// MARK: - Renaming and deleting

struct CustomThemeStoreRenameAndDeleteTests {
    private let pictureBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    private func themeFileJSON(of themeID: String, in store: CustomThemeStore) throws -> JSONValue {
        let themeFileURL = store.themesDirectoryURL
            .appendingPathComponent(themeID, isDirectory: true)
            .appendingPathComponent(CustomThemeStore.themeFileName)
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: themeFileURL))
    }

    /// A folder next to the Themes folder with one file in it, for a test to check a bad id never reached.
    private func makeASiblingFolder(of store: CustomThemeStore) throws -> (folderName: String, fileURL: URL) {
        let folderName = "clicky-sibling-\(UUID().uuidString.lowercased())"
        let folderURL = store.themesDirectoryURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: fileURL)
        return (folderName, fileURL)
    }

    @Test func renamingChangesOnlyTheNameAndKeepsTheIdTheFolderAndThePicture() throws {
        try withATemporaryThemeStore { store in
            let savedTheme = try store.save(try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true), pictureJPEG: pictureBytes)
            let themeFileBeforeTheRename = try themeFileJSON(of: savedTheme.id, in: store)

            let renamedTheme = try store.rename(themeID: savedTheme.id, to: "  Night Owl \n")

            #expect(renamedTheme.id == savedTheme.id)
            #expect(renamedTheme.name == "Night Owl")
            #expect(store.loadSavedThemes().map(\.theme) == [renamedTheme])
            // The file holds the old file with the name replaced and nothing else changed.
            #expect(try themeFileJSON(of: savedTheme.id, in: store) == replacingField(in: themeFileBeforeTheRename, at: ["name"], with: .string("Night Owl")))
            #expect(try Data(contentsOf: store.pictureURL(forThemeID: savedTheme.id)) == pictureBytes)
        }
    }

    @Test func renamingKeepsTheSavedDate() throws {
        try withATemporaryThemeStore { store in
            let savedTheme = try store.save(try parsedThemeIdea(), pictureJPEG: nil)
            let themeFilePath = store.themesDirectoryURL
                .appendingPathComponent(savedTheme.id, isDirectory: true)
                .appendingPathComponent(CustomThemeStore.themeFileName).path
            // Whole seconds a day ahead, for the reason `eachLoadedThemeCarriesTheModificationDateOfItsThemeFile` gives.
            let savedDate = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded() + 86_400)
            try FileManager.default.setAttributes([.modificationDate: savedDate], ofItemAtPath: themeFilePath)

            try store.rename(themeID: savedTheme.id, to: "Night Owl")
            #expect(store.loadSavedThemes().map(\.savedDate) == [savedDate])
        }
    }

    @Test func aNameThatIsEmptyOrTooLongIsRefusedAndTheFileIsLeftAlone() throws {
        try withATemporaryThemeStore { store in
            let savedTheme = try store.save(try parsedThemeIdea(), pictureJPEG: nil)
            let themeFileBeforeTheRename = try themeFileJSON(of: savedTheme.id, in: store)

            for badName in ["", "   ", "\n", String(repeating: "a", count: ClickyTheme.longestName + 1)] {
                #expect(throws: CustomThemeStoreError.themeNameIsNotValid) {
                    try store.rename(themeID: savedTheme.id, to: badName)
                }
            }
            #expect(try themeFileJSON(of: savedTheme.id, in: store) == themeFileBeforeTheRename)

            // The longest name that is allowed, counted after trimming.
            let longestAllowedName = String(repeating: "a", count: ClickyTheme.longestName)
            #expect(try store.rename(themeID: savedTheme.id, to: " \(longestAllowedName) ").name == longestAllowedName)
        }
    }

    @Test func aThemeIdWithNoFolderIsRefusedAndNothingIsCreated() throws {
        try withATemporaryThemeStore { store in
            #expect(throws: CustomThemeStoreError.noThemeHasThatID) {
                try store.rename(themeID: "gone-0000", to: "Night Owl")
            }
            #expect(throws: CustomThemeStoreError.noThemeHasThatID) {
                try store.delete(themeID: "gone-0000")
            }
            #expect(!FileManager.default.fileExists(atPath: store.themesDirectoryURL.path))

            // A file with a valid theme id for a name is not a theme folder either.
            try FileManager.default.createDirectory(at: store.themesDirectoryURL, withIntermediateDirectories: true)
            let aFileNamedLikeATheme = store.themesDirectoryURL.appendingPathComponent("file-0000")
            try Data("not a folder".utf8).write(to: aFileNamedLikeATheme)
            #expect(throws: CustomThemeStoreError.noThemeHasThatID) {
                try store.delete(themeID: "file-0000")
            }
            #expect(FileManager.default.fileExists(atPath: aFileNamedLikeATheme.path))
        }
    }

    @Test func deletingRemovesOnlyThatThemesFolder() throws {
        try withATemporaryThemeStore { store in
            let themeToDelete = try store.save(try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true), pictureJPEG: pictureBytes)
            let themeToKeep = try store.save(try parsedThemeIdea(), pictureJPEG: nil)

            try store.delete(themeID: themeToDelete.id)

            #expect(!FileManager.default.fileExists(atPath: store.themesDirectoryURL.appendingPathComponent(themeToDelete.id).path))
            #expect(store.loadSavedThemes().map(\.theme) == [themeToKeep])
            #expect(FileManager.default.fileExists(atPath: store.themesDirectoryURL.appendingPathComponent(themeToKeep.id).path))
        }
    }

    @Test func aSymbolicLinkInTheThemesFolderIsRemovedWithoutTouchingWhereItPoints() throws {
        try withATemporaryThemeStore { store in
            let outsideFolder = try makeASiblingFolder(of: store)
            let outsideFolderURL = outsideFolder.fileURL.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: outsideFolderURL) }
            try FileManager.default.createDirectory(at: store.themesDirectoryURL, withIntermediateDirectories: true)
            let linkURL = store.themesDirectoryURL.appendingPathComponent("link-0000")
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideFolderURL)

            try store.delete(themeID: "link-0000")

            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) == nil)
            #expect(FileManager.default.fileExists(atPath: outsideFolder.fileURL.path))
        }
    }

    @Test func anIdThatIsNotAFolderNameIsRefusedBeforeAnyFileIsTouched() throws {
        try withATemporaryThemeStore { store in
            let savedTheme = try store.save(try parsedThemeIdea(), pictureJPEG: nil)
            let sibling = try makeASiblingFolder(of: store)
            defer { try? FileManager.default.removeItem(at: sibling.fileURL.deletingLastPathComponent()) }

            // "../name" names a sibling of the Themes folder, and "" would name the Themes folder itself. ".." is left out on
            // purpose: with the guard broken, a test that deletes it would delete the folder above the Themes folder.
            for badThemeID in ["../\(sibling.folderName)", "a/b", "Moonlit", ""] {
                #expect(throws: CustomThemeStoreError.themeIDIsNotAValidFolderName, "delete \(badThemeID)") {
                    try store.delete(themeID: badThemeID)
                }
                #expect(throws: CustomThemeStoreError.themeIDIsNotAValidFolderName, "rename \(badThemeID)") {
                    try store.rename(themeID: badThemeID, to: "Night Owl")
                }
            }

            #expect(FileManager.default.fileExists(atPath: sibling.fileURL.path))
            #expect(store.loadSavedThemes().map(\.theme) == [savedTheme])
        }
    }

    @Test func aBadIdIsReportedBeforeABadName() throws {
        try withATemporaryThemeStore { store in
            #expect(throws: CustomThemeStoreError.themeIDIsNotAValidFolderName) {
                try store.rename(themeID: "../x", to: "")
            }
        }
    }

    // MARK: - Installing a package

    /// A `.clickytheme` folder in its own temporary folder, holding `themeJSON` and any extra files named.
    private func makeThemePackage(themeJSON: JSONValue, extraFiles: [String: Data] = [:]) throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-test-package-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Shared.clickytheme", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(themeJSON).write(to: packageURL.appendingPathComponent(CustomThemeStore.themeFileName))
        for (relativePath, fileData) in extraFiles {
            let fileURL = packageURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileData.write(to: fileURL)
        }
        return packageURL
    }

    @Test func installingAPackageCopiesItInUnderANewIdAndItLoadsBackAsASavedTheme() throws {
        try withATemporaryThemeStore { store in
            let packageURL = try makeThemePackage(themeJSON: goodVersion2ThemeJSON, extraFiles: ["notes.txt": Data("not a theme file".utf8)])
            let installedTheme = try store.install(packageAt: packageURL)
            #expect(installedTheme.name == "Moonlit")
            #expect(installedTheme.id.hasPrefix("moonlit-"))
            #expect(installedTheme.origin == .saved(folderURL: store.folderURL(forThemeID: installedTheme.id)))
            #expect(store.loadSavedThemes().map(\.theme) == [installedTheme])
            // Only the theme's own files are copied in.
            let installedFiles = try FileManager.default.contentsOfDirectory(atPath: store.folderURL(forThemeID: installedTheme.id).path)
            #expect(installedFiles == [CustomThemeStore.themeFileName])
            // The package itself is left where it was.
            #expect(FileManager.default.fileExists(atPath: packageURL.path))
        }
    }

    @Test func aPackageThatDoesNotParseIsRefusedAndNothingIsInstalled() throws {
        try withATemporaryThemeStore { store in
            let darkAccentPackage = try makeThemePackage(themeJSON: replacingField(in: goodVersion2ThemeJSON, at: ["accent"], with: .string("#101010")))
            #expect(throws: CustomThemeParseError.self) { try store.install(packageAt: darkAccentPackage) }
            let notAPackage = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-test-missing-\(UUID().uuidString).clickytheme")
            #expect(throws: CustomThemeStoreError.packageIsNotAThemeFolder) { try store.install(packageAt: notAPackage) }
            #expect(store.loadSavedThemes().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.themesDirectoryURL.path))
        }
    }

    @Test func aPackageWithAPictureNeedsItsPictureAndKeepsIt() throws {
        try withATemporaryThemeStore { store in
            let pictureFacesJSON = replacingField(in: goodVersion2ThemeJSON, at: ["agents", "faces"], with: .object(["kind": .string("picture")]))
            #expect(throws: CustomThemeParseError.self) { try store.install(packageAt: try makeThemePackage(themeJSON: pictureFacesJSON)) }
            let installedTheme = try store.install(packageAt: try makeThemePackage(themeJSON: pictureFacesJSON, extraFiles: [CustomThemeStore.pictureFileName: pictureBytes]))
            #expect(installedTheme.agents.faces == .picture)
            #expect(try Data(contentsOf: store.pictureURL(forThemeID: installedTheme.id)) == pictureBytes)
        }
    }

    @Test func aRosterPackageKeepsThePortraitsItHasAndAFaceWithoutOneShowsItsInitials() throws {
        try withATemporaryThemeStore { store in
            let rosterJSON = replacingField(in: goodVersion2ThemeJSON, at: ["agents"], with: .object([
                "ring": .string("accent"),
                "faces": .object([
                    "kind": .string("roster"),
                    "order": .string("firstUnused"),
                    "players": .array([
                        .object(["name": .string("Ace"), "number": .number(1), "portrait": .string("portraits/1.jpg")]),
                        .object(["name": .string("Blue"), "fullName": .string("Blue Sky"), "portrait": .string("portraits/2.jpg")]),
                    ]),
                ]),
            ]))
            let packageURL = try makeThemePackage(themeJSON: rosterJSON, extraFiles: ["portraits/1.jpg": pictureBytes])
            let installedTheme = try store.install(packageAt: packageURL)
            let installedFolderURL = store.folderURL(forThemeID: installedTheme.id)
            #expect(try Data(contentsOf: installedFolderURL.appendingPathComponent("portraits/1.jpg")) == pictureBytes)
            #expect(!FileManager.default.fileExists(atPath: installedFolderURL.appendingPathComponent("portraits/2.jpg").path))
            guard case .roster(let players) = installedTheme.agents.faces else {
                Issue.record("the installed theme lost its roster")
                return
            }
            let blueFace = AgentRosterFace(player: players[1], of: installedTheme)
            #expect(blueFace.portraitURL == installedFolderURL.appendingPathComponent("portraits/2.jpg"))
            #expect(players[1].initials == "BS")
            #expect(players[0].initials == "A")
        }
    }

    @Test func aSymbolicLinkInAPackageIsRefusedAndNothingIsWrittenWhereItPoints() throws {
        try withATemporaryThemeStore { store in
            // A downloaded zip that holds the package and a folder the package's portraits folder links to, such as
            // ~/Library/LaunchAgents. Install must never write through that link.
            let attackFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-test-attack-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: attackFolderURL) }
            let outsideFolderURL = attackFolderURL.appendingPathComponent("LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: outsideFolderURL, withIntermediateDirectories: true)
            try Data("plist".utf8).write(to: outsideFolderURL.appendingPathComponent("evil.plist"))
            let rosterJSON = replacingField(in: goodVersion2ThemeJSON, at: ["agents"], with: .object([
                "ring": .string("accent"),
                "faces": .object(["kind": .string("roster"), "players": .array([
                    .object(["name": .string("Link"), "portrait": .string("L")]),
                    .object(["name": .string("Evil"), "portrait": .string("L/evil.plist")]),
                ])]),
            ]))
            let packageURL = try makeThemePackage(themeJSON: rosterJSON)
            try FileManager.default.createSymbolicLink(at: packageURL.appendingPathComponent("L"), withDestinationURL: outsideFolderURL)

            #expect(throws: CustomThemeStoreError.packageFileIsNotAPlainFile("L")) { try store.install(packageAt: packageURL) }
            #expect(store.loadSavedThemes().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: outsideFolderURL.path) == ["evil.plist"])

            // A theme.json that is a link, such as one to /dev/zero, is refused before it is read.
            let linkedThemeFilePackageURL = try makeThemePackage(themeJSON: goodVersion2ThemeJSON)
            let themeFileURL = linkedThemeFilePackageURL.appendingPathComponent(CustomThemeStore.themeFileName)
            try FileManager.default.moveItem(at: themeFileURL, to: attackFolderURL.appendingPathComponent("real-theme.json"))
            try FileManager.default.createSymbolicLink(at: themeFileURL, withDestinationURL: attackFolderURL.appendingPathComponent("real-theme.json"))
            #expect(throws: CustomThemeStoreError.packageFileIsNotAPlainFile(CustomThemeStore.themeFileName)) {
                try store.install(packageAt: linkedThemeFilePackageURL)
            }
        }
    }

    @Test func theReadRefusesALinkAPipeOrAnOversizedFileSwappedInAfterTheCheck() throws {
        // The checks in plainFileData run before the read, so the read checks the open file again. Each of these reaches
        // the read directly, as a file swapped in between would.
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-test-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let regularFileURL = folderURL.appendingPathComponent("regular.jpg")
        try Data(count: 10).write(to: regularFileURL)
        #expect(try CustomThemeStore.boundedRegularFileData(at: regularFileURL, relativePath: "regular.jpg", mostBytes: 10).count == 10)
        #expect(throws: CustomThemeStoreError.packageFileIsTooLarge("regular.jpg")) {
            try CustomThemeStore.boundedRegularFileData(at: regularFileURL, relativePath: "regular.jpg", mostBytes: 9)
        }
        let linkURL = folderURL.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: regularFileURL)
        #expect(throws: CustomThemeStoreError.packageFileIsNotAPlainFile("link.jpg")) {
            try CustomThemeStore.boundedRegularFileData(at: linkURL, relativePath: "link.jpg", mostBytes: 10)
        }
        // A named pipe with no writer would block a plain read forever.
        let pipeURL = folderURL.appendingPathComponent("pipe.jpg")
        #expect(mkfifo(pipeURL.path, 0o600) == 0)
        #expect(throws: CustomThemeStoreError.packageFileIsNotAPlainFile("pipe.jpg")) {
            try CustomThemeStore.boundedRegularFileData(at: pipeURL, relativePath: "pipe.jpg", mostBytes: 10)
        }
    }

    @Test func aPortraitOverItsSizeCapIsRefusedAndNothingIsInstalled() throws {
        try withATemporaryThemeStore { store in
            let rosterJSON = replacingField(in: goodVersion2ThemeJSON, at: ["agents"], with: .object([
                "ring": .string("accent"),
                "faces": .object(["kind": .string("roster"), "players": .array([.object(["name": .string("Big"), "portrait": .string("big.jpg")])])]),
            ]))
            let packageURL = try makeThemePackage(themeJSON: rosterJSON, extraFiles: ["big.jpg": Data(count: CustomThemeStore.mostPortraitBytes + 1)])
            #expect(throws: CustomThemeStoreError.packageFileIsTooLarge("big.jpg")) { try store.install(packageAt: packageURL) }
            #expect(!FileManager.default.fileExists(atPath: store.themesDirectoryURL.path))
        }
    }

    @Test func theBundledLoaderSkipsAPackageWithoutAnIdAndKeepsFolderNameOrder() throws {
        let bundledFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-test-bundled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundledFolderURL) }
        for (folderName, themeID) in [("02-second.clickytheme", "second"), ("01-first.clickytheme", "first"), ("03-no-id.clickytheme", nil)] {
            let packageURL = bundledFolderURL.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let themeJSON = replacingField(in: goodVersion2ThemeJSON, at: ["id"], with: themeID.map(JSONValue.string) ?? .null)
            try JSONEncoder().encode(themeJSON).write(to: packageURL.appendingPathComponent(CustomThemeStore.themeFileName))
        }
        let bundledThemes = CustomThemeStore.loadBundledThemes(inDirectoryAt: bundledFolderURL, imagesFolderURL: bundledFolderURL)
        #expect(bundledThemes.map(\.id) == ["first", "second"])
        #expect(bundledThemes.first?.origin == .bundled(imagesFolderURL: bundledFolderURL))
    }
}

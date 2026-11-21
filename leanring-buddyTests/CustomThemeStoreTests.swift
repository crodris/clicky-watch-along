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
            let otherTheme = CustomTheme(
                id: existingTheme.id, name: "Other", accentHex: existingTheme.accentHex, contrastHex: existingTheme.contrastHex,
                agentColorHexes: existingTheme.agentColorHexes, cursor: existingTheme.cursor, motion: existingTheme.motion,
                sounds: existingTheme.sounds, usesPicture: false
            )
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
                let themeWithABadID = CustomTheme(
                    id: badThemeID, name: idea.name, accentHex: idea.accentHex, contrastHex: idea.contrastHex,
                    agentColorHexes: idea.agentColorHexes, cursor: idea.cursor, motion: idea.motion,
                    sounds: idea.sounds, usesPicture: false
                )
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

            for badName in ["", "   ", "\n", String(repeating: "a", count: CustomTheme.longestName + 1)] {
                #expect(throws: CustomThemeStoreError.themeNameIsNotValid) {
                    try store.rename(themeID: savedTheme.id, to: badName)
                }
            }
            #expect(try themeFileJSON(of: savedTheme.id, in: store) == themeFileBeforeTheRename)

            // The longest name that is allowed, counted after trimming.
            let longestAllowedName = String(repeating: "a", count: CustomTheme.longestName)
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
}

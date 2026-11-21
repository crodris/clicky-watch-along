//
//  CustomThemeSettingsTests.swift
//  leanring-buddyTests
//
//  How a custom theme sits in CompanionTheme and CompanionThemeSettings: its saved form, its colors and sounds, the
//  preview that every view reads through `shownTheme`, and saving an idea as the theme.
//

import Foundation
import SwiftUI
import Testing
@testable import Clicky

@MainActor
struct CustomThemeSettingsTests {
    private func customTheme(id: String = "moonlit-3f9a", sounds: CustomThemeSounds? = nil) throws -> CustomTheme {
        let baseTheme = try CustomTheme.parse(idea: goodThemeIdea, id: id, pictureIsAvailable: false)
        guard let sounds else { return baseTheme }
        return CustomTheme(
            id: baseTheme.id, name: baseTheme.name, accentHex: baseTheme.accentHex, contrastHex: baseTheme.contrastHex,
            agentColorHexes: baseTheme.agentColorHexes, cursor: baseTheme.cursor, motion: baseTheme.motion,
            sounds: sounds, usesPicture: baseTheme.usesPicture
        )
    }

    @Test func aCustomThemeReadsBackFromItsRawValueAndAnUnknownIdReadsAsClickyBlue() throws {
        let savedTheme = try customTheme()
        let theme = CompanionTheme.custom(savedTheme)
        #expect(theme.rawValue == "custom:moonlit-3f9a")
        #expect(CompanionTheme(rawValue: theme.rawValue, savedCustomThemes: [savedTheme]) == theme)
        // A theme whose folder was deleted, or one saved under another id, is no longer known.
        #expect(CompanionTheme(rawValue: theme.rawValue, savedCustomThemes: []) == .clickyBlue)
        #expect(CompanionTheme(rawValue: "custom:other-0000", savedCustomThemes: [savedTheme]) == .clickyBlue)
        #expect(CompanionTheme(rawValue: "custom:", savedCustomThemes: [savedTheme]) == .clickyBlue)
    }

    @Test func aCustomThemeTakesItsColorsFromTheTwoColorsItSet() throws {
        let theme = CompanionTheme.custom(try customTheme())
        #expect(theme.cursorColorHex == "#7DD3FC")
        #expect(theme.cursorContrastColorHex == "#1E1B4B")
        #expect(theme.cursorVolleyballColors == nil)
        #expect(theme.displayName == "Moonlit")
    }

    @Test func builtInThemesKeepTodaysSoundsAndACustomThemeSetsItsOwn() throws {
        let todaysSounds = CustomThemeSounds(done: .tink, correct: .glass, needsYourOK: .pop)
        #expect(CompanionTheme.clickyBlue.sounds == todaysSounds)
        #expect(CompanionTheme.school(.karasuno).sounds == todaysSounds)
        #expect(CompanionTheme.random.sounds == todaysSounds)
        let customSounds = CustomThemeSounds(done: .purr, correct: .hero, needsYourOK: .ping)
        #expect(CompanionTheme.custom(try customTheme(sounds: customSounds)).sounds == customSounds)
    }

    @Test func theBuiltInChoicesHoldNoCustomTheme() {
        #expect(!CompanionTheme.allChoices.contains { choice in
            if case .custom = choice { return true }
            return false
        })
        #expect(CompanionTheme.allChoices.count == 12)
    }

    @Test func theDialsTeamFanListsTheNewestSavedThemesFirstWhileTheSavedListKeepsNameOrder() throws {
        try withATemporaryThemeStore { store in
            // A day ahead of the clock, in whole seconds, so the dates are exact and APFS leaves the creation dates alone.
            let dayFromNow = Date().timeIntervalSinceReferenceDate.rounded() + 86_400
            for (themeIndex, themeName) in ["Beta", "Alpha", "Gamma"].enumerated() {
                let savedTheme = try store.save(try parsedThemeIdea(replacingField(in: goodThemeIdea, at: ["name"], with: .string(themeName))), pictureJPEG: nil)
                // Beta is the oldest and Gamma the newest, whatever the clock said while the test saved them.
                let themeFilePath = store.themesDirectoryURL
                    .appendingPathComponent(savedTheme.id, isDirectory: true)
                    .appendingPathComponent(CustomThemeStore.themeFileName).path
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceReferenceDate: dayFromNow + Double(themeIndex) * 3600)],
                    ofItemAtPath: themeFilePath
                )
            }
            let themeSettings = makeThemeSettings(customThemeStore: store)
            #expect(themeSettings.savedCustomThemes.map(\.name) == ["Alpha", "Beta", "Gamma"])
            let fans = SettingsDialFans(savedCustomThemes: themeSettings.savedCustomThemesWithSavedDates)
            #expect(fans.teamThemes.suffix(3).map(\.displayName) == ["Gamma", "Alpha", "Beta"])
        }
    }

    @Test func aCustomThemesAgentsAreNotPlayers() throws {
        var randomNumberGenerator = SeededRandomNumberGenerator(seed: 1)
        let player = nextHaikyuPlayer(
            for: .custom(try customTheme()),
            playersOfRunningAgents: [],
            playersOfEndedAgentsStillListed: [],
            randomNumberGenerator: &randomNumberGenerator
        )
        #expect(player == nil)
    }

    @Test func thePreviewShowsOverTheSavedThemeAndNeverSavesIt() throws {
        let suiteName = fixedTestDefaultsSuiteName("HaikyuThemeTests-Preview")
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let themeSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: themeStoreWithNoSavedThemes)
        themeSettings.theme = .school(.nekoma)

        let idea = try customTheme(id: "idea-2")
        themeSettings.preview(idea, picture: nil)
        #expect(themeSettings.shownTheme == .custom(idea))
        #expect(themeSettings.theme == .school(.nekoma))
        // Only the saved theme is in UserDefaults, so a relaunch during a preview comes back to the old theme.
        #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "school:nekoma")

        themeSettings.clearPreview()
        #expect(themeSettings.shownTheme == .school(.nekoma))
        #expect(themeSettings.previewTheme == nil)
    }

    @Test func savingAnIdeaMakesItTheThemeEndsThePreviewAndSurvivesARelaunch() throws {
        let suiteName = fixedTestDefaultsSuiteName("HaikyuThemeTests-SaveIdea")
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        try withATemporaryThemeStore { store in
            let themeSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store)
            let idea = try customTheme(id: "idea-1")
            themeSettings.preview(idea, picture: nil)

            let savedTheme = try themeSettings.saveAndApply(idea, pictureJPEG: nil)
            #expect(savedTheme.id != "idea-1")
            #expect(themeSettings.theme == .custom(savedTheme))
            #expect(themeSettings.shownTheme == .custom(savedTheme))
            #expect(themeSettings.previewTheme == nil)
            #expect(themeSettings.savedCustomThemes == [savedTheme])

            let relaunchedSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store)
            #expect(relaunchedSettings.theme == .custom(savedTheme))
        }
    }

    @Test func aFailedSaveLeavesTheThemeAndThePreviewAlone() throws {
        try withATemporaryThemeStore { store in
            let themeSettings = makeThemeSettings(startingWith: .school(.nekoma), customThemeStore: store)
            let pictureIdea = try CustomTheme.parse(idea: goodPictureCursorThemeIdea, id: "idea-1", pictureIsAvailable: true)
            themeSettings.preview(pictureIdea, picture: nil)

            #expect(throws: CustomThemeStoreError.themeUsesAPictureButNoneWasGiven) {
                try themeSettings.saveAndApply(pictureIdea, pictureJPEG: nil)
            }
            #expect(themeSettings.theme == .school(.nekoma))
            #expect(themeSettings.shownTheme == .custom(pictureIdea))
        }
    }

    // MARK: - Renaming and deleting a saved theme

    private func nameOnlyIdea(_ themeName: String) -> JSONValue {
        replacingField(in: goodThemeIdea, at: ["name"], with: .string(themeName))
    }

    /// A real, tiny JPEG, since the picture cache decodes the file it reads.
    private func smallPictureJPEG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .jpeg, properties: [:]))
    }

    /// Settings on their own UserDefaults suite, so a test can read the saved theme back and relaunch. The suite is fixed for
    /// the reason `makeThemeSettings` gives.
    private func withSettingsOnTheirOwnDefaults<Result>(
        _ body: (CompanionThemeSettings, UserDefaults, CustomThemeStore) throws -> Result
    ) throws -> Result {
        let suiteName = fixedTestDefaultsSuiteName("CustomThemeSettingsTests-ManageSavedThemes")
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        return try withATemporaryThemeStore { store in
            try body(CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store), testDefaults, store)
        }
    }

    @Test func renamingTheThemeInUseKeepsItInUseUnderItsNewNameAcrossARelaunch() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, testDefaults, store in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)

            try themeSettings.renameSavedTheme(themeID: savedTheme.id, to: " Night Owl ")

            let renamedTheme = try #require(themeSettings.savedCustomThemes.first)
            #expect(renamedTheme.name == "Night Owl")
            #expect(renamedTheme.id == savedTheme.id)
            #expect(themeSettings.theme == .custom(renamedTheme))
            #expect(themeSettings.shownTheme.displayName == "Night Owl")
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "custom:\(savedTheme.id)")
            #expect(CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store).theme == .custom(renamedTheme))
        }
    }

    @Test func renamingAnotherThemeLeavesTheThemeInUseAloneAndKeepsTheListInNameOrder() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let firstTheme = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Moonlit")), pictureJPEG: nil)
            let themeInUse = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Ember")), pictureJPEG: nil)

            try themeSettings.renameSavedTheme(themeID: firstTheme.id, to: "Zen")

            #expect(themeSettings.theme == .custom(themeInUse))
            #expect(themeSettings.savedCustomThemes.map(\.name) == ["Ember", "Zen"])
        }
    }

    @Test func aRefusedRenameChangesNeitherTheThemeNorTheList() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)

            #expect(throws: CustomThemeStoreError.themeNameIsNotValid) {
                try themeSettings.renameSavedTheme(themeID: savedTheme.id, to: "   ")
            }

            #expect(themeSettings.theme == .custom(savedTheme))
            #expect(themeSettings.savedCustomThemes == [savedTheme])
        }
    }

    @Test func deletingTheThemeInUseFallsBackToClickyBlueAcrossARelaunch() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, testDefaults, store in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)

            try themeSettings.deleteSavedTheme(themeID: savedTheme.id)

            #expect(themeSettings.theme == .clickyBlue)
            #expect(themeSettings.shownTheme == .clickyBlue)
            #expect(themeSettings.savedCustomThemes.isEmpty)
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == CompanionTheme.clickyBlue.rawValue)
            #expect(CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store).theme == .clickyBlue)
        }
    }

    @Test func deletingAnotherThemeLeavesTheThemeInUseAlone() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let themeToDelete = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Moonlit")), pictureJPEG: nil)
            let themeInUse = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Ember")), pictureJPEG: nil)

            try themeSettings.deleteSavedTheme(themeID: themeToDelete.id)

            #expect(themeSettings.theme == .custom(themeInUse))
            #expect(themeSettings.savedCustomThemes == [themeInUse])
        }
    }

    @Test func aBuiltInThemeInUseIsNotChangedByDeletingASavedTheme() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)
            themeSettings.theme = .school(.nekoma)

            try themeSettings.deleteSavedTheme(themeID: savedTheme.id)

            #expect(themeSettings.theme == .school(.nekoma))
        }
    }

    @Test func deletingAThemeDropsItsPictureFromTheCache() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, store in
            let pictureIdea = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
            let savedTheme = try themeSettings.saveAndApply(pictureIdea, pictureJPEG: try smallPictureJPEG())
            #expect(CustomThemePictureCache.image(forThemeID: savedTheme.id, in: store) != nil)

            try themeSettings.deleteSavedTheme(themeID: savedTheme.id)

            // The folder is gone, so a lookup that reads the disk finds no picture. A picture left in the cache would still answer.
            #expect(CustomThemePictureCache.image(forThemeID: savedTheme.id, in: store) == nil)
        }
    }

    @Test func aRunningAgentKeepsItsColorAndFaceWhenItsThemeIsRenamedAndWhenItIsDeleted() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let pictureIdea = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
            let savedTheme = try themeSettings.saveAndApply(pictureIdea, pictureJPEG: try smallPictureJPEG())
            let agentStore = BackgroundAgentStore(themeSettings: themeSettings)
            let agentID = agentStore.start(kind: .task)
            let colorWhenItStarted = try #require(agentStore.agents.first { $0.id == agentID }?.tokenColor)
            #expect(agentStore.face(for: agentID) == .themePicture(themeID: savedTheme.id))

            try themeSettings.renameSavedTheme(themeID: savedTheme.id, to: "Night Owl")
            // The picture face names the theme by id, which a rename keeps.
            #expect(agentStore.face(for: agentID) == .themePicture(themeID: savedTheme.id))
            #expect(agentStore.agents.first { $0.id == agentID }?.tokenColor == colorWhenItStarted)

            try themeSettings.deleteSavedTheme(themeID: savedTheme.id)
            #expect(agentStore.agents.first { $0.id == agentID }?.tokenColor == colorWhenItStarted)
            // An agent that starts afterward reads the theme in use, which is Clicky blue again.
            let laterAgentID = agentStore.start(kind: .task)
            #expect(agentStore.agents.first { $0.id == laterAgentID }?.tokenColor == .teal)
        }
    }
}

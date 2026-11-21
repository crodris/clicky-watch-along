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

    @Test func theMenuBarPanelListsTheBuiltInThemesThenTheSavedCustomOnes() throws {
        try withATemporaryThemeStore { store in
            let themeSettings = makeThemeSettings(customThemeStore: store)
            #expect(themeSettings.menuBarThemeChoices == CompanionTheme.allChoices)
            let savedTheme = try themeSettings.saveAndApply(try customTheme(id: "idea-1"), pictureJPEG: nil)
            #expect(themeSettings.menuBarThemeChoices == CompanionTheme.allChoices + [.custom(savedTheme)])
        }
    }

    @Test func theDialsTeamFanListsTheNewestSavedThemesFirstWhileTheMenuBarPanelKeepsNameOrder() throws {
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
            #expect(themeSettings.menuBarThemeChoices.suffix(3).map(\.displayName) == ["Alpha", "Beta", "Gamma"])
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
        let suiteName = "HaikyuThemeTests-Preview"
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
        let suiteName = "HaikyuThemeTests-SaveIdea"
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
}

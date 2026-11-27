//
//  CustomThemeSettingsTests.swift
//  leanring-buddyTests
//
//  How a saved theme sits in CompanionThemeSettings: its saved form, its colors and sounds, the preview that every view
//  reads through `shownTheme`, saving an idea as the theme, installing a `.clickytheme` file, and renaming or deleting.
//

import Foundation
import SwiftUI
import Testing
@testable import Clicky

@MainActor
struct CustomThemeSettingsTests {
    private func customTheme(id: String = "moonlit-3f9a", sounds: CustomThemeSounds? = nil) throws -> ClickyTheme {
        let baseTheme = try ClickyTheme.parse(themeJSON: goodThemeIdea, id: id, origin: .saved(folderURL: URL(fileURLWithPath: "/tmp/\(id)")), pictureIsAvailable: false)
        guard let sounds else { return baseTheme }
        return ClickyTheme(
            id: baseTheme.id, name: baseTheme.name, accentHex: baseTheme.accentHex, contrastHex: baseTheme.contrastHex,
            cursor: baseTheme.cursor, motion: baseTheme.motion, agents: baseTheme.agents, sounds: sounds, origin: baseTheme.origin
        )
    }

    @Test func aSavedThemeReadsBackFromItsSettingAndAnUnknownIdReadsAsNothing() throws {
        let savedTheme = try customTheme()
        #expect(ThemeSettingValue.of(savedTheme) == "custom:moonlit-3f9a")
        #expect(ThemeSettingValue.theme(named: "custom:moonlit-3f9a", bundledThemes: bundledThemesForTests, savedThemes: [savedTheme]) == savedTheme)
        // A theme whose folder was deleted, or one saved under another id, is no longer known, and the settings fall back.
        #expect(ThemeSettingValue.theme(named: "custom:moonlit-3f9a", bundledThemes: bundledThemesForTests, savedThemes: []) == nil)
        #expect(ThemeSettingValue.theme(named: "custom:other-0000", bundledThemes: bundledThemesForTests, savedThemes: [savedTheme]) == nil)
        #expect(ThemeSettingValue.theme(named: "custom:", bundledThemes: bundledThemesForTests, savedThemes: [savedTheme]) == nil)
        // A bundled id is not a saved one, so the two prefixes never find each other's themes.
        #expect(ThemeSettingValue.theme(named: "custom:clicky-blue", bundledThemes: bundledThemesForTests, savedThemes: []) == nil)
        #expect(ThemeSettingValue.of(clickyBlueTheme) == "bundled:clicky-blue")
    }

    @Test func aSavedThemeTakesItsColorsFromTheTwoColorsItSet() throws {
        let theme = try customTheme()
        #expect(theme.cursorColorHex == "#7DD3FC")
        #expect(theme.contrastHex == "#1E1B4B")
        #expect(theme.name == "Moonlit")
    }

    @Test func bundledThemesKeepTodaysSoundsAndASavedThemeSetsItsOwn() throws {
        let todaysSounds = CustomThemeSounds(done: .tink, correct: .glass, needsYourOK: .pop)
        for bundledTheme in bundledThemesForTests {
            #expect(bundledTheme.sounds == todaysSounds)
        }
        let customSounds = CustomThemeSounds(done: .purr, correct: .hero, needsYourOK: .ping)
        #expect(try customTheme(sounds: customSounds).sounds == customSounds)
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
            let fans = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: themeSettings.savedCustomThemesWithSavedDates)
            #expect(fans.teamThemes.suffix(3).map(\.name) == ["Gamma", "Alpha", "Beta"])
        }
    }

    @Test func aSavedThemesAgentsAreTrianglesInItsOwnColorsNotPlayers() throws {
        let look = newAgentLook(kind: .task, theme: try customTheme(), colorsInUse: [], rosterFacesOfRunningAgents: [], rosterFacesOfEndedAgentsStillListed: [])
        #expect(look.face == .triangle)
        #expect(look.tokenColor == .custom(try #require(ThemeRGBColor(hex: "#7DD3FC"))))
    }

    @Test func thePreviewShowsOverTheSavedThemeAndNeverSavesIt() throws {
        let suiteName = perRunTestDefaultsSuiteName("CustomThemeSettingsTests-Preview")
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { try? removeTestDefaultsSuite(named: suiteName) }
        let themeSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: themeStoreWithNoSavedThemes, bundledThemes: bundledThemesForTests)
        themeSettings.theme = bundledTheme("school-nekoma")

        let idea = try customTheme(id: "idea-2")
        themeSettings.preview(idea, picture: nil)
        #expect(themeSettings.shownTheme == idea)
        #expect(themeSettings.theme == bundledTheme("school-nekoma"))
        // Only the saved theme is in UserDefaults, so a relaunch during a preview comes back to the old theme.
        #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "bundled:school-nekoma")

        themeSettings.clearPreview()
        #expect(themeSettings.shownTheme == bundledTheme("school-nekoma"))
        #expect(themeSettings.previewTheme == nil)
    }

    @Test func savingAnIdeaMakesItTheThemeEndsThePreviewAndSurvivesARelaunch() throws {
        let suiteName = perRunTestDefaultsSuiteName("CustomThemeSettingsTests-SaveIdea")
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { try? removeTestDefaultsSuite(named: suiteName) }
        try withATemporaryThemeStore { store in
            let themeSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store, bundledThemes: bundledThemesForTests)
            let idea = try customTheme(id: "idea-1")
            themeSettings.preview(idea, picture: nil)

            let savedTheme = try themeSettings.saveAndApply(idea, pictureJPEG: nil)
            #expect(savedTheme.id != "idea-1")
            #expect(themeSettings.theme == savedTheme)
            #expect(themeSettings.shownTheme == savedTheme)
            #expect(themeSettings.previewTheme == nil)
            #expect(themeSettings.savedCustomThemes == [savedTheme])

            let relaunchedSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store, bundledThemes: bundledThemesForTests)
            #expect(relaunchedSettings.theme == savedTheme)
        }
    }

    @Test func aFailedSaveLeavesTheThemeAndThePreviewAlone() throws {
        try withATemporaryThemeStore { store in
            let themeSettings = makeThemeSettings(startingWith: bundledTheme("school-nekoma"), customThemeStore: store)
            let pictureIdea = try ClickyTheme.parse(themeJSON: goodPictureCursorThemeIdea, id: "idea-1", pictureIsAvailable: true)
            themeSettings.preview(pictureIdea, picture: nil)

            #expect(throws: CustomThemeStoreError.themeUsesAPictureButNoneWasGiven) {
                try themeSettings.saveAndApply(pictureIdea, pictureJPEG: nil)
            }
            #expect(themeSettings.theme == bundledTheme("school-nekoma"))
            #expect(themeSettings.shownTheme == pictureIdea)
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
        let suiteName = perRunTestDefaultsSuiteName("CustomThemeSettingsTests-ManageSavedThemes")
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { try? removeTestDefaultsSuite(named: suiteName) }
        return try withATemporaryThemeStore { store in
            try body(CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store, bundledThemes: bundledThemesForTests), testDefaults, store)
        }
    }

    @Test func renamingTheThemeInUseKeepsItInUseUnderItsNewNameAcrossARelaunch() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, testDefaults, store in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)

            try themeSettings.renameSavedTheme(themeID: savedTheme.id, to: " Night Owl ")

            let renamedTheme = try #require(themeSettings.savedCustomThemes.first)
            #expect(renamedTheme.name == "Night Owl")
            #expect(renamedTheme.id == savedTheme.id)
            #expect(themeSettings.theme == renamedTheme)
            #expect(themeSettings.shownTheme.name == "Night Owl")
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "custom:\(savedTheme.id)")
            #expect(CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store, bundledThemes: bundledThemesForTests).theme == renamedTheme)
        }
    }

    @Test func renamingAnotherThemeLeavesTheThemeInUseAloneAndKeepsTheListInNameOrder() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let firstTheme = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Moonlit")), pictureJPEG: nil)
            let themeInUse = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Ember")), pictureJPEG: nil)

            try themeSettings.renameSavedTheme(themeID: firstTheme.id, to: "Zen")

            #expect(themeSettings.theme == themeInUse)
            #expect(themeSettings.savedCustomThemes.map(\.name) == ["Ember", "Zen"])
        }
    }

    @Test func aRefusedRenameChangesNeitherTheThemeNorTheList() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)

            #expect(throws: CustomThemeStoreError.themeNameIsNotValid) {
                try themeSettings.renameSavedTheme(themeID: savedTheme.id, to: "   ")
            }

            #expect(themeSettings.theme == savedTheme)
            #expect(themeSettings.savedCustomThemes == [savedTheme])
        }
    }

    @Test func deletingTheThemeInUseFallsBackToClickyBlueAcrossARelaunch() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, testDefaults, store in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)

            try themeSettings.deleteSavedTheme(themeID: savedTheme.id)

            #expect(themeSettings.theme == clickyBlueTheme)
            #expect(themeSettings.shownTheme == clickyBlueTheme)
            #expect(themeSettings.savedCustomThemes.isEmpty)
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "bundled:clicky-blue")
            #expect(CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: store, bundledThemes: bundledThemesForTests).theme == clickyBlueTheme)
        }
    }

    @Test func deletingAnotherThemeLeavesTheThemeInUseAlone() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let themeToDelete = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Moonlit")), pictureJPEG: nil)
            let themeInUse = try themeSettings.saveAndApply(try parsedThemeIdea(nameOnlyIdea("Ember")), pictureJPEG: nil)

            try themeSettings.deleteSavedTheme(themeID: themeToDelete.id)

            #expect(themeSettings.theme == themeInUse)
            #expect(themeSettings.savedCustomThemes == [themeInUse])
        }
    }

    @Test func aBuiltInThemeInUseIsNotChangedByDeletingASavedTheme() throws {
        try withSettingsOnTheirOwnDefaults { themeSettings, _, _ in
            let savedTheme = try themeSettings.saveAndApply(try parsedThemeIdea(), pictureJPEG: nil)
            themeSettings.theme = bundledTheme("school-nekoma")

            try themeSettings.deleteSavedTheme(themeID: savedTheme.id)

            #expect(themeSettings.theme == bundledTheme("school-nekoma"))
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

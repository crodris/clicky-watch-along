//
//  HaikyuThemeTests.swift
//  leanring-buddyTests
//
//  The Haikyu!! team theme: how a player is picked, the saved theme, portrait file names, how the wingman formation
//  changes for portraits, and how the agent store assigns players.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Clicky

/// A generator with a fixed seed (SplitMix64), so a test about random picks gives the same picks every run.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Theme settings backed by their own UserDefaults suite, so a test never reads or changes the app's saved theme.
@MainActor
func makeThemeSettings(startingWith theme: CompanionTheme = .clickyBlue) -> CompanionThemeSettings {
    // One fixed suite for every test, since macOS keeps an empty preferences file for each suite even after its domain
    // is removed. Sharing it is safe because each test sets the theme right after this reads it and never reads the
    // saved value back. The name is a plain string UserDefaults accepts, so the optional is never nil.
    let testDefaults = UserDefaults(suiteName: "HaikyuThemeTests")!
    let themeSettings = CompanionThemeSettings(userDefaults: testDefaults)
    themeSettings.theme = theme
    return themeSettings
}

@MainActor
func makeBackgroundAgentStore(theme: CompanionTheme = .clickyBlue) -> BackgroundAgentStore {
    BackgroundAgentStore(themeSettings: makeThemeSettings(startingWith: theme))
}

@MainActor
struct HaikyuThemeTests {
    private func nextPlayer(for theme: CompanionTheme, running: [HaikyuPlayer], ended: [HaikyuPlayer] = [], seed: UInt64 = 1) -> HaikyuPlayer? {
        var randomNumberGenerator = SeededRandomNumberGenerator(seed: seed)
        return nextHaikyuPlayer(for: theme, playersOfRunningAgents: running, playersOfEndedAgentsStillListed: ended, randomNumberGenerator: &randomNumberGenerator)
    }

    @Test func aPlayerWhoseAgentEndedIsNotReusedWhileTheListStillShowsThemAndOthersAreFree() async throws {
        let roster = HaikyuSchool.karasuno.roster
        #expect(nextPlayer(for: .school(.karasuno), running: [roster[0]], ended: [roster[1]]) == roster[2])
        // Once every player is listed, an ended agent's player comes back before a working one is doubled up.
        #expect(nextPlayer(for: .school(.karasuno), running: Array(roster.dropLast()), ended: [roster[roster.count - 1]]) == roster[roster.count - 1])
    }

    // MARK: - Picking a player

    @Test func aSchoolHandsOutItsRosterInPopularityOrderAndSkipsPlayersAlreadyWorking() async throws {
        let roster = HaikyuSchool.karasuno.roster
        #expect(nextPlayer(for: .school(.karasuno), running: []) == roster[0])
        #expect(nextPlayer(for: .school(.karasuno), running: [roster[0]]) == roster[1])
        // The second player is free, so the next agent fills that gap before taking the third.
        #expect(nextPlayer(for: .school(.karasuno), running: [roster[0], roster[2]]) == roster[1])
        #expect(roster[0].displayName == "Hinata")
    }

    @Test func aSchoolReusesPlayersOnceEveryoneIsWorking() async throws {
        let roster = HaikyuSchool.kamomedai.roster
        #expect(roster.count == 2)
        #expect(nextPlayer(for: .school(.kamomedai), running: roster) == roster[0])
        #expect(nextPlayer(for: .school(.kamomedai), running: roster + [roster[0]]) == roster[1])
    }

    @Test func randomNeverPicksAWorkingPlayerWhileAnotherIsFree() async throws {
        let everyPlayer = HaikyuSchool.allCases.flatMap(\.roster)
        let theOnlyFreePlayer = everyPlayer[17]
        let everyoneElse = everyPlayer.filter { $0 != theOnlyFreePlayer }
        for seed in UInt64(1)...20 {
            #expect(nextPlayer(for: .random, running: everyoneElse, seed: seed) == theOnlyFreePlayer)
        }
        // With everyone working, any player will do, so the call still answers.
        #expect(nextPlayer(for: .random, running: everyPlayer) != nil)
    }

    @Test func randomPicksFromEveryTeamNotOneTeam() async throws {
        let schoolsPicked = Set((1...60).compactMap { seed in nextPlayer(for: .random, running: [], seed: UInt64(seed))?.school })
        #expect(schoolsPicked.count > 1)
    }

    @Test func clickyBlueBecomesNoPlayer() async throws {
        #expect(nextPlayer(for: .clickyBlue, running: []) == nil)
    }

    // MARK: - The saved theme

    @Test func everyThemeSurvivesItsSavedForm() async throws {
        let themes = [CompanionTheme.clickyBlue, .random] + HaikyuSchool.allCases.map(CompanionTheme.school)
        for theme in themes {
            #expect(CompanionTheme(rawValue: theme.rawValue) == theme)
        }
        #expect(Set(themes.map(\.rawValue)).count == themes.count)
    }

    @Test func anUnknownSavedThemeReadsAsClickyBlue() async throws {
        #expect(CompanionTheme(rawValue: "") == .clickyBlue)
        #expect(CompanionTheme(rawValue: "school:hogwarts") == .clickyBlue)
        #expect(CompanionTheme(rawValue: "karasuno") == .clickyBlue)
    }

    @Test func theThemeIsSavedWhenItChangesAndReadBackOnTheNextLaunch() async throws {
        let suiteName = "HaikyuThemeTests-SavedTheme"
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        testDefaults.removePersistentDomain(forName: suiteName)
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        #expect(CompanionThemeSettings(userDefaults: testDefaults).theme == .clickyBlue)
        CompanionThemeSettings(userDefaults: testDefaults).theme = .school(.nekoma)
        #expect(CompanionThemeSettings(userDefaults: testDefaults).theme == .school(.nekoma))
    }

    @Test func onlyATeamThemeRecolorsTheCursorAndOutlinesIt() async throws {
        #expect(CompanionTheme.clickyBlue.cursorOutlineColor == nil)
        #expect(CompanionTheme.random.cursorOutlineColor == nil)
        #expect(CompanionTheme.random.cursorColorHex == "#3380ff")
        #expect(CompanionTheme.school(.nekoma).cursorOutlineColor != nil)
        #expect(CompanionTheme.school(.nekoma).cursorColorHex == "#E0313B")
        #expect(CompanionTheme.school(.karasuno).cursorContrastColorHex == "#1A1A1A")
        #expect(!CompanionTheme.clickyBlue.usesVolleyballMenuBarIcon)
        #expect(CompanionTheme.random.usesVolleyballMenuBarIcon)
        #expect(CompanionTheme.school(.itachiyama).usesVolleyballMenuBarIcon)
    }

    // MARK: - Portrait names

    @Test func portraitFileNamesAreAsciiSlugsOfTheWikiTitle() async throws {
        let hinata = HaikyuSchool.karasuno.roster[0]
        #expect(hinata.portraitResourceName == "haikyu-shoyo-hinata")
        let izaka = try #require(HaikyuSchool.johzenji.roster.first { $0.displayName == "Izaka" })
        #expect(izaka.portraitResourceName == "haikyu-nobuyoshi-izaka")
        #expect(HaikyuPlayer.asciiSlug(of: "Tōru  Oikawa") == "toru-oikawa")
        #expect(hinata.initials == "SH")
    }

    @Test func everyPortraitFileNameIsUnique() async throws {
        let everyPlayer = HaikyuSchool.allCases.flatMap(\.roster)
        #expect(Set(everyPlayer.map(\.portraitResourceName)).count == everyPlayer.count)
        #expect(everyPlayer.allSatisfy { $0.school.roster.contains($0) })
    }

    // MARK: - Formation

    @Test func portraitWingmenSitFartherOutAndHopFartherAhead() async throws {
        let store = makeBackgroundAgentStore(theme: .school(.karasuno))
        for _ in 0..<5 { store.start(kind: .studyGuide) }
        let formation = wingmanFormation(for: store.agents)
        #expect(formation.style == .avatar)
        #expect(formation.placements.map(\.offset) == [CGSize(width: 30, height: 34), CGSize(width: 52, height: 68), CGSize(width: 74, height: 102)])
        #expect(formation.overflowCount == 2)
        #expect(formation.style.offset(forSlot: WingmanFormation.mostWingmen) == CGSize(width: 96, height: 136))
        #expect(WingmanStyle.avatar.size(forSlot: 0) == 40)
        #expect(WingmanStyle.avatar.size(forSlot: 1) == 32)
        #expect(WingmanStyle.avatar.exitScale == 1.25)
        #expect(WingmanStyle.avatar.stepLineOffset == 48)

        let finishedAgentID = try #require(store.agents.first?.id)
        store.finish(finishedAgentID, with: .readyScene)
        let hoppingFormation = wingmanFormation(for: store.agents)
        #expect(hoppingFormation.placements.first?.offset == CGSize(width: -30, height: -34))
    }

    @Test func theTriangleLookKeepsItsOldNumbers() async throws {
        #expect(WingmanStyle.triangle.offset(forSlot: 0) == CGSize(width: 15, height: 18))
        #expect(WingmanStyle.triangle.offset(forSlot: 2) == CGSize(width: 45, height: 54))
        #expect(WingmanStyle.triangle.aheadOfTheTipOffset == CGSize(width: -14, height: -20))
        #expect(WingmanStyle.triangle.size(forSlot: 0) == 11)
        #expect(WingmanStyle.triangle.size(forSlot: 2) == 11)
        #expect(WingmanStyle.triangle.exitScale == 1.8)
        #expect(WingmanStyle.triangle.stepLineOffset == 16)

        let store = makeBackgroundAgentStore()
        store.start(kind: .studyGuide)
        #expect(wingmanFormation(for: store.agents).style == .triangle)
    }

    // MARK: - The store

    @Test func theStoreGivesEachNewAgentThePlayerNextInTheRoster() async throws {
        let store = makeBackgroundAgentStore(theme: .school(.nekoma))
        let roster = HaikyuSchool.nekoma.roster
        store.start(kind: .studyGuide)
        store.start(kind: .task)
        store.start(kind: .experiment)
        #expect(store.agents.reversed().map(\.player) == [roster[0], roster[1], roster[2]])
    }

    @Test func theNextAgentSkipsAPlayerWhoseFinishedAgentTheListStillShows() async throws {
        let store = makeBackgroundAgentStore(theme: .school(.nekoma))
        let roster = HaikyuSchool.nekoma.roster
        let firstAgentID = store.start(kind: .studyGuide)
        store.start(kind: .task)
        store.finish(firstAgentID, with: .readyScene)
        store.start(kind: .experiment)
        #expect(store.agents.first?.player == roster[2])
    }

    @Test func aFailedOrCancelledAgentsPortraitBorderShowsItsStateInsteadOfTheTeamColor() async throws {
        #expect(agentListPortraitBorderColor(phase: .running(completedStepCount: 0), school: .nekoma) == HaikyuSchool.nekoma.accentColor)
        #expect(agentListPortraitBorderColor(phase: .failed(reason: "Broke"), school: .nekoma) == DS.Colors.destructive)
        #expect(agentListPortraitBorderColor(phase: .cancelled, school: .nekoma) == DS.Colors.textTertiary)
    }

    @Test func theChipMovesAboveTheCursorWhilePlayerWingmenTrailThroughTheSpotUnderIt() async throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let mouseLocation = CGPoint(x: 500, y: 500)
        let chipOriginUnderTheCursor = voiceToolCallChipOrigin(mouseLocation: mouseLocation, screenFrame: screenFrame, avatarWingmenAreShowing: false)
        let chipOriginWithPlayerWingmen = voiceToolCallChipOrigin(mouseLocation: mouseLocation, screenFrame: screenFrame, avatarWingmenAreShowing: true)
        #expect(chipOriginUnderTheCursor.y < mouseLocation.y)
        #expect(chipOriginWithPlayerWingmen.y > mouseLocation.y)
        // Near the top edge, with no room above, the chip goes below the whole trail instead of onto the cursor.
        let mouseAtTheTop = CGPoint(x: 500, y: 1100)
        let chipOriginAtTheTop = voiceToolCallChipOrigin(mouseLocation: mouseAtTheTop, screenFrame: screenFrame, avatarWingmenAreShowing: true)
        let overflowLabelBottomBelowTheMouse = 25 + WingmanStyle.avatar.offset(forSlot: WingmanFormation.mostWingmen).height + 8
        #expect(chipOriginAtTheTop.y + VoiceToolCallChip.panelSize.height < mouseAtTheTop.y - overflowLabelBottomBelowTheMouse)
    }

    @Test func everyWikiTitleIsAsciiOnceItsAccentsAreRemovedSoSwiftAndThePortraitScriptNameTheFileAlike() async throws {
        // tools/fetch-haikyu-portraits.py builds the same slug with NFKD, which agrees with Swift's folding only for
        // accented ASCII letters, so a title outside that set would make the app look for a file the script never wrote.
        for player in HaikyuSchool.allCases.flatMap(\.roster) {
            let scalarsWithoutAccents = player.wikiTitle.decomposedStringWithCanonicalMapping.unicodeScalars.filter { scalar in
                scalar.properties.generalCategory != .nonspacingMark
            }
            let titleIsAsciiWithoutAccents = scalarsWithoutAccents.allSatisfy { scalar in scalar.isASCII }
            #expect(titleIsAsciiWithoutAccents, "\(player.wikiTitle) has a letter the two slug rules may name differently")
        }
    }

    @Test func clickyBlueAgentsHaveNoPlayer() async throws {
        let store = makeBackgroundAgentStore()
        store.start(kind: .studyGuide)
        #expect(store.agents.first?.player == nil)
    }

    @Test func aRunningAgentKeepsItsPlayerWhenTheThemeChangesAndOnlyNewAgentsGetTheNewTeam() async throws {
        let themeSettings = makeThemeSettings(startingWith: .school(.karasuno))
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        let karasunoAgentID = store.start(kind: .studyGuide)
        let karasunoPlayer = store.agents.first?.player
        #expect(karasunoPlayer?.school == .karasuno)

        themeSettings.theme = .school(.inarizaki)
        let inarizakiAgentID = store.start(kind: .task)
        #expect(store.agents.first { $0.id == karasunoAgentID }?.player == karasunoPlayer)
        #expect(store.agents.first { $0.id == inarizakiAgentID }?.player == HaikyuSchool.inarizaki.roster[0])

        themeSettings.theme = .clickyBlue
        let unthemedAgentID = store.start(kind: .experiment)
        #expect(store.agents.first { $0.id == unthemedAgentID }?.player == nil)
        #expect(store.agents.first { $0.id == karasunoAgentID }?.player == karasunoPlayer)
        #expect(store.player(for: karasunoAgentID) == karasunoPlayer)
    }
}

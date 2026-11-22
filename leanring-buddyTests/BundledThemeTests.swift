//
//  BundledThemeTests.swift
//  leanring-buddyTests
//
//  The bundled `.clickytheme` files: every one parses, the volleyball schools keep their balls and rosters as data, the
//  saved setting moves from the names older versions wrote, Shuffle gives agents other themes' looks, and the agent store
//  hands out roster players.
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

/// The repository's root, found from this file's own path, which tools/swift-check.sh reaches through a symbolic link.
let repositoryRootURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()

/// The bundled themes in themes/, read by the loader the app uses.
let bundledThemesForTests = CustomThemeStore.loadBundledThemes(
    inDirectoryAt: repositoryRootURL.appendingPathComponent("themes", isDirectory: true),
    imagesFolderURL: repositoryRootURL.appendingPathComponent("leanring-buddy/HaikyuPortraits", isDirectory: true)
)

/// One bundled theme by id. A missing id is a broken fixture, so the test stops there.
func bundledTheme(_ themeID: String) -> ClickyTheme {
    guard let theme = bundledThemesForTests.first(where: { $0.id == themeID }) else {
        preconditionFailure("themes/ has no theme with the id \(themeID)")
    }
    return theme
}

let clickyBlueTheme = bundledTheme("clicky-blue")

/// A roster theme's players in order. Empty for a theme without a roster.
func rosterPlayers(of theme: ClickyTheme) -> [ThemeRosterPlayer] {
    if case .roster(let players) = theme.agents.faces { return players }
    return []
}

/// A store whose folder does not exist, so a test never reads the themes the developer saved on this Mac. Each use gets its own
/// folder, since a test that saves a theme (the studio's save, a rename) would otherwise leave it for every later test and
/// every later run, and Shuffle picks among them, so one run found 209 saved themes and the shuffle test failed whenever its
/// 30 random picks all had triangle faces.
var themeStoreWithNoSavedThemes: CustomThemeStore {
    CustomThemeStore(themesDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("clicky-tests-no-saved-themes-\(UUID().uuidString)", isDirectory: true))
}

/// Theme settings backed by their own UserDefaults suite, so a test never reads or changes the app's saved theme.
@MainActor
func makeThemeSettings(startingWith theme: ClickyTheme = clickyBlueTheme, customThemeStore: CustomThemeStore = themeStoreWithNoSavedThemes) -> CompanionThemeSettings {
    // One suite for every test in this process. Sharing it is safe because each test sets the theme and Shuffle right
    // after this reads them and never reads the saved values back. The name has the process ID, so another test run on
    // this Mac that runs at the same time has its own suite. The name is a plain string UserDefaults accepts, so the
    // optional is never nil.
    let testDefaults = UserDefaults(suiteName: testDefaultsSuiteName("BundledThemeTests"))!
    let themeSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: customThemeStore, bundledThemes: bundledThemesForTests)
    themeSettings.theme = theme
    themeSettings.shufflesAgentThemes = false
    return themeSettings
}

@MainActor
func makeBackgroundAgentStore(theme: ClickyTheme = clickyBlueTheme) -> BackgroundAgentStore {
    BackgroundAgentStore(themeSettings: makeThemeSettings(startingWith: theme))
}

/// The name of a UserDefaults suite for a test that reads its saved values back, after the test host's bundle ID and this
/// process's ID. Every test run on this Mac runs as the same macOS user, and two runs at the same time, such as two
/// `swift-check` runs of different worktrees or two CI runners, share one preferences file per suite name, so each would
/// clear or overwrite the other's values. The bundle ID keeps two CI runners apart, and the process ID keeps every other
/// pair of runs apart. The name stays the same for every test of one process, so a test can open its suite again. No later
/// process uses the name, so the process deletes the suite's preferences file when it exits (`TestSuiteNames`), since macOS
/// keeps a file for every suite name, and every run would otherwise leave more of them in ~/Library/Preferences.
func testDefaultsSuiteName(_ testName: String) -> String {
    let suiteName = "\(Bundle.main.bundleIdentifier ?? "clicky-tests")-\(testName)-\(ProcessInfo.processInfo.processIdentifier)"
    TestSuiteNames.shared.record(suiteName)
    return suiteName
}

/// The suite names this process made, and the removal of their preferences files when the process exits.
final class TestSuiteNames: @unchecked Sendable {
    static let shared = TestSuiteNames()

    private let lock = NSLock()
    private var suiteNames: Set<String> = []
    private var removalAtExitIsRegistered = false

    func record(_ suiteName: String) {
        lock.lock()
        defer { lock.unlock() }
        suiteNames.insert(suiteName)
        guard !removalAtExitIsRegistered else { return }
        removalAtExitIsRegistered = true
        // A C function pointer cannot capture, so the handler reads the shared instance.
        atexit { TestSuiteNames.shared.removeEverySuite() }
    }

    /// Empties each suite and deletes its preferences file. Best effort: a file that is not there, or a host that keeps its
    /// preferences somewhere else, leaves nothing worse than the files that were left before.
    func removeEverySuite() {
        lock.lock()
        let suiteNamesToRemove = suiteNames
        lock.unlock()
        let preferencesFolderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
        for suiteName in suiteNamesToRemove {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: preferencesFolderURL.appendingPathComponent("\(suiteName).plist"))
        }
    }
}

/// A UserDefaults suite of its own, named by `testDefaultsSuiteName`, emptied before and after `body`.
@MainActor
func withEmptyDefaults(suiteName: String, _ body: @MainActor (UserDefaults) throws -> Void) throws {
    let runnerSuiteName = testDefaultsSuiteName(suiteName)
    let testDefaults = try #require(UserDefaults(suiteName: runnerSuiteName))
    testDefaults.removePersistentDomain(forName: runnerSuiteName)
    defer { testDefaults.removePersistentDomain(forName: runnerSuiteName) }
    try body(testDefaults)
}

@MainActor
struct BundledThemeTests {
    // MARK: - The test suites

    @Test func aTestDefaultsSuiteNameHasThisProcessesIDSoTwoRunsAtOnceKeepApart() {
        let suiteName = testDefaultsSuiteName("Example")
        #expect(suiteName == "\(Bundle.main.bundleIdentifier ?? "clicky-tests")-Example-\(ProcessInfo.processInfo.processIdentifier)")
        #expect(testDefaultsSuiteName("Example") == suiteName, "a test can open its suite again in the same process")
        #expect(testDefaultsSuiteName("Other") != suiteName)
    }

    @Test func theThemeSettingsATestMakesLiveInThePerProcessSuite() throws {
        // No await sits between the two lines, so no other test on the main actor changes the suite in between.
        _ = makeThemeSettings(startingWith: bundledTheme("school-karasuno"))
        let processSuite = try #require(UserDefaults(suiteName: testDefaultsSuiteName("BundledThemeTests")))
        #expect(processSuite.string(forKey: CompanionThemeSettings.userDefaultsKey) == "bundled:school-karasuno")
    }

    // MARK: - The files

    @Test func everyBundledFileParsesWithClickyBlueFirstAndTheTenSchoolsInTheirOrder() async throws {
        let packageCount = try FileManager.default.contentsOfDirectory(atPath: repositoryRootURL.appendingPathComponent("themes").path)
            .filter { $0.hasSuffix(".clickytheme") }.count
        #expect(bundledThemesForTests.count == packageCount)
        #expect(bundledThemesForTests.map(\.id) == [
            "clicky-blue", "school-karasuno", "school-nekoma", "school-aoba-johsai", "school-fukurodani", "school-date-tech",
            "school-shiratorizawa", "school-johzenji", "school-inarizaki", "school-kamomedai", "school-itachiyama",
        ])
        #expect(Set(bundledThemesForTests.map(\.name)).count == bundledThemesForTests.count)
        for theme in bundledThemesForTests {
            guard case .bundled = theme.origin else {
                Issue.record("\(theme.id) does not read as bundled")
                continue
            }
        }
    }

    @Test func everySavedThemeOnThisMacStillParses() async throws {
        // The acceptance test for the version 2 parser: every folder the learner's Themes folder holds with a theme.json,
        // version 1 files from before theme files included, still loads. A Mac with no saved themes passes at once.
        let savedThemesStore = CustomThemeStore.standard()
        // A folder whose name is not a theme id, such as one made by hand, is skipped by design, so it is left out here too.
        let folderNamesWithAThemeFile = ((try? FileManager.default.contentsOfDirectory(atPath: savedThemesStore.themesDirectoryURL.path)) ?? [])
            .filter(CustomThemeStore.isAValidThemeID)
            .filter { folderName in
                FileManager.default.fileExists(atPath: savedThemesStore.folderURL(forThemeID: folderName).appendingPathComponent(CustomThemeStore.themeFileName).path)
            }
        #expect(Set(savedThemesStore.loadSavedThemes().map(\.theme.id)) == Set(folderNamesWithAThemeFile))
    }

    @Test func clickyBlueIsTheTriangleWithEachKindsOwnColorAndTheSoundsClickyAlwaysPlayed() async throws {
        #expect(clickyBlueTheme.cursor == .triangle)
        #expect(clickyBlueTheme.cursorColorHex == "#3380FF")
        #expect(clickyBlueTheme.agents == ThemeAgents(ring: .perKind, faces: .triangle))
        #expect(clickyBlueTheme.sounds == .builtIn)
        #expect(clickyBlueTheme.cursorFacing == .pointerAngle)
    }

    @Test func eachSchoolsVolleyballIsShapesInItsColorsAndFacesItsMovement() async throws {
        /// The ball's fill, its seams' color, and its outline's color, from the shapes the files draw in that order.
        func volleyballColors(of themeID: String) -> [String?] {
            guard case .shapes(let shapes) = bundledTheme(themeID).cursor, shapes.count == 4 else { return [] }
            return [shapes[1].fillHex, shapes[2].strokeHex, shapes[3].strokeHex]
        }
        #expect(volleyballColors(of: "school-karasuno") == ["#F26B1D", "#1A1A1A", "#1A1A1A"])
        // A red ball keeps a black outline, so white seams never leave it edgeless on a light page.
        #expect(volleyballColors(of: "school-nekoma") == ["#E0313B", "#FFFFFF", "#1A1A1A"])
        #expect(volleyballColors(of: "school-aoba-johsai") == ["#5CC8B8", "#FFFFFF", "#1A1A1A"])
        // Inarizaki's white ball would vanish on a light page, so its ball is black with white lines.
        #expect(volleyballColors(of: "school-inarizaki") == ["#1A1A1A", "#FFFFFF", "#FFFFFF"])
        for school in bundledThemesForTests.dropFirst() {
            #expect(school.cursorFacing == .followsMouseMovement)
            #expect(school.motion.trailStreaks == 3)
            #expect(school.agents.ring == .accent)
            #expect(!rosterPlayers(of: school).isEmpty)
            #expect(school.sounds == .builtIn)
        }
        #expect(bundledTheme("school-nekoma").cursorColorHex == "#E0313B")
        #expect(bundledTheme("school-karasuno").cursorContrastColorHex == "#1A1A1A")
    }

    @Test func aRosterNamesItsPortraitFilesAndFallsBackToInitials() async throws {
        let hinata = try #require(rosterPlayers(of: bundledTheme("school-karasuno")).first)
        #expect(hinata.name == "Hinata")
        #expect(hinata.number == 10)
        #expect(hinata.portraitFileName == "haikyu-shoyo-hinata.jpg")
        #expect(hinata.initials == "SH")
        let everyPortraitFileName = bundledThemesForTests.flatMap(rosterPlayers(of:)).compactMap(\.portraitFileName)
        #expect(Set(everyPortraitFileName).count == everyPortraitFileName.count)
        // A bundled roster's portraits are looked up in the app's Resources, where Xcode copies HaikyuPortraits.
        let hinataFace = AgentRosterFace(player: hinata, of: bundledTheme("school-karasuno"))
        #expect(hinataFace.portraitURL?.lastPathComponent == "haikyu-shoyo-hinata.jpg")
        #expect(hinataFace.accentHex == "#F26B1D")
    }

    // MARK: - Picking a player

    @Test func aRosterHandsOutItsPlayersInOrderAndSkipsPlayersAlreadyWorking() async throws {
        let roster = rosterPlayers(of: bundledTheme("school-karasuno"))
        func nextPlayer(running: [ThemeRosterPlayer], ended: [ThemeRosterPlayer] = []) -> ThemeRosterPlayer? {
            rosterPlayerForANewAgent(roster: roster, playersOfRunningAgents: running, playersOfEndedAgentsStillListed: ended)
        }
        #expect(nextPlayer(running: []) == roster[0])
        #expect(nextPlayer(running: [roster[0]]) == roster[1])
        // The second player is free, so the next agent fills that gap before taking the third.
        #expect(nextPlayer(running: [roster[0], roster[2]]) == roster[1])
        // A player whose agent ended is not reused while the list still shows them and others are free.
        #expect(nextPlayer(running: [roster[0]], ended: [roster[1]]) == roster[2])
        // Once every player is listed, an ended agent's player comes back before a working one is doubled up.
        #expect(nextPlayer(running: Array(roster.dropLast()), ended: [roster[roster.count - 1]]) == roster[roster.count - 1])
    }

    @Test func aRosterReusesPlayersOnceEveryoneIsWorking() async throws {
        let roster = rosterPlayers(of: bundledTheme("school-kamomedai"))
        #expect(roster.count == 2)
        #expect(rosterPlayerForANewAgent(roster: roster, playersOfRunningAgents: roster, playersOfEndedAgentsStillListed: []) == roster[0])
        #expect(rosterPlayerForANewAgent(roster: roster, playersOfRunningAgents: roster + [roster[0]], playersOfEndedAgentsStillListed: []) == roster[1])
    }

    // MARK: - The saved setting

    @Test func everySettingAnOlderVersionSavedMovesToTheThemeItNamed() async throws {
        let schoolNamesOlderVersionsSaved = [
            "karasuno", "nekoma", "aobaJohsai", "fukurodani", "dateTech",
            "shiratorizawa", "johzenji", "inarizaki", "kamomedai", "itachiyama",
        ]
        for schoolName in schoolNamesOlderVersionsSaved {
            let migration = ThemeSettingValue.migrated(fromSavedValue: "school:" + schoolName)
            #expect(!migration.turnsShuffleOn)
            let theme = ThemeSettingValue.theme(named: migration.settingValue, bundledThemes: bundledThemesForTests, savedThemes: [])
            #expect(theme != nil, "school:\(schoolName) moved to \(migration.settingValue), which no bundled theme has")
        }
        #expect(ThemeSettingValue.migrated(fromSavedValue: "school:aobaJohsai").settingValue == "bundled:school-aoba-johsai")
        #expect(ThemeSettingValue.migrated(fromSavedValue: "clickyBlue") == ("bundled:clicky-blue", false))
        #expect(ThemeSettingValue.migrated(fromSavedValue: "random") == ("bundled:clicky-blue", true))
        #expect(ThemeSettingValue.migrated(fromSavedValue: "custom:moonlit-3f9a") == ("custom:moonlit-3f9a", false))
        #expect(ThemeSettingValue.migrated(fromSavedValue: "bundled:school-nekoma") == ("bundled:school-nekoma", false))
    }

    @Test func aLaunchReadsAnOlderSettingWithoutRewritingItAndRandomIsClickyBlueWithShuffleOn() async throws {
        try withEmptyDefaults(suiteName: "BundledThemeTests-Migration") { testDefaults in
            @MainActor func launch() -> CompanionThemeSettings {
                CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: themeStoreWithNoSavedThemes, bundledThemes: bundledThemesForTests)
            }
            testDefaults.set("school:inarizaki", forKey: CompanionThemeSettings.userDefaultsKey)
            #expect(launch().theme == bundledTheme("school-inarizaki"))
            // An older Clicky that shares these defaults still reads its own setting.
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "school:inarizaki")

            testDefaults.set("random", forKey: CompanionThemeSettings.userDefaultsKey)
            let randomSettings = launch()
            #expect(randomSettings.theme == clickyBlueTheme)
            #expect(randomSettings.shufflesAgentThemes)
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "random")

            // Picking a theme with Shuffle on from an old `random` keeps Shuffle on after a relaunch.
            randomSettings.theme = bundledTheme("school-nekoma")
            #expect(launch().shufflesAgentThemes)
            #expect(launch().theme == bundledTheme("school-nekoma"))

            // Turning Shuffle off writes today's form of the theme too, so the old `random` cannot turn it back on.
            randomSettings.shufflesAgentThemes = false
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "bundled:school-nekoma")
            #expect(!launch().shufflesAgentThemes)

            // Picking a theme writes today's form.
            testDefaults.set("school:nekoma", forKey: CompanionThemeSettings.userDefaultsKey)
            launch().theme = bundledTheme("school-karasuno")
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "bundled:school-karasuno")
        }
    }

    @Test func anUnknownSavedThemeReadsAsClickyBlue() async throws {
        for unknownValue in ["", "school:hogwarts", "karasuno", "bundled:school-hogwarts", "custom:gone-0000"] {
            try withEmptyDefaults(suiteName: "BundledThemeTests-Unknown") { testDefaults in
                testDefaults.set(unknownValue, forKey: CompanionThemeSettings.userDefaultsKey)
                let themeSettings = CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: themeStoreWithNoSavedThemes, bundledThemes: bundledThemesForTests)
                #expect(themeSettings.theme == clickyBlueTheme, "\(unknownValue) did not read as Clicky blue")
            }
        }
    }

    @Test func theThemeIsSavedWhenItChangesAndReadBackOnTheNextLaunch() async throws {
        try withEmptyDefaults(suiteName: "BundledThemeTests-SavedTheme") { testDefaults in
            @MainActor func launch() -> CompanionThemeSettings {
                CompanionThemeSettings(userDefaults: testDefaults, customThemeStore: themeStoreWithNoSavedThemes, bundledThemes: bundledThemesForTests)
            }
            #expect(launch().theme == clickyBlueTheme)
            launch().theme = bundledTheme("school-nekoma")
            #expect(launch().theme == bundledTheme("school-nekoma"))
            #expect(testDefaults.string(forKey: CompanionThemeSettings.userDefaultsKey) == "bundled:school-nekoma")
            launch().shufflesAgentThemes = true
            #expect(launch().shufflesAgentThemes)
        }
    }

    // MARK: - The follow motion

    @Test func theFollowingCursorFacesTheMouseMovementShowsStreaksAtSpeedAndFadesWhenItStops() async throws {
        var followMotion = CursorFollowMotion.atRest

        // A slow drift shows no streaks and keeps the resting angle.
        for _ in 0..<10 { followMotion = followMotion.advanced(byMouseMovement: CGVector(dx: 1, dy: 0)) }
        #expect(followMotion.streakStrength == 0)
        #expect(followMotion.facingDegrees == -35)

        // A fast move right turns the ball to face right (90 degrees) with full streaks.
        for _ in 0..<20 { followMotion = followMotion.advanced(byMouseMovement: CGVector(dx: 30, dy: 0)) }
        #expect(abs(followMotion.facingDegrees - 90) < 0.5)
        #expect(followMotion.streakStrength == 1)

        // Moving left with jitter across the +180 and -180 wrap turns at most half a turn per tick, never a full spin.
        var previousFacingDegrees = followMotion.facingDegrees
        for tick in 0..<30 {
            let jitter: CGFloat = tick.isMultiple(of: 2) ? 1 : -1
            followMotion = followMotion.advanced(byMouseMovement: CGVector(dx: -30, dy: jitter))
            #expect(abs(followMotion.facingDegrees - previousFacingDegrees) <= 180)
            previousFacingDegrees = followMotion.facingDegrees
        }
        let facingDegreesWithinOneTurn = (followMotion.facingDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        #expect(abs(facingDegreesWithinOneTurn - 270) < 2)

        // Once the mouse stops, the streaks fade within half a second and the motion settles on one value.
        for _ in 0..<30 { followMotion = followMotion.advanced(byMouseMovement: .zero) }
        #expect(followMotion.streakStrength == 0)
        #expect(followMotion.smoothedMovementPerTick == .zero)
        #expect(followMotion.advanced(byMouseMovement: .zero) == followMotion)
    }

    // MARK: - The store

    @Test func theStoreGivesEachNewAgentThePlayerNextInTheRosterInTheTeamsColor() async throws {
        let nekoma = bundledTheme("school-nekoma")
        let store = makeBackgroundAgentStore(theme: nekoma)
        let roster = rosterPlayers(of: nekoma)
        store.start(kind: .studyGuide)
        store.start(kind: .task)
        store.start(kind: .experiment)
        #expect(store.agents.reversed().map(\.rosterFace?.player) == [roster[0], roster[1], roster[2]])
        let nekomaRed = try #require(ThemeRGBColor(hex: "#E0313B"))
        #expect(store.agents.allSatisfy { $0.tokenColor == .custom(nekomaRed) })
        #expect(store.agents.first?.displayName == roster[2].name)
    }

    @Test func theNextAgentSkipsAPlayerWhoseFinishedAgentTheListStillShows() async throws {
        let nekoma = bundledTheme("school-nekoma")
        let store = makeBackgroundAgentStore(theme: nekoma)
        let roster = rosterPlayers(of: nekoma)
        let firstAgentID = store.start(kind: .studyGuide)
        store.start(kind: .task)
        store.finish(firstAgentID, with: .readyScene)
        store.start(kind: .experiment)
        #expect(store.agents.first?.rosterFace?.player == roster[2])
    }

    @Test func clickyBlueAgentsAreTrianglesInTheirKindsColor() async throws {
        let store = makeBackgroundAgentStore()
        store.start(kind: .studyGuide)
        #expect(store.agents.first?.face == .triangle)
        #expect(store.agents.first?.tokenColor == .amber)
        #expect(store.agents.first?.displayName == BackgroundAgentKind.studyGuide.displayName)
    }

    @Test func aRunningAgentKeepsItsPlayerWhenTheThemeChangesAndOnlyNewAgentsGetTheNewTeam() async throws {
        let themeSettings = makeThemeSettings(startingWith: bundledTheme("school-karasuno"))
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        let karasunoAgentID = store.start(kind: .studyGuide)
        let karasunoFace = try #require(store.agents.first?.rosterFace)
        #expect(karasunoFace.themeID == "school-karasuno")

        themeSettings.theme = bundledTheme("school-inarizaki")
        let inarizakiAgentID = store.start(kind: .task)
        #expect(store.agents.first { $0.id == karasunoAgentID }?.rosterFace == karasunoFace)
        #expect(store.agents.first { $0.id == inarizakiAgentID }?.rosterFace?.player == rosterPlayers(of: bundledTheme("school-inarizaki"))[0])

        themeSettings.theme = clickyBlueTheme
        let unthemedAgentID = store.start(kind: .experiment)
        #expect(store.agents.first { $0.id == unthemedAgentID }?.face == .triangle)
        #expect(store.face(for: karasunoAgentID) == .rosterFace(karasunoFace))
    }

    @Test func shuffleGivesAgentsTheLooksOfOtherThemesAndKeepsTheCursorOfTheChosenOne() async throws {
        let themeSettings = makeThemeSettings(startingWith: clickyBlueTheme)
        themeSettings.shufflesAgentThemes = true
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        for _ in 0..<30 { store.start(kind: .task) }
        let themesTheAgentsWore = Set(store.agents.map { agent in agent.rosterFace?.themeID ?? "a triangle" })
        // Ten of the eleven bundled themes are rosters, so thirty agents that all wore one look would mean no shuffle.
        #expect(themesTheAgentsWore.count > 1)
        #expect(themeSettings.theme == clickyBlueTheme)
        #expect(themeSettings.shownTheme.cursor == .triangle)
    }

    @Test func anotherThemesPlayerOfTheSameNameDoesNotHoldBackThisRostersPlayer() async throws {
        let karasuno = bundledTheme("school-karasuno")
        let hinata = try #require(rosterPlayers(of: karasuno).first)
        // An agent from a theme that has a player like Hinata, such as a copy of the theme under another id.
        let hinataOfAnotherTheme = AgentRosterFace(player: hinata, of: bundledTheme("school-nekoma"))
        let look = newAgentLook(kind: .task, theme: karasuno, colorsInUse: [], rosterFacesOfRunningAgents: [hinataOfAnotherTheme], rosterFacesOfEndedAgentsStillListed: [])
        #expect(look.face == .rosterFace(AgentRosterFace(player: hinata, of: karasuno)))
    }

    @Test func onlyASavedThemeGivesItsAgentsThePictureFace() async throws {
        let pictureFacesJSON = replacingField(in: goodVersion2ThemeJSON, at: ["agents", "faces"], with: .object(["kind": .string("picture")]))
        let idea = try ClickyTheme.parse(themeJSON: pictureFacesJSON, id: "idea-1", pictureIsAvailable: true)
        let savedTheme = idea.with(id: "moonlit-3f9a", origin: .saved(folderURL: URL(fileURLWithPath: "/tmp/moonlit-3f9a")))
        func face(under theme: ClickyTheme) -> AgentFace {
            newAgentLook(kind: .task, theme: theme, colorsInUse: [], rosterFacesOfRunningAgents: [], rosterFacesOfEndedAgentsStillListed: []).face
        }
        // An idea has no picture.jpg yet, so its agents keep the triangle.
        #expect(face(under: idea) == .triangle)
        #expect(face(under: savedTheme) == .themePicture(themeID: "moonlit-3f9a"))
    }

    @Test func aRosterNeverHandsTheSamePlayerToTwoRunningAgentsWhileItHasOthers() async throws {
        let roster = rosterPlayers(of: bundledTheme("school-aoba-johsai"))
        let store = makeBackgroundAgentStore(theme: bundledTheme("school-aoba-johsai"))
        for _ in roster { store.start(kind: .task) }
        let runningPlayers = store.agents.compactMap(\.rosterFace?.player)
        #expect(Set(runningPlayers) == Set(roster))
    }

    #if DEBUG
    @Test func seededScreenshotAgentsPutTheTeamsBestKnownPlayerFirst() async throws {
        let aobaJohsai = bundledTheme("school-aoba-johsai")
        let store = makeBackgroundAgentStore(theme: aobaJohsai)
        store.seedAgentsForScreenshots()
        let roster = rosterPlayers(of: aobaJohsai)
        let runningPlayers = store.agents.filter(\.isRunning).map(\.rosterFace?.player)
        #expect(runningPlayers == [roster[0], roster[1], roster[2]])
        // Three running agents fill the three token positions, so the finished and failed ones wait in "+N".
        let rankedAgents = agentsWithTokens(from: store.agents, at: Date())
        #expect(rankedAgents.prefix(3).map(\.rosterFace?.player) == [roster[0], roster[1], roster[2]])
        #expect(rankedAgents.count == 5)
        // A second seed gives its running agents new players, never a second Oikawa. Ten listed agents outnumber the
        // 9 players, so only an ended agent may repeat one.
        store.seedAgentsForScreenshots()
        let runningPlayersAfterTwoSeeds = store.agents.filter(\.isRunning).compactMap(\.rosterFace?.player)
        #expect(Set(runningPlayersAfterTwoSeeds).count == runningPlayersAfterTwoSeeds.count)
    }
    #endif

    // MARK: - What views draw

    @Test func theChipsPortraitFillsItsDiscAndEveryOtherIconIsASymbolOnTheDisc() async throws {
        let karasuno = bundledTheme("school-karasuno")
        let hinataFace = AgentRosterFace(player: try #require(rosterPlayers(of: karasuno).first), of: karasuno)
        #expect(VoiceToolCallChipSender.backgroundAgent(color: .teal, face: .rosterFace(hinataFace)).iconContent == .circularPortrait)
        #expect(VoiceToolCallChipSender.backgroundAgent(color: .teal, face: .triangle).iconContent == .symbolOnDisc)
        #expect(VoiceToolCallChipSender.voiceToolCall.iconContent == .symbolOnDisc)
        #expect(VoiceToolCallChipSender.failure.iconContent == .symbolOnDisc)
    }

    @Test func theChipSitsAboveTheCursorAndStaysInsideTheScreen() async throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let chipOriginInTheMiddle = voiceToolCallChipOrigin(mouseLocation: CGPoint(x: 500, y: 500), screenFrame: screenFrame)
        // The tail's tip is above the triangle, which sits 25 below the mouse, so the panel starts below the mouse and its
        // Callout reaches above the triangle.
        #expect(chipOriginInTheMiddle.y + tetherCalloutPanelMargin > 500 - 25)
        #expect(abs(chipOriginInTheMiddle.x + tetherCalloutPanelMargin + tetherSingleLineCalloutTailTipX - (500 + 35)) < 0.001)
        // A 200 point chip whose tail would stand at the cursor but run past the screen's edge slides left, and a chip that
        // fits keeps its tail on the cursor.
        let chipOriginAtTheRightEdge = voiceToolCallChipOrigin(mouseLocation: CGPoint(x: 1700, y: 500), screenFrame: screenFrame, calloutWidth: 200)
        #expect(abs(chipOriginAtTheRightEdge.x + tetherCalloutPanelMargin + 200 - screenFrame.maxX) < 0.001)
        let chipOriginThatFits = voiceToolCallChipOrigin(mouseLocation: CGPoint(x: 1000, y: 500), screenFrame: screenFrame, calloutWidth: 200)
        #expect(abs(chipOriginThatFits.x + tetherCalloutPanelMargin + tetherSingleLineCalloutTailTipX - (1000 + 35)) < 0.001)
        let chipOriginAtTheTop = voiceToolCallChipOrigin(mouseLocation: CGPoint(x: 500, y: 1100), screenFrame: screenFrame)
        #expect(chipOriginAtTheTop.y + VoiceToolCallChip.panelSize.height <= screenFrame.maxY)
        let chipOriginAtTheBottom = voiceToolCallChipOrigin(mouseLocation: CGPoint(x: 500, y: 10), screenFrame: screenFrame)
        #expect(chipOriginAtTheBottom.y >= screenFrame.minY)
    }

    @Test func aChipSitsAboveAStatusLineThatShowsAtTheSameSpot() async throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let mouseLocation = CGPoint(x: 500, y: 500)
        let withNoStatusLine = voiceToolCallChipOrigin(mouseLocation: mouseLocation, screenFrame: screenFrame, aStatusLabelIsShowing: false)
        let withAStatusLine = voiceToolCallChipOrigin(mouseLocation: mouseLocation, screenFrame: screenFrame, aStatusLabelIsShowing: true)
        #expect(withAStatusLine.y - withNoStatusLine.y >= tetherSingleLineCalloutHeight)
        #expect(withAStatusLine.x == withNoStatusLine.x)
    }

    @Test func aTokenSaysItsStateByItsBadgeAndAWaitingApprovalWins() async throws {
        #expect(agentTokenBadge(phase: .running(completedStepCount: 0), isWaitingForApproval: false) == nil)
        #expect(agentTokenBadge(phase: .finished(.readyScene), isWaitingForApproval: false) == .done)
        #expect(agentTokenBadge(phase: .failed(reason: "Broke"), isWaitingForApproval: false) == .failed)
        #expect(agentTokenBadge(phase: .cancelled, isWaitingForApproval: false) == nil)
        #expect(agentTokenBadge(phase: .running(completedStepCount: 0), isWaitingForApproval: true) == .needsYourOK)
    }
}

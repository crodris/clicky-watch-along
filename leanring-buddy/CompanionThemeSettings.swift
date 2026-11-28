//
//  CompanionThemeSettings.swift
//  leanring-buddy
//
//  The theme the learner wears, and every theme they can pick. The built-in themes (Clicky blue and the volleyball
//  schools) are `.clickytheme` packages the app bundles, read by the same parser as the themes the learner saved, so no
//  theme's name, colors, cursor, or roster is written in Swift. This file holds the saved setting and its migration from
//  the names older versions saved, the Shuffle switch, the rule that picks a roster face for a new agent, and the image
//  loading for roster portraits and theme pictures. The views that draw a theme read it from `CompanionThemeSettings`.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Where saved themes live

nonisolated extension CustomThemeStore {
    /// ~/Library/Application Support/Clicky/Themes, next to the learner's skills and mcp.json. It is here and not in
    /// CustomThemeStore.swift because the Quick Look extension compiles that file and has no folder of Clicky's to read.
    static func standard() -> CustomThemeStore {
        CustomThemeStore(themesDirectoryURL: TaskAgentFolders.clickyApplicationSupportURL().appendingPathComponent("Themes", isDirectory: true))
    }
}

// MARK: - What views read from a theme

extension ClickyTheme {
    /// The theme every launch falls back to, and the one an unknown setting reads as.
    nonisolated static let defaultThemeID = "clicky-blue"

    /// The color of the cursor, its glow, the ring, the loop, and the navigation bubble.
    var cursorColor: Color { Color(hex: accentHex) }

    /// For text and icons drawn on a cursor-colored fill: near-black or white, whichever reads better on it.
    var accentInk: Color { Color(hex: accentInkHex) }

    /// The cursor color as a hex string, for the frame pop-out page's quiz label.
    var cursorColorHex: String { accentHex }
}

extension ThemeSound {
    func play() {
        NSSound(named: NSSound.Name(rawValue))?.play()
    }
}

// MARK: - The saved setting

/// How the `companionTheme` setting names a theme: `bundled:<id>` for a bundled theme and `custom:<id>` for a saved one.
nonisolated enum ThemeSettingValue {
    static let bundledPrefix = "bundled:"
    static let savedPrefix = "custom:"

    /// The value a theme is saved under. An idea on the studio card is never saved, and reads like a saved theme here.
    static func of(_ theme: ClickyTheme) -> String {
        if case .bundled = theme.origin { return bundledPrefix + theme.id }
        return savedPrefix + theme.id
    }

    /// The setting written by a version from before theme files, in today's form, and whether it turns Shuffle on.
    /// `clickyBlue` is the bundled Clicky blue, `school:aobaJohsai` the bundled `school-aoba-johsai`, and `random`, which
    /// gave every agent a random team's player, is Clicky blue with Shuffle on. Any other value, `custom:<id>` included,
    /// is already today's form.
    static func migrated(fromSavedValue savedValue: String) -> (settingValue: String, turnsShuffleOn: Bool) {
        if savedValue == "clickyBlue" { return (bundledPrefix + ClickyTheme.defaultThemeID, false) }
        if savedValue == "random" { return (bundledPrefix + ClickyTheme.defaultThemeID, true) }
        if savedValue.hasPrefix("school:") {
            let schoolName = savedValue.dropFirst("school:".count)
            var themeID = "school-"
            for character in schoolName {
                if character.isUppercase { themeID += "-" }
                themeID += character.lowercased()
            }
            return (bundledPrefix + themeID, false)
        }
        return (savedValue, false)
    }

    /// The theme a setting names, or nil when no installed theme has it, such as a theme whose folder was deleted.
    static func theme(named settingValue: String, bundledThemes: [ClickyTheme], savedThemes: [ClickyTheme]) -> ClickyTheme? {
        if settingValue.hasPrefix(bundledPrefix) {
            let themeID = String(settingValue.dropFirst(bundledPrefix.count))
            return bundledThemes.first { $0.id == themeID }
        }
        if settingValue.hasPrefix(savedPrefix) {
            let themeID = String(settingValue.dropFirst(savedPrefix.count))
            return savedThemes.first { $0.id == themeID }
        }
        return nil
    }
}

// MARK: - The bundled themes

/// The `.clickytheme` packages in the app bundle's Themes folder, which the "Copy Bundled Themes" build phase copies from
/// themes/ in the repository.
nonisolated enum BundledThemes {
    /// The app bundle's Themes folder. A test run outside Clicky.app, such as tools/swift-check.sh, has no app bundle, so a
    /// Debug build falls back to themes/ next to this source file.
    static func directoryURL(sourceFilePath: String = #filePath) -> URL? {
        if let bundledDirectoryURL = Bundle.main.resourceURL?.appendingPathComponent("Themes", isDirectory: true),
           FileManager.default.fileExists(atPath: bundledDirectoryURL.path) {
            return bundledDirectoryURL
        }
        #if DEBUG
        let repositoryThemesURL = URL(fileURLWithPath: sourceFilePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("themes", isDirectory: true)
        if FileManager.default.fileExists(atPath: repositoryThemesURL.path) { return repositoryThemesURL }
        #endif
        return nil
    }

    /// Every bundled theme, Clicky blue first, read once. Xcode copies the gitignored roster portraits to the top of the
    /// app's Resources, so a bundled roster's portrait file names are looked up there.
    static let loadedFromTheApp: [ClickyTheme] = {
        guard let directoryURL = directoryURL() else {
            print("Themes: the app has no bundled Themes folder")
            return []
        }
        let imagesFolderURL = Bundle.main.resourceURL ?? directoryURL
        return CustomThemeStore.loadBundledThemes(inDirectoryAt: directoryURL, imagesFolderURL: imagesFolderURL)
    }()
}

// MARK: - Settings

/// The one source of truth for the theme. CompanionManager owns it and passes it to the views and the agent store.
///
/// `theme` is the saved theme, the only one written to UserDefaults. While the Theme Studio is open, `previewTheme` is the
/// idea the learner is trying, and `shownTheme` is what every view that draws the theme reads: the preview, else the
/// saved theme. A view that read `theme` would not show the preview, and one that read `previewTheme` would show nothing
/// when no studio is open.
@MainActor
final class CompanionThemeSettings: ObservableObject {
    static let userDefaultsKey = "companionTheme"
    static let shuffleUserDefaultsKey = "shufflesAgentThemes"

    @Published var theme: ClickyTheme {
        didSet {
            userDefaults.set(ThemeSettingValue.of(theme), forKey: Self.userDefaultsKey)
            // An old `random` read as Shuffle on without writing the switch, so the switch is written with the theme, or
            // the Shuffle that `random` turned on would be gone once the old value is replaced.
            userDefaults.set(shufflesAgentThemes, forKey: Self.shuffleUserDefaultsKey)
        }
    }

    /// Whether each new agent takes the look of a theme picked at random from every installed theme, instead of the
    /// chosen theme's. The cursor stays the chosen theme's.
    @Published var shufflesAgentThemes: Bool {
        didSet {
            userDefaults.set(shufflesAgentThemes, forKey: Self.shuffleUserDefaultsKey)
            // A setting of `random` from before theme files reads as Shuffle on, so it is replaced with today's form, or
            // turning Shuffle off would not last past a relaunch.
            userDefaults.set(ThemeSettingValue.of(theme), forKey: Self.userDefaultsKey)
        }
    }

    /// The themes the app bundles, Clicky blue first, in the order the menu bar panel and the dial's Theme fan show them.
    let bundledThemes: [ClickyTheme]

    /// The custom themes the learner saved with their saved dates, sorted by name. The menu bar panel's All themes page lists
    /// them in this order, and its home and the settings dial's Theme fan sort the same list by date.
    @Published private(set) var savedCustomThemesWithSavedDates: [SavedCustomTheme]

    var savedCustomThemes: [ClickyTheme] { savedCustomThemesWithSavedDates.map(\.theme) }

    /// The idea the Theme Studio is previewing on the real cursor. Nil when the studio is closed. Never saved.
    @Published private(set) var previewTheme: ClickyTheme?
    /// The picture the previewed idea uses, since an idea that is not saved yet has no picture.jpg to load.
    @Published private(set) var previewPicture: NSImage?

    private let userDefaults: UserDefaults
    private let customThemeStore: CustomThemeStore

    /// A saved setting from before theme files reads as the theme it named (`ThemeSettingValue.migrated`), and is left as it
    /// is until the learner picks a theme or flips Shuffle. A launch writes nothing, since an older Clicky that shares these
    /// defaults, such as the everyday build next to a Debug one, would read today's form as an unknown theme.
    init(
        userDefaults: UserDefaults = .standard,
        customThemeStore: CustomThemeStore = .standard(),
        bundledThemes: [ClickyTheme] = BundledThemes.loadedFromTheApp
    ) {
        guard let defaultTheme = bundledThemes.first(where: { $0.id == ClickyTheme.defaultThemeID }) else {
            fatalError("The app bundles no \(ClickyTheme.defaultThemeID) theme, so the Copy Bundled Themes build phase did not run")
        }
        self.userDefaults = userDefaults
        self.customThemeStore = customThemeStore
        self.bundledThemes = bundledThemes
        let savedCustomThemesWithSavedDates = customThemeStore.loadSavedThemes()
        self.savedCustomThemesWithSavedDates = savedCustomThemesWithSavedDates

        let storedValue = userDefaults.string(forKey: Self.userDefaultsKey)
        let migration = ThemeSettingValue.migrated(fromSavedValue: storedValue ?? "")
        theme = ThemeSettingValue.theme(
            named: migration.settingValue,
            bundledThemes: bundledThemes,
            savedThemes: savedCustomThemesWithSavedDates.map(\.theme)
        ) ?? defaultTheme
        shufflesAgentThemes = userDefaults.bool(forKey: Self.shuffleUserDefaultsKey) || migration.turnsShuffleOn
        if let storedValue, storedValue != migration.settingValue {
            print("Themes: read the saved theme \(storedValue) as \(migration.settingValue)\(migration.turnsShuffleOn ? " with Shuffle on" : "")")
        }
    }

    var defaultTheme: ClickyTheme {
        // The initializer refuses a list without it.
        bundledThemes.first { $0.id == ClickyTheme.defaultThemeID } ?? bundledThemes[0]
    }

    /// What every view that draws the theme reads: the preview while the studio is open, else the saved theme.
    var shownTheme: ClickyTheme { previewTheme ?? theme }

    /// The picture the shown theme uses, for its cursor and its agent tokens. Nil when it uses none.
    var shownThemePicture: NSImage? {
        if previewTheme != nil { return previewPicture }
        guard theme.usesPicture else { return nil }
        return CustomThemePictureCache.image(forThemeID: theme.id, in: customThemeStore)
    }

    /// Every theme Shuffle may give an agent: the bundled ones and the saved ones.
    var themesAgentsMayShuffleThrough: [ClickyTheme] { bundledThemes + savedCustomThemes }

    /// Calls `apply` with the shown theme's Pop, Glide, and Point springs now, and again whenever the saved theme or the studio's
    /// preview changes them. `$theme` and `$previewTheme` publish the new value before the stored one changes, so the closure
    /// reads what the publishers send and never `shownTheme`. The caller keeps the returned subscription alive.
    func observeShownMoveSprings(_ apply: @escaping (ThemeMoveSprings) -> Void) -> AnyCancellable {
        $theme.combineLatest($previewTheme)
            .map { savedTheme, previewTheme in (previewTheme ?? savedTheme).moveSprings }
            .removeDuplicates()
            .sink(receiveValue: apply)
    }

    func preview(_ idea: ClickyTheme, picture: NSImage?) {
        previewTheme = idea
        previewPicture = picture
    }

    func clearPreview() {
        previewTheme = nil
        previewPicture = nil
    }

    /// Saves the idea to disk, makes it the theme, and ends the preview. Nothing changes when the save fails.
    @discardableResult
    func saveAndApply(_ idea: ClickyTheme, pictureJPEG: Data?) throws -> ClickyTheme {
        let savedTheme = try customThemeStore.save(idea, pictureJPEG: pictureJPEG)
        savedCustomThemesWithSavedDates = customThemeStore.loadSavedThemes()
        clearPreview()
        theme = savedTheme
        return savedTheme
    }

    /// Reads and checks a `.clickytheme` package without installing it, for the "Add theme?" card. Throws what
    /// `installAndApply` would throw for a package it refuses.
    func previewPackage(at packageURL: URL) throws -> CustomThemeStore.ThemePackagePreview {
        try customThemeStore.previewPackage(at: packageURL)
    }

    /// Installs a `.clickytheme` package the learner opened, such as by a double-click in Finder, and makes it the theme.
    /// Throws what `CustomThemeStore.install` throws, such as a theme.json that does not parse, and changes nothing then.
    @discardableResult
    func installAndApply(packageAt packageURL: URL, expectedPreview: CustomThemeStore.ThemePackagePreview? = nil) throws -> ClickyTheme {
        let installedTheme = try customThemeStore.install(packageAt: packageURL, expectedPreview: expectedPreview)
        savedCustomThemesWithSavedDates = customThemeStore.loadSavedThemes()
        theme = installedTheme
        return installedTheme
    }

    /// Gives a saved theme a new name, and puts the list back in name order. The theme in use stays in use, now under its
    /// new name. Throws what `CustomThemeStore.rename` throws, such as a name over 24 characters, and changes nothing then.
    func renameSavedTheme(themeID: String, to typedName: String) throws {
        let renamedTheme = try customThemeStore.rename(themeID: themeID, to: typedName)
        savedCustomThemesWithSavedDates = customThemeStore.loadSavedThemes()
        if case .saved = theme.origin, theme.id == themeID {
            // The saved setting is the id, which did not change, so only the name this holds needs replacing.
            theme = renamedTheme
        }
    }

    /// Deletes a saved theme from disk and from the list. If it was the theme in use, Clicky blue takes over. An agent that
    /// is running keeps the color it was given when it started, as agents keep theirs for life, and a picture face it wore
    /// falls back to the triangle, since the picture went with the folder.
    func deleteSavedTheme(themeID: String) throws {
        try customThemeStore.delete(themeID: themeID)
        savedCustomThemesWithSavedDates = customThemeStore.loadSavedThemes()
        CustomThemePictureCache.forgetImage(forThemeID: themeID)
        if case .saved = theme.origin, theme.id == themeID {
            theme = defaultTheme
        }
    }
}

// MARK: - Roster faces

/// A roster face an agent wears for its whole life, with what it needs to draw itself after the theme changes: the
/// theme's accent for the initials' circle and the portrait file's location.
struct AgentRosterFace: Equatable, Hashable {
    /// The theme the face came from, since two themes may each have a player of one name.
    let themeID: String
    let player: ThemeRosterPlayer
    let accentHex: String
    /// Nil when the player has no portrait, or the theme is an idea with no folder.
    let portraitURL: URL?

    init(player: ThemeRosterPlayer, of theme: ClickyTheme) {
        themeID = theme.id
        self.player = player
        accentHex = theme.accentHex
        let imagesFolderURL: URL?
        switch theme.origin {
        case .bundled(let bundledImagesFolderURL): imagesFolderURL = bundledImagesFolderURL
        case .saved(let folderURL): imagesFolderURL = folderURL
        case .idea: imagesFolderURL = nil
        }
        portraitURL = player.portraitFileName.flatMap { portraitFileName in
            imagesFolderURL?.appendingPathComponent(portraitFileName)
        }
    }
}

/// The player a new agent becomes under a roster. The roster hands out its players in order, skipping players the agent
/// list still shows, so one list never shows the same player twice while the roster has others. Once every player is
/// listed it reuses one whose agent has ended, and only past that one already working.
func rosterPlayerForANewAgent(
    roster: [ThemeRosterPlayer],
    playersOfRunningAgents: [ThemeRosterPlayer],
    playersOfEndedAgentsStillListed: [ThemeRosterPlayer]
) -> ThemeRosterPlayer? {
    guard !roster.isEmpty else { return nil }
    let playersStillListed = playersOfRunningAgents + playersOfEndedAgentsStillListed
    if let unlistedPlayer = roster.first(where: { !playersStillListed.contains($0) }) {
        return unlistedPlayer
    }
    if let playerNotWorking = roster.first(where: { !playersOfRunningAgents.contains($0) }) {
        return playerNotWorking
    }
    return roster[playersOfRunningAgents.count % roster.count]
}

/// Loads a roster face's portrait file once, or nil when there is none. The bundled rosters' portraits are gitignored, so
/// CI and a fresh clone have none, and the views draw the initials circle instead.
@MainActor
enum RosterPortraitCache {
    private static var portraitsByURL: [URL: NSImage?] = [:]

    static func image(for rosterFace: AgentRosterFace) -> NSImage? {
        guard let portraitURL = rosterFace.portraitURL else { return nil }
        if let cachedPortrait = portraitsByURL[portraitURL] {
            return cachedPortrait
        }
        let portrait = NSImage(contentsOf: portraitURL)
        portraitsByURL[portraitURL] = .some(portrait)
        return portrait
    }
}

/// Loads the picture a saved custom theme keeps (picture.jpg), once. Nil when the theme has none or the file is unreadable.
/// A saved theme's picture never changes, so an id's picture is cached for the life of the app, until the theme is deleted
/// (`forgetImage(forThemeID:)`).
@MainActor
enum CustomThemePictureCache {
    private static var imagesByThemeID: [String: NSImage?] = [:]

    static func image(forThemeID themeID: String, in store: CustomThemeStore = .standard()) -> NSImage? {
        if let cachedImage = imagesByThemeID[themeID] {
            return cachedImage
        }
        let image = NSImage(contentsOf: store.pictureURL(forThemeID: themeID))
        imagesByThemeID[themeID] = .some(image)
        return image
    }

    /// A deleted theme's picture, and a "no picture" answer cached for its id, are not looked up again from memory.
    static func forgetImage(forThemeID themeID: String) {
        imagesByThemeID.removeValue(forKey: themeID)
    }
}

/// A roster face's round portrait, or the theme's accent filled with the player's initials when the file is not there.
struct RosterFaceView: View {
    let rosterFace: AgentRosterFace
    let size: CGFloat
    /// Failed agents show a grayscale face, so the state reads at a glance along with the cross badge.
    var isGrayscale = false

    var body: some View {
        Group {
            if let portrait = RosterPortraitCache.image(for: rosterFace) {
                Image(nsImage: portrait)
                    .resizable()
                    .scaledToFill()
                    .grayscale(isGrayscale ? 1 : 0)
            } else {
                ZStack {
                    Circle().fill(Color(hex: rosterFace.accentHex))
                    Text(rosterFace.player.initials)
                        .font(DS.glyphFont(pointSize: size * 0.38, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: ThemeRGBColor.inkHex(onFillHex: rosterFace.accentHex)))
                }
                .grayscale(isGrayscale ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

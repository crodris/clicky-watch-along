//
//  HaikyuTheme.swift
//  leanring-buddy
//
//  An optional Haikyu!! team theme. Picking a school in the menu bar panel recolors Clicky's cursor, and every
//  background agent that starts becomes one of that team's players, shown as a round portrait in the wingman
//  formation and in the agent list. This file holds the data (schools, rosters, the theme and its saved setting),
//  the rule that picks the next player, and the portrait loading. The views that draw a theme read it from here.
//  Portraits are fetched by tools/fetch-haikyu-portraits.py, which reads every `wikiTitle` in this file, so this
//  table is the single source of truth for who exists.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Players

struct HaikyuPlayer: Equatable, Hashable {
    let displayName: String
    let jerseyNumber: Int
    /// The player's page title on the Haikyu!! wiki, which the portrait script looks up.
    let wikiTitle: String
    let school: HaikyuSchool

    /// The bundled portrait's file name without its extension, such as "haikyu-shoyo-hinata" for "Shōyō Hinata".
    /// tools/fetch-haikyu-portraits.py builds the same slug, so change both together.
    var portraitResourceName: String {
        "haikyu-" + Self.asciiSlug(of: wikiTitle)
    }

    /// The first letter of each word of the wiki title, for the circle drawn when no portrait is bundled.
    var initials: String {
        wikiTitle.split(separator: " ").compactMap { $0.first }.map(String.init).joined()
    }

    /// Lowercase ASCII with macrons and other accents removed, and each run of other characters turned into one hyphen.
    static func asciiSlug(of title: String) -> String {
        let withoutAccents = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        for character in withoutAccents {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if slug.last != "-" {
                slug.append("-")
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Schools

enum HaikyuSchool: String, CaseIterable {
    case karasuno
    case nekoma
    case aobaJohsai
    case fukurodani
    case dateTech
    case shiratorizawa
    case johzenji
    case inarizaki
    case kamomedai
    case itachiyama

    var displayName: String {
        switch self {
        case .karasuno: return "Karasuno"
        case .nekoma: return "Nekoma"
        case .aobaJohsai: return "Aoba Johsai"
        case .fukurodani: return "Fukurodani"
        case .dateTech: return "Date Tech"
        case .shiratorizawa: return "Shiratorizawa"
        case .johzenji: return "Johzenji"
        case .inarizaki: return "Inarizaki"
        case .kamomedai: return "Kamomedai"
        case .itachiyama: return "Itachiyama"
        }
    }

    /// The team's color: the cursor, the progress ring, the portrait border, and the list's meter.
    var accentColor: Color {
        Color(hex: accentHex)
    }

    /// Text and outlines drawn on or around the accent color, picked to stay readable on it.
    var contrastColor: Color {
        Color(hex: contrastHex)
    }

    /// Hex strings, so the quiz label's page, which cannot read a SwiftUI Color, gets the same colors.
    var accentHex: String {
        switch self {
        case .karasuno: return "#F26B1D"
        case .nekoma: return "#E0313B"
        case .aobaJohsai: return "#5CC8B8"
        case .fukurodani: return "#D4A017"
        case .dateTech: return "#2EA58F"
        case .shiratorizawa: return "#A0457F"
        case .johzenji: return "#F5C518"
        case .inarizaki: return "#F4F4F5"
        case .kamomedai: return "#6EC1E4"
        case .itachiyama: return "#F2D600"
        }
    }

    var contrastHex: String {
        switch self {
        case .karasuno: return "#1A1A1A"
        case .nekoma: return "#FFFFFF"
        case .aobaJohsai: return "#0F2E2A"
        case .fukurodani: return "#141414"
        case .dateTech: return "#FFFFFF"
        case .shiratorizawa: return "#FFFFFF"
        case .johzenji: return "#1A1A1A"
        case .inarizaki: return "#111111"
        case .kamomedai: return "#1F3A5F"
        case .itachiyama: return "#1E6B30"
        }
    }

    /// The team's players in popularity order, so the first agent is always the most recognizable one.
    var roster: [HaikyuPlayer] {
        switch self {
        case .karasuno:
            return [
                HaikyuPlayer(displayName: "Hinata", jerseyNumber: 10, wikiTitle: "Shōyō Hinata", school: .karasuno),
                HaikyuPlayer(displayName: "Kageyama", jerseyNumber: 9, wikiTitle: "Tobio Kageyama", school: .karasuno),
                HaikyuPlayer(displayName: "Tsukishima", jerseyNumber: 11, wikiTitle: "Kei Tsukishima", school: .karasuno),
                HaikyuPlayer(displayName: "Nishinoya", jerseyNumber: 4, wikiTitle: "Yū Nishinoya", school: .karasuno),
                HaikyuPlayer(displayName: "Sugawara", jerseyNumber: 2, wikiTitle: "Kōshi Sugawara", school: .karasuno),
                HaikyuPlayer(displayName: "Tanaka", jerseyNumber: 5, wikiTitle: "Ryūnosuke Tanaka", school: .karasuno),
                HaikyuPlayer(displayName: "Daichi", jerseyNumber: 1, wikiTitle: "Daichi Sawamura", school: .karasuno),
                HaikyuPlayer(displayName: "Asahi", jerseyNumber: 3, wikiTitle: "Asahi Azumane", school: .karasuno),
                HaikyuPlayer(displayName: "Yamaguchi", jerseyNumber: 12, wikiTitle: "Tadashi Yamaguchi", school: .karasuno),
            ]
        case .nekoma:
            return [
                HaikyuPlayer(displayName: "Kenma", jerseyNumber: 5, wikiTitle: "Kenma Kozume", school: .nekoma),
                HaikyuPlayer(displayName: "Kuroo", jerseyNumber: 1, wikiTitle: "Tetsurō Kuroo", school: .nekoma),
                HaikyuPlayer(displayName: "Lev", jerseyNumber: 11, wikiTitle: "Lev Haiba", school: .nekoma),
                HaikyuPlayer(displayName: "Yaku", jerseyNumber: 3, wikiTitle: "Morisuke Yaku", school: .nekoma),
                HaikyuPlayer(displayName: "Yamamoto", jerseyNumber: 4, wikiTitle: "Taketora Yamamoto", school: .nekoma),
                HaikyuPlayer(displayName: "Kai", jerseyNumber: 2, wikiTitle: "Nobuyuki Kai", school: .nekoma),
                HaikyuPlayer(displayName: "Fukunaga", jerseyNumber: 6, wikiTitle: "Shōhei Fukunaga", school: .nekoma),
            ]
        case .aobaJohsai:
            return [
                HaikyuPlayer(displayName: "Oikawa", jerseyNumber: 1, wikiTitle: "Tōru Oikawa", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Iwaizumi", jerseyNumber: 4, wikiTitle: "Hajime Iwaizumi", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Kunimi", jerseyNumber: 13, wikiTitle: "Akira Kunimi", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Kyotani", jerseyNumber: 16, wikiTitle: "Kentarō Kyōtani", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Hanamaki", jerseyNumber: 3, wikiTitle: "Takahiro Hanamaki", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Matsukawa", jerseyNumber: 2, wikiTitle: "Issei Matsukawa", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Kindaichi", jerseyNumber: 12, wikiTitle: "Yūtarō Kindaichi", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Yahaba", jerseyNumber: 6, wikiTitle: "Shigeru Yahaba", school: .aobaJohsai),
                HaikyuPlayer(displayName: "Watari", jerseyNumber: 7, wikiTitle: "Shinji Watari", school: .aobaJohsai),
            ]
        case .fukurodani:
            return [
                HaikyuPlayer(displayName: "Bokuto", jerseyNumber: 4, wikiTitle: "Kōtarō Bokuto", school: .fukurodani),
                HaikyuPlayer(displayName: "Akaashi", jerseyNumber: 5, wikiTitle: "Keiji Akaashi", school: .fukurodani),
                HaikyuPlayer(displayName: "Konoha", jerseyNumber: 7, wikiTitle: "Akinori Konoha", school: .fukurodani),
                HaikyuPlayer(displayName: "Komi", jerseyNumber: 11, wikiTitle: "Haruki Komi", school: .fukurodani),
                HaikyuPlayer(displayName: "Washio", jerseyNumber: 2, wikiTitle: "Tatsuki Washio", school: .fukurodani),
                HaikyuPlayer(displayName: "Sarukui", jerseyNumber: 3, wikiTitle: "Yamato Sarukui", school: .fukurodani),
                HaikyuPlayer(displayName: "Onaga", jerseyNumber: 12, wikiTitle: "Wataru Onaga", school: .fukurodani),
            ]
        case .dateTech:
            return [
                HaikyuPlayer(displayName: "Futakuchi", jerseyNumber: 2, wikiTitle: "Kenji Futakuchi", school: .dateTech),
                HaikyuPlayer(displayName: "Aone", jerseyNumber: 1, wikiTitle: "Takanobu Aone", school: .dateTech),
                HaikyuPlayer(displayName: "Koganegawa", jerseyNumber: 7, wikiTitle: "Kanji Koganegawa", school: .dateTech),
                HaikyuPlayer(displayName: "Moniwa", jerseyNumber: 2, wikiTitle: "Kaname Moniwa", school: .dateTech),
                HaikyuPlayer(displayName: "Kamasaki", jerseyNumber: 1, wikiTitle: "Yasushi Kamasaki", school: .dateTech),
                HaikyuPlayer(displayName: "Obara", jerseyNumber: 3, wikiTitle: "Yutaka Obara", school: .dateTech),
                HaikyuPlayer(displayName: "Sakunami", jerseyNumber: 13, wikiTitle: "Kōsuke Sakunami", school: .dateTech),
            ]
        case .shiratorizawa:
            return [
                HaikyuPlayer(displayName: "Ushijima", jerseyNumber: 1, wikiTitle: "Wakatoshi Ushijima", school: .shiratorizawa),
                HaikyuPlayer(displayName: "Tendo", jerseyNumber: 5, wikiTitle: "Satori Tendō", school: .shiratorizawa),
                HaikyuPlayer(displayName: "Goshiki", jerseyNumber: 8, wikiTitle: "Tsutomu Goshiki", school: .shiratorizawa),
                HaikyuPlayer(displayName: "Shirabu", jerseyNumber: 10, wikiTitle: "Kenjirō Shirabu", school: .shiratorizawa),
                HaikyuPlayer(displayName: "Semi", jerseyNumber: 3, wikiTitle: "Eita Semi", school: .shiratorizawa),
                HaikyuPlayer(displayName: "Kawanishi", jerseyNumber: 12, wikiTitle: "Taichi Kawanishi", school: .shiratorizawa),
                HaikyuPlayer(displayName: "Ohira", jerseyNumber: 4, wikiTitle: "Reon Ōhira", school: .shiratorizawa),
                HaikyuPlayer(displayName: "Yamagata", jerseyNumber: 14, wikiTitle: "Hayato Yamagata", school: .shiratorizawa),
            ]
        case .johzenji:
            return [
                HaikyuPlayer(displayName: "Terushima", jerseyNumber: 1, wikiTitle: "Yūji Terushima", school: .johzenji),
                HaikyuPlayer(displayName: "Futamata", jerseyNumber: 3, wikiTitle: "Takeharu Futamata", school: .johzenji),
                HaikyuPlayer(displayName: "Bobata", jerseyNumber: 2, wikiTitle: "Kazuma Bobata", school: .johzenji),
                HaikyuPlayer(displayName: "Higashiyama", jerseyNumber: 4, wikiTitle: "Katsumichi Higashiyama", school: .johzenji),
                HaikyuPlayer(displayName: "Numajiri", jerseyNumber: 7, wikiTitle: "Rintarō Numajiri", school: .johzenji),
                HaikyuPlayer(displayName: "Izaka", jerseyNumber: 9, wikiTitle: "Nobuyoshi Īzaka", school: .johzenji),
                HaikyuPlayer(displayName: "Tsuchiyu", jerseyNumber: 11, wikiTitle: "Arata Tsuchiyu", school: .johzenji),
            ]
        case .inarizaki:
            return [
                HaikyuPlayer(displayName: "Atsumu", jerseyNumber: 7, wikiTitle: "Atsumu Miya", school: .inarizaki),
                HaikyuPlayer(displayName: "Osamu", jerseyNumber: 11, wikiTitle: "Osamu Miya", school: .inarizaki),
                HaikyuPlayer(displayName: "Suna", jerseyNumber: 10, wikiTitle: "Rintarō Suna", school: .inarizaki),
                HaikyuPlayer(displayName: "Kita", jerseyNumber: 1, wikiTitle: "Shinsuke Kita", school: .inarizaki),
                HaikyuPlayer(displayName: "Aran", jerseyNumber: 4, wikiTitle: "Aran Ojiro", school: .inarizaki),
                HaikyuPlayer(displayName: "Ginjima", jerseyNumber: 5, wikiTitle: "Hitoshi Ginjima", school: .inarizaki),
                HaikyuPlayer(displayName: "Omimi", jerseyNumber: 2, wikiTitle: "Ren Ōmimi", school: .inarizaki),
                HaikyuPlayer(displayName: "Akagi", jerseyNumber: 15, wikiTitle: "Michinari Akagi", school: .inarizaki),
            ]
        case .kamomedai:
            return [
                HaikyuPlayer(displayName: "Hoshiumi", jerseyNumber: 5, wikiTitle: "Kōrai Hoshiumi", school: .kamomedai),
                HaikyuPlayer(displayName: "Hirugami", jerseyNumber: 6, wikiTitle: "Sachirō Hirugami", school: .kamomedai),
            ]
        case .itachiyama:
            return [
                HaikyuPlayer(displayName: "Sakusa", jerseyNumber: 10, wikiTitle: "Kiyoomi Sakusa", school: .itachiyama),
                HaikyuPlayer(displayName: "Komori", jerseyNumber: 13, wikiTitle: "Motoya Komori", school: .itachiyama),
            ]
        }
    }
}

// MARK: - Theme

/// What the learner picked in the menu bar panel's "Team theme" section.
enum CompanionTheme: Equatable {
    case clickyBlue
    case school(HaikyuSchool)
    /// Every agent is a random player from any team, and the cursor stays Clicky blue.
    case random

    /// The saved form in UserDefaults. A string nothing here produces reads back as Clicky blue.
    var rawValue: String {
        switch self {
        case .clickyBlue: return "clickyBlue"
        case .school(let school): return "school:" + school.rawValue
        case .random: return "random"
        }
    }

    init(rawValue: String) {
        if rawValue == "random" {
            self = .random
        } else if rawValue.hasPrefix("school:"), let school = HaikyuSchool(rawValue: String(rawValue.dropFirst("school:".count))) {
            self = .school(school)
        } else {
            self = .clickyBlue
        }
    }

    /// The color of the cursor triangle, glow, spinner, waveform, and navigation bubble.
    var cursorColor: Color {
        switch self {
        case .clickyBlue, .random: return DS.Colors.overlayCursorBlue
        case .school(let school): return school.accentColor
        }
    }

    /// Drawn around the cursor triangle so a light team color still shows on a light page. Nil keeps today's look.
    var cursorOutlineColor: Color? {
        switch self {
        case .clickyBlue, .random: return nil
        case .school(let school): return school.contrastColor
        }
    }

    /// For text drawn on a cursor-colored fill, such as the navigation bubble's letters.
    var cursorContrastColor: Color {
        switch self {
        case .clickyBlue, .random: return .white
        case .school(let school): return school.contrastColor
        }
    }

    /// The same two colors as hex strings, for the frame pop-out page's quiz label.
    var cursorColorHex: String {
        switch self {
        case .clickyBlue, .random: return "#3380ff"
        case .school(let school): return school.accentHex
        }
    }

    var cursorContrastColorHex: String {
        switch self {
        case .clickyBlue, .random: return "#ffffff"
        case .school(let school): return school.contrastHex
        }
    }

    var usesVolleyballMenuBarIcon: Bool {
        switch self {
        case .clickyBlue: return false
        case .school, .random: return true
        }
    }
}

/// The one source of truth for the theme. CompanionManager owns it and passes it to the views and the agent store.
@MainActor
final class CompanionThemeSettings: ObservableObject {
    static let userDefaultsKey = "companionTheme"

    @Published var theme: CompanionTheme {
        didSet { userDefaults.set(theme.rawValue, forKey: Self.userDefaultsKey) }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        theme = CompanionTheme(rawValue: userDefaults.string(forKey: Self.userDefaultsKey) ?? "")
    }
}

// MARK: - Picking a player

/// The player a new agent becomes. An unthemed Clicky gets nil. A school hands out its roster in popularity order,
/// skipping players the agent list still shows, so one list never shows the same player twice while the roster has
/// others. Once every player is listed it reuses one whose agent has ended, and only past that one already working.
/// Random applies the same three steps over every school's players, picking at random within each step.
func nextHaikyuPlayer(
    for theme: CompanionTheme,
    playersOfRunningAgents: [HaikyuPlayer],
    playersOfEndedAgentsStillListed: [HaikyuPlayer],
    randomNumberGenerator: inout some RandomNumberGenerator
) -> HaikyuPlayer? {
    let playersStillListed = playersOfRunningAgents + playersOfEndedAgentsStillListed
    switch theme {
    case .clickyBlue:
        return nil
    case .school(let school):
        let roster = school.roster
        if let unlistedPlayer = roster.first(where: { !playersStillListed.contains($0) }) {
            return unlistedPlayer
        }
        if let playerNotWorking = roster.first(where: { !playersOfRunningAgents.contains($0) }) {
            return playerNotWorking
        }
        return roster[playersOfRunningAgents.count % roster.count]
    case .random:
        let everyPlayer = HaikyuSchool.allCases.flatMap(\.roster)
        let unlistedPlayers = everyPlayer.filter { !playersStillListed.contains($0) }
        let playersNotWorking = everyPlayer.filter { !playersOfRunningAgents.contains($0) }
        let candidates = !unlistedPlayers.isEmpty ? unlistedPlayers : (!playersNotWorking.isEmpty ? playersNotWorking : everyPlayer)
        return candidates.randomElement(using: &randomNumberGenerator)
    }
}

// MARK: - Portraits

/// Loads a player's bundled portrait, or nil when none is bundled. The portraits are gitignored, so CI and a fresh
/// clone have none, and the views draw the initials circle instead.
@MainActor
enum HaikyuPortraitCache {
    private static var portraitsByResourceName: [String: NSImage?] = [:]

    static func image(for player: HaikyuPlayer) -> NSImage? {
        let resourceName = player.portraitResourceName
        if let cachedPortrait = portraitsByResourceName[resourceName] {
            return cachedPortrait
        }
        let portraitURL = Bundle.main.url(forResource: resourceName, withExtension: "jpg", subdirectory: "HaikyuPortraits")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "jpg")
        let portrait = portraitURL.flatMap { NSImage(contentsOf: $0) }
        portraitsByResourceName[resourceName] = .some(portrait)
        return portrait
    }
}

/// A player's round portrait, or the school's accent filled with the player's initials when none is bundled.
struct HaikyuPortraitView: View {
    let player: HaikyuPlayer
    let size: CGFloat
    /// Finished and failed agents show a grayscale portrait or a dimmed one, so the state reads at a glance.
    var isGrayscale = false

    var body: some View {
        Group {
            if let portrait = HaikyuPortraitCache.image(for: player) {
                Image(nsImage: portrait)
                    .resizable()
                    .scaledToFill()
                    .grayscale(isGrayscale ? 1 : 0)
            } else {
                ZStack {
                    Circle().fill(player.school.accentColor)
                    Text(player.initials)
                        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                        .foregroundColor(player.school.contrastColor)
                }
                .grayscale(isGrayscale ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

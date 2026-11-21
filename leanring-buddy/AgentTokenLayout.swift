//
//  AgentTokenLayout.swift
//  leanring-buddy
//
//  The rules for the agent tokens that float in the menu bar beside the notch, as plain data and pure functions:
//  which agents have a token and in what rank order, how many discs fit in the free space, which tokens show in
//  which position, and what color a token's ring is. The AppKit side (`AgentTokenDockController`) measures the
//  screen and feeds these functions a width. Nothing here draws or reads a window.
//

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Rank

/// Which agents get a slot first. Rank only decides who fills a slot that opens. A token that already shows is never
/// displaced by a higher rank.
enum AgentTokenRank: Int, Comparable {
    case running = 0
    /// A finished agent whose result has not reached the learner yet.
    case waitingResult = 1
    /// A finished or failed agent in the few seconds its chip shows.
    case ending = 2

    static func < (firstRank: AgentTokenRank, secondRank: AgentTokenRank) -> Bool {
        firstRank.rawValue < secondRank.rawValue
    }
}

/// The agents that have a token at `now`, best rank first. Within a rank the newest comes first: by start time for a
/// running agent, and by end time for the others.
func agentsWithTokens(from agents: [BackgroundAgent], at now: Date) -> [BackgroundAgent] {
    let rankedAgents: [(agent: BackgroundAgent, rank: AgentTokenRank)] = agents.compactMap { agent in
        guard let rank = agent.tokenRank(at: now) else { return nil }
        return (agent, rank)
    }
    return rankedAgents
        .sorted { firstEntry, secondEntry in
            if firstEntry.rank != secondEntry.rank { return firstEntry.rank < secondEntry.rank }
            let firstNewness = firstEntry.agent.endedAt ?? firstEntry.agent.startedAt
            let secondNewness = secondEntry.agent.endedAt ?? secondEntry.agent.startedAt
            return firstNewness > secondNewness
        }
        .map(\.agent)
}

// MARK: - Positions

/// One disc beside the notch: an agent's token, or the "+N" disc after them.
enum AgentTokenSlot: Hashable {
    case agent(UUID)
    case overflow
}

/// One disc on one display. The same agent has a disc on every display whose menu bar shows, so a display belongs to the
/// identity: a click on one display's disc is never "the same disc" as the other display's.
struct AgentTokenDiscID: Hashable {
    let displayID: CGDirectDisplayID
    let tokenSlot: AgentTokenSlot
}

/// What shows beside the notch on one display: the agents whose tokens show, left to right, and how many more agents
/// the "+N" disc after them stands for. An overflow count of 0 means there is no "+N" disc.
struct AgentTokenLayout: Equatable {
    let shownAgentIDs: [UUID]
    let overflowCount: Int
}

/// The most positions beside the notch. The last one is the "+N" disc whenever the agents do not all fit in the first three.
let mostAgentTokenPositions = 4

/// The most tokens that show with no "+N" disc.
let mostAgentTokensWithoutOverflow = 3

/// Decides which agents' tokens show in which position.
///
/// - `previouslyShownAgentIDs`: the tokens this display showed last time, left to right.
/// - `rankedAgentIDs`: every agent with a token, best rank first (`agentsWithTokens`).
/// - `positionCount`: how many discs fit in the measured free space, at most `mostAgentTokenPositions`.
///
/// Positions are the discs that fit. When the agents fit in the first `min(3, positions)`, all show. Otherwise the last
/// position is a "+N" disc and the tokens fill the ones before it. A token that showed before keeps its position until it
/// leaves, and the ones after it close the gap. Rank decides which agents fill the positions that are open. Only when
/// fewer positions fit than before, or the "+N" disc needs the last position, does a shown token at the end give way.
func agentTokenLayout(previouslyShownAgentIDs: [UUID], rankedAgentIDs: [UUID], positionCount: Int) -> AgentTokenLayout {
    let positionCount = min(mostAgentTokenPositions, max(0, positionCount))
    guard positionCount > 0 else { return AgentTokenLayout(shownAgentIDs: [], overflowCount: 0) }

    let allAgentsFit = rankedAgentIDs.count <= min(mostAgentTokensWithoutOverflow, positionCount)
    let tokenPositionCount = allAgentsFit ? rankedAgentIDs.count : positionCount - 1

    let stillRankedAgentIDs = Set(rankedAgentIDs)
    let keptAgentIDs = previouslyShownAgentIDs.filter { stillRankedAgentIDs.contains($0) }.prefix(tokenPositionCount)
    let keptAgentIDSet = Set(keptAgentIDs)
    let newAgentIDs = rankedAgentIDs.filter { !keptAgentIDSet.contains($0) }.prefix(tokenPositionCount - keptAgentIDs.count)

    let shownAgentIDs = Array(keptAgentIDs) + Array(newAgentIDs)
    return AgentTokenLayout(shownAgentIDs: shownAgentIDs, overflowCount: rankedAgentIDs.count - shownAgentIDs.count)
}

// MARK: - Free space

/// Disc sizes, in points. A disc is 22 across, and its panel adds half of the 6 point gap on each side.
enum AgentTokenMetrics {
    static let discDiameter: CGFloat = 22
    static let gapBetweenDiscs: CGFloat = 6
    /// A disc's panel is as wide as the disc plus half a gap on each side, so a click anywhere between two discs lands on one.
    static let panelWidth: CGFloat = discDiameter + gapBetweenDiscs
    /// Space between the free space's left edge (the notch, or the front app's last menu title) and the first disc.
    static let spaceBeforeTheFirstDisc: CGFloat = 10
    /// Space between the last disc and the first status icon.
    static let spaceBeforeTheFirstStatusIcon: CGFloat = 6
    /// How far past the front app's last menu title the free space starts.
    static let spaceAfterTheLastMenuTitle: CGFloat = 8
}

/// How many discs fit between `freeSpaceMinX` and `endOfFreeSpaceX`, the first status icon's left edge, or the screen's
/// right edge when no icon is in the way.
func agentTokenPositionCount(freeSpaceMinX: CGFloat, endOfFreeSpaceX: CGFloat) -> Int {
    let usableWidth = endOfFreeSpaceX - freeSpaceMinX - AgentTokenMetrics.spaceBeforeTheFirstDisc - AgentTokenMetrics.spaceBeforeTheFirstStatusIcon
    // n discs take n * 22 + (n - 1) * 6 points, which is n * 28 - 6.
    let discsThatFit = Int(((usableWidth + AgentTokenMetrics.gapBetweenDiscs) / AgentTokenMetrics.panelWidth).rounded(.down))
    return min(mostAgentTokenPositions, max(0, discsThatFit))
}

/// Where the free space starts, in the screen's own x coordinates.
///
/// - With a notch, the free space starts at the notch's right edge, or 8 points past the front app's last menu title when
///   its menus continue past the notch.
/// - With no notch, it starts at the screen's horizontal center or 8 points past the last menu title, whichever is
///   further right, so the discs never cover a menu.
func agentTokenFreeSpaceMinX(notchMaxX: CGFloat?, screenMidX: CGFloat, lastMenuTitleMaxX: CGFloat?) -> CGFloat {
    let afterTheLastMenuTitle = lastMenuTitleMaxX.map { $0 + AgentTokenMetrics.spaceAfterTheLastMenuTitle }
    if let notchMaxX {
        if let lastMenuTitleMaxX, let afterTheLastMenuTitle, lastMenuTitleMaxX > notchMaxX { return afterTheLastMenuTitle }
        return notchMaxX
    }
    return max(screenMidX, afterTheLastMenuTitle ?? screenMidX)
}

/// The left edge of the first status icon that sits right of `freeSpaceMinX`, from the on-screen windows at the status
/// window layer. Control Center owns most of them, so the layer picks them, not the owner. Only windows inside the menu
/// bar's strip count, so a window the layer shares elsewhere never narrows the space.
func firstStatusIconMinX(statusWindowFrames: [CGRect], menuBarStrip: CGRect, rightOf freeSpaceMinX: CGFloat) -> CGFloat? {
    statusWindowFrames
        .filter { $0.intersects(menuBarStrip) && $0.minX >= freeSpaceMinX }
        .map(\.minX)
        .min()
}

/// Whether a display's menu bar shows. In a full-screen space or with the menu bar hidden, the visible frame reaches the
/// screen's top edge, and on a notched display the strip beside the notch stays empty then, so no disc floats.
func menuBarIsShowing(screenFrame: CGRect, visibleFrame: CGRect) -> Bool {
    screenFrame.maxY - visibleFrame.maxY > 0
}

// MARK: - Colors

/// The colors an agent can have. Under Clicky blue it takes one of the fixed palette, in the order a new agent looks for a
/// free one. Red is left out because it means failed, and so is green, which is the done check. Under another theme it
/// takes one of the theme's own agent colors, which the theme parser kept clear of red and green, or the theme's accent.
enum AgentPaletteColor: Equatable {
    case teal
    case amber
    case violet
    case lime
    case sky
    case pink
    /// One of a theme's agent colors, or its accent.
    case custom(ThemeRGBColor)

    /// The fixed palette under Clicky blue, in the order a new agent looks for a free color.
    static let fixedPalette: [AgentPaletteColor] = [.teal, .amber, .violet, .lime, .sky, .pink]

    var color: Color {
        switch self {
        case .teal: return DS.Colors.backgroundAgentTaskTeal
        case .amber: return DS.Colors.backgroundAgentStudyGuideAmber
        case .violet: return DS.Colors.backgroundAgentThreeDModelViolet
        case .lime: return DS.Colors.backgroundAgentExperimentLime
        case .sky: return DS.Colors.sky400
        case .pink: return DS.Colors.pink400
        case .custom(let themeColor): return Color(red: themeColor.red, green: themeColor.green, blue: themeColor.blue)
        }
    }

    /// A darker shade of the same hue for the chip's letters, since the color itself is too light to read inside a white outline.
    var chipTextColor: Color {
        switch self {
        case .teal: return DS.Colors.backgroundAgentTaskTealText
        case .amber: return DS.Colors.backgroundAgentStudyGuideAmberText
        case .violet: return DS.Colors.backgroundAgentThreeDModelVioletText
        case .lime: return DS.Colors.backgroundAgentExperimentLimeText
        case .sky: return DS.Colors.sky700
        case .pink: return DS.Colors.pink700
        // Half the brightness of the same hue, which reads inside the chip's white outline.
        case .custom(let themeColor): return Color(red: themeColor.red * 0.5, green: themeColor.green * 0.5, blue: themeColor.blue * 0.5)
        }
    }
}

/// The color a new agent takes, kept for its whole life. `colorsInUse` is one entry for each other running agent, and each
/// agent whose result waits, that has a color. The agent takes its kind's color when no one else has it, and otherwise the
/// first palette color no one has. When every color is in use, it cycles through the palette.
func agentPaletteColorToAssign(forKind agentKind: BackgroundAgentKind, colorsInUse: [AgentPaletteColor]) -> AgentPaletteColor {
    let preferredColor = agentKind.preferredPaletteColor
    if !colorsInUse.contains(preferredColor) { return preferredColor }
    if let freeColor = AgentPaletteColor.fixedPalette.first(where: { !colorsInUse.contains($0) }) { return freeColor }
    return AgentPaletteColor.fixedPalette[colorsInUse.count % AgentPaletteColor.fixedPalette.count]
}

/// The color a new agent takes under a custom theme: the first of the theme's agent colors that no other running agent or
/// waiting result has, and once every one is in use, the theme's colors in order again. The theme's agent colors are
/// already checked `#RRGGBB`, so none is dropped here.
func agentPaletteColorToAssign(forCustomThemeAgentColorHexes agentColorHexes: [String], colorsInUse: [AgentPaletteColor]) -> AgentPaletteColor {
    let themeColors = agentColorHexes.compactMap(ThemeRGBColor.init(hex:)).map(AgentPaletteColor.custom)
    guard !themeColors.isEmpty else { return .teal }
    if let freeColor = themeColors.first(where: { !colorsInUse.contains($0) }) { return freeColor }
    return themeColors[colorsInUse.count % themeColors.count]
}

/// What colors a token's ring, before it becomes a SwiftUI color, so the choice is testable.
enum AgentTokenRingColorChoice: Equatable {
    /// The ring takes the color the agent was given when it started: its theme's accent, one of the theme's agent colors,
    /// or Clicky's palette.
    case assigned(AgentPaletteColor)
    /// A failed agent's ring is red, whatever the theme, along with its cross badge and gray face.
    case failed

    var color: Color {
        switch self {
        case .assigned(let paletteColor): return paletteColor.color
        case .failed: return DS.Colors.destructive
        }
    }
}

func agentTokenRingColorChoice(for agent: BackgroundAgent) -> AgentTokenRingColorChoice {
    if agent.phase.isFailed { return .failed }
    return .assigned(agent.displayColor)
}

// MARK: - A new agent's look

extension ClickyTheme {
    /// The colors the theme's agents take, in the order they hand them out, for swatches such as the Theme Studio's tiles.
    var agentColorsInOrder: [AgentPaletteColor] {
        switch agents.ring {
        case .perKind: return AgentPaletteColor.fixedPalette
        case .perAgent(let colorHexes): return colorHexes.compactMap(ThemeRGBColor.init(hex:)).map(AgentPaletteColor.custom)
        case .accent: return ThemeRGBColor(hex: accentHex).map { [AgentPaletteColor.custom($0)] } ?? []
        }
    }
}

/// The color and the face an agent takes when it starts, kept for its whole life.
struct NewAgentLook: Equatable {
    let tokenColor: AgentPaletteColor
    let face: AgentFace
}

/// The look a new agent takes from `theme`, the theme it starts under (the saved theme, or with Shuffle on, one picked at
/// random). `colorsInUse` is one entry for each other running agent, and each agent whose result waits, that has a color.
/// The roster faces are the faces of the agents the list still shows, so a roster hands out a player no one shows first.
func newAgentLook(
    kind agentKind: BackgroundAgentKind,
    theme: ClickyTheme,
    colorsInUse: [AgentPaletteColor],
    rosterFacesOfRunningAgents: [AgentRosterFace],
    rosterFacesOfEndedAgentsStillListed: [AgentRosterFace]
) -> NewAgentLook {
    let tokenColor: AgentPaletteColor
    switch theme.agents.ring {
    case .perKind:
        tokenColor = agentPaletteColorToAssign(forKind: agentKind, colorsInUse: colorsInUse)
    case .perAgent(let colorHexes):
        tokenColor = agentPaletteColorToAssign(forCustomThemeAgentColorHexes: colorHexes, colorsInUse: colorsInUse)
    case .accent:
        tokenColor = ThemeRGBColor(hex: theme.accentHex).map(AgentPaletteColor.custom) ?? agentKind.preferredPaletteColor
    }

    let face: AgentFace
    switch theme.agents.faces {
    case .triangle:
        face = .triangle
    case .picture:
        // Only a saved theme has a picture.jpg to show, so an idea's agents keep the triangle.
        if case .saved = theme.origin {
            face = .themePicture(themeID: theme.id)
        } else {
            face = .triangle
        }
    case .roster(let players):
        let playersOfThisTheme = { (rosterFaces: [AgentRosterFace]) in
            rosterFaces.filter { $0.themeID == theme.id }.map(\.player)
        }
        let player = rosterPlayerForANewAgent(
            roster: players,
            playersOfRunningAgents: playersOfThisTheme(rosterFacesOfRunningAgents),
            playersOfEndedAgentsStillListed: playersOfThisTheme(rosterFacesOfEndedAgentsStillListed)
        )
        face = player.map { .rosterFace(AgentRosterFace(player: $0, of: theme)) } ?? .triangle
    }
    return NewAgentLook(tokenColor: tokenColor, face: face)
}

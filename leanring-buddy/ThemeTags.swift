//
//  ThemeTags.swift
//  leanring-buddy
//
//  A theme described in words: the Theme Studio card's tags, the "Add theme?" card's line about how it moves, and the
//  Quick Look preview's same line. The Quick Look extension compiles this file too, so the preview says what the card says.
//

import Foundation

/// What the card says about the highlighted idea, in words, as short tags: a picture cursor's look, how it moves, and the sounds.
nonisolated func themeStudioTags(for idea: ClickyTheme) -> [String] {
    var tags: [String] = []
    // A drawn cursor shows itself on the tile, so only a picture cursor gets a tag, since its fit and tint are easy to miss.
    if case .picture(let style) = idea.cursor {
        var pictureTag = "cursor: your picture"
        if style.fit == .circle { pictureTag += ", round" }
        if style.tintHex != nil && style.tintStrength > 0 { pictureTag += ", tinted" }
        tags.append(pictureTag)
    }
    if idea.motion.turnsTowardMovement { tags.append("turns as it moves") }
    if idea.motion.trailStreaks > 0 {
        tags.append(idea.motion.trailStreaks == 1 ? "1 trail streak" : "\(idea.motion.trailStreaks) trail streaks")
    }
    switch idea.motion.whileThinking {
    case .none: break
    case .spin: tags.append("spins while thinking")
    case .pulse: tags.append("pulses while thinking")
    case .wobble: tags.append("wobbles while thinking")
    }
    if idea.motion.whileListening == .pulse { tags.append("pulses while you talk") }
    if let springs = idea.motion.springs, let feel = themeMotionFeel(of: springs) { tags.append(feel) }
    tags.append("sounds: \(idea.sounds.done.rawValue), \(idea.sounds.correct.rawValue), \(idea.sounds.needsYourOK.rawValue)")
    return tags
}

/// The word for how a theme's springs feel, from its Pop spring, or nil for Clicky's own. The Worker's prompt asks for these
/// ranges when the learner says bouncy, calm, or snappy, so the card repeats the word they used.
nonisolated func themeMotionFeel(of springs: ThemeMoveSprings) -> String? {
    guard springs != .standard else { return nil }
    if springs.pop.dampingFraction < 0.65 { return "bouncy motion" }
    if springs.pop.response >= 0.38 && springs.pop.dampingFraction >= 0.95 { return "calm motion" }
    if springs.pop.response <= 0.25 { return "snappy motion" }
    return "custom motion"
}

/// How the theme moves, in a line, such as "Wobbles while thinking · 2 trail streaks". It leaves out the sounds, which the
/// learner can hear after adding it. A theme with no motion says it keeps the cursor still.
nonisolated func themeInstallCardSummary(for theme: ClickyTheme) -> String {
    let motionTags = themeStudioTags(for: theme).filter { !$0.hasPrefix("sounds:") }
    guard let firstTag = motionTags.first else { return "A still cursor" }
    let joinedTags = ([firstTag.prefix(1).uppercased() + firstTag.dropFirst()] + motionTags.dropFirst()).joined(separator: " · ")
    return joinedTags
}

//
//  ThemeInstallConfirmation.swift
//  leanring-buddy
//
//  The "Add theme?" confirmation. Double-clicking a `.clickytheme` file in Finder used to install the theme and put it on at
//  once. Now Clicky reads and checks the package first (`CustomThemeStore.previewPackage`), shows a card that names the theme
//  and says how it moves, and installs only when the learner adds it. Packages opened together wait their turn, one card at a
//  time. `ThemeInstallCardPanel.swift` draws the card; this file holds the queue and the words, so tests need no window.
//

import AppKit
import Foundation

/// A package the learner opened that passed the checks and waits for their answer.
struct PendingThemeInstall: Equatable {
    /// Names this card, so a late answer from a card that was replaced is told from the answer of the one that shows, even
    /// when both are for the same file.
    let id = UUID()
    let packageURL: URL
    let theme: ClickyTheme
    /// The package's picture, when the theme's cursor or faces use it.
    let pictureJPEG: Data?
}

/// The card's question, such as `Add "Moonlit" to Clicky?`.
nonisolated func themeInstallCardTitle(for theme: ClickyTheme) -> String {
    "Add \"\(theme.name)\" to Clicky?"
}

/// How the theme moves, in a line, such as "Wobbles while thinking · 2 trail streaks". It leaves out the sounds, which the
/// learner can hear after adding it. A theme with no motion says it keeps the cursor still.
nonisolated func themeInstallCardSummary(for theme: ClickyTheme) -> String {
    let motionTags = themeStudioTags(for: theme).filter { !$0.hasPrefix("sounds:") }
    guard let firstTag = motionTags.first else { return "A still cursor" }
    let joinedTags = ([firstTag.prefix(1).uppercased() + firstTag.dropFirst()] + motionTags.dropFirst()).joined(separator: " · ")
    return joinedTags
}

/// Shows and hides the card. The real one is a panel, and a test swaps in one that records the calls.
@MainActor
protocol ThemeInstallCardPresenting: AnyObject {
    /// Shows the card for `pendingInstall` and calls `decide` once with whether the learner added it. A card still showing is
    /// replaced.
    func show(_ pendingInstall: PendingThemeInstall, decide: @escaping (_ learnerAddedIt: Bool) -> Void)
    func hide()
}

/// The queue of packages waiting for an answer. Only the card showing can be answered, so a second package opened meanwhile
/// waits for the first.
@MainActor
final class ThemeInstallConfirmation {
    private let cardPresenter: ThemeInstallCardPresenting
    /// Installs a package the learner added.
    private let install: (PendingThemeInstall) -> Void
    private var waitingInstalls: [PendingThemeInstall] = []
    private var showingInstall: PendingThemeInstall?

    init(cardPresenter: ThemeInstallCardPresenting, install: @escaping (PendingThemeInstall) -> Void) {
        self.cardPresenter = cardPresenter
        self.install = install
    }

    var isOpen: Bool { showingInstall != nil }

    /// Asks the learner about `pendingInstall`: now, or after the ones before it.
    /// A package that is already showing or waiting is not asked about twice, since the learner would then install it twice.
    func ask(about pendingInstall: PendingThemeInstall) {
        let alreadyAsked = showingInstall?.packageURL == pendingInstall.packageURL
            || waitingInstalls.contains { $0.packageURL == pendingInstall.packageURL }
        guard !alreadyAsked else { return }
        waitingInstalls.append(pendingInstall)
        showTheNextInstallIfNoneShows()
    }

    /// Escape answers the card that shows with a no, and the next package waits behind it. False when no card shows.
    func cancelOnEscape() -> Bool {
        guard isOpen else { return false }
        decide(learnerAddedIt: false)
        return true
    }

    private func showTheNextInstallIfNoneShows() {
        guard showingInstall == nil, !waitingInstalls.isEmpty else { return }
        let nextInstall = waitingInstalls.removeFirst()
        showingInstall = nextInstall
        cardPresenter.show(nextInstall) { [weak self] learnerAddedIt in
            // A card replaced by the next one answers for itself only.
            guard let self, self.showingInstall?.id == nextInstall.id else { return }
            self.decide(learnerAddedIt: learnerAddedIt)
        }
    }

    private func decide(learnerAddedIt: Bool) {
        guard let answeredInstall = showingInstall else { return }
        showingInstall = nil
        cardPresenter.hide()
        if learnerAddedIt {
            install(answeredInstall)
        } else {
            print("Themes: the learner did not add \(answeredInstall.packageURL.lastPathComponent)")
        }
        showTheNextInstallIfNoneShows()
    }
}

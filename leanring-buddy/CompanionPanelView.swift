//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content of the menu bar panel, on the Tether Card. It is the only Clicky window that takes the keyboard, so
//  it is the keyboard and VoiceOver home for everything else: the agents (whose discs never take the keyboard), the
//  approval that waits, every setting the settings dial offers, and the themes.
//
//  Three pages share the header: the home (the banner slot, the agents row, the model, Show Clicky, the theme cards, and
//  the footer), all themes (every theme as a card, and the Shuffle switch), and setup (the six steps, which a first run
//  opens on and the footer's Setup reopens, so the optional Chrome control step stays reachable).
//
//  Motion: the card Glides down out of the menu bar icon (scale 0.96 to 1 from its top, on the Glide move) with its rows
//  rising 30 ms apart, the banner slot Glides open, and picking a theme Pops the new cursor into the header. With Reduce
//  Motion on, the card and the banner only crossfade and the cursor appears.
//

import AppKit
import Combine
import SwiftUI

/// What `MenuBarPanelManager` tells the view about the panel window: whether it is open, which page shows, and how to fit
/// the window to the card.
@MainActor
final class PanelPresentation: ObservableObject {
    @Published var isOpen = false
    @Published var page: PanelPage = .home
    /// Counts the opens, so the approval card is a new view on each one and measures its summary from the top again.
    @Published var openCount = 0
    /// The tallest a page under the header may be before it scrolls, so the card never runs past the screen's bottom.
    @Published var tallestPageHeight: CGFloat = panelTallestPageHeightWithNoScreen
    /// Called when the card's size changes, so the window follows it with its top edge kept under the menu bar.
    var onCardSizeChanged: (() -> Void)?
}

extension EnvironmentValues {
    /// False while the menu bar panel is closed. Its window keeps its views, so a clock in it, such as a hovered theme
    /// card's motion, reads this and stops.
    @Entry var menuPanelIsOpen = true
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var themeSettings: CompanionThemeSettings
    @ObservedObject var backgroundAgentStore: BackgroundAgentStore
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var workerReachability: WorkerReachability
    @ObservedObject var approvalDesk: HarnessApprovalDesk

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False while the panel is closed, so each open plays the Glide in.
    @State private var hasGlidedIn = false
    /// The agent chip the learner picked, whose actions show under the agents row.
    @State private var selectedAgentID: UUID?
    /// The banner slot's height, which the page under it gives up so the card still ends above the screen's bottom.
    @State private var bannerSlotHeight: CGFloat = 0

    /// The panel card's width, without the shadow margin around it.
    static let contentWidth: CGFloat = 340

    /// Transparent space around the card for its drop shadow, which the Card draws 24 points wide and 14 points down. A
    /// window clips what it draws, so without this margin the shadow is cut off at the edge. `MenuBarPanelManager` sizes and
    /// places the window with it.
    static let shadowMargin = EdgeInsets(top: 12, leading: 28, bottom: 40, trailing: 28)

    var body: some View {
        panelCard
            .padding(Self.shadowMargin)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var accentColor: Color { themeSettings.shownTheme.cursorColor }

    private var panelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(
                shownTheme: themeSettings.shownTheme,
                status: headerStatus,
                close: { NotificationCenter.default.post(name: .clickyDismissPanel, object: nil) },
                stopTheQuiz: { companionManager.stopTheVideoQuizFromThePanel() }
            )
            .panelRowRise(order: 0, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)

            // The banner slot is pinned under the header, as the agent list pins its card, so the approval card never
            // scrolls out of sight while its clock runs.
            if presentation.page == .home, let banner {
                bannerSlot(banner)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bannerSlotHeight = $0 }
                    .onDisappear { bannerSlotHeight = 0 }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }

            switch presentation.page {
            case .allThemes:
                // All themes scrolls its own grid, so it sits outside the page scroll and never nests two of them.
                allThemesPage
            case .home, .setup:
                // A tall page scrolls under the header instead of running off the bottom of the screen.
                ScrollView(.vertical) {
                    if presentation.page == .home { homePage } else { setupPage }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: max(PanelMetrics.shortestScrollingPageHeight, presentation.tallestPageHeight - bannerSlotHeight))
            }
        }
        .animation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion), value: banner)
        .onChange(of: presentation.page) { _, pageNow in
            // The approval card shows only on the home, so leaving it stops the card's clock and lets the desk show the
            // request elsewhere.
            if pageNow != .home { companionManager.theMenuPanelStoppedShowingTheApprovalCard() }
        }
        .frame(width: Self.contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .tetherCard()
        .scaleEffect(hasGlidedIn || reduceMotion ? 1 : PanelMetrics.cardStartScale, anchor: .top)
        .opacity(hasGlidedIn ? 1 : 0)
        .animation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion), value: hasGlidedIn)
        .animation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion), value: presentation.page)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in presentation.onCardSizeChanged?() }
        .environment(\.menuPanelIsOpen, presentation.isOpen)
        .task(id: presentation.isOpen) { await glideInOrResetForTheNextOpen() }
    }

    private func glideInOrResetForTheNextOpen() async {
        guard presentation.isOpen else {
            var noAnimation = Transaction()
            noAnimation.disablesAnimations = true
            withTransaction(noAnimation) { hasGlidedIn = false }
            selectedAgentID = nil
            return
        }
        // One turn, so the first frame of the open draws the card at its start, and the Glide has somewhere to go.
        await Task.yield()
        hasGlidedIn = true
    }

    // MARK: - State

    private var setupStepStateList: [(step: SetupStep, state: SetupStepState)] { setupStepStates(for: companionManager.setupFacts) }

    private var headerStatus: PanelHeaderStatus {
        panelHeaderStatus(
            setupIsFinished: companionManager.setupIsFinished,
            aRequiredPermissionIsOff: firstRequiredSetupStepThatIsOff(setupStepStateList) != nil,
            workerIsUnreachable: workerReachability.isUnreachable,
            voiceState: companionManager.voiceState,
            aVideoQuizQuestionIsOpen: backgroundAgentStore.aVideoQuizQuestionIsOpen,
            videoQuizProgress: companionManager.videoQuizProgress,
            approvalRequestsWaiting: approvalDesk.waitingRequests.count
        )
    }

    private var banner: PanelBanner? {
        panelBanner(
            anApprovalCardShows: approvalDesk.cardToShow(on: .menuPanel, at: Date()) != nil,
            setupIsFinished: companionManager.setupIsFinished,
            firstRequiredStepThatIsOff: firstRequiredSetupStepThatIsOff(setupStepStateList),
            workerIsUnreachable: workerReachability.isUnreachable
        )
    }

    private func runTheBanner(_ banner: PanelBanner) {
        switch banner {
        case .approvalCard: break
        case .permissionOff: presentation.page = .setup
        case .workerUnreachable: Task { await workerReachability.check() }
        }
    }

    /// The approval card, on the panel's own surface, or a problem banner.
    @ViewBuilder private func bannerSlot(_ banner: PanelBanner) -> some View {
        if let problemWords = panelProblemBannerWords(for: banner) {
            PanelBannerView(words: problemWords, run: { runTheBanner(banner) })
        } else if let shownCard = approvalDesk.cardToShow(on: .menuPanel, at: Date()) {
            let requestingAgent = backgroundAgentStore.agents.first { agent in agent.id == shownCard.request.taskID }
            ApprovalCardView(
                shownCard: shownCard,
                agentName: requestingAgent?.displayName ?? "An agent",
                learnerWords: requestingAgent?.learnerWords,
                wholeSummaryShownSince: approvalDesk.wholeSummaryShownSinceBySurface[.menuPanel],
                answerApproval: { approvalID, approved, scope in
                    approvalDesk.answerByClick(approvalID: approvalID, approved: approved, scope: scope, on: .menuPanel)
                },
                summaryWasShownWhole: { summaryWasShownWhole in
                    // A closed panel reports nothing, since its card is not on screen to be read.
                    guard presentation.isOpen else { return }
                    if summaryWasShownWhole {
                        approvalDesk.theCardShowedTheWholeSummary(ofApprovalID: shownCard.request.approvalID, on: .menuPanel)
                    } else {
                        approvalDesk.theCardHasNotShownTheWholeSummary(on: .menuPanel)
                    }
                }
            )
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // A new request, or a new open of the panel, gets a new card, so its summary is measured from the top: the
            // desk forgot what this surface had seen when the panel closed.
            .id("\(shownCard.request.approvalID)-\(presentation.openCount)")
        }
    }

    // MARK: - Home

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The closed panel keeps its view, so the row's clock runs only while the panel is open.
            if presentation.isOpen {
                TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
                    if let agentsSummary = panelAgentsSummary(agents: backgroundAgentStore.agents, agentsArePaused: backgroundAgentStore.agentsArePaused, anApprovalWaits: !backgroundAgentStore.agentIDsWaitingForApproval.isEmpty, at: timelineContext.date) {
                        PanelAgentsSection(
                            summary: agentsSummary,
                            agents: agentsWithTokens(from: backgroundAgentStore.agents, at: timelineContext.date),
                            store: backgroundAgentStore,
                            selectedAgentID: $selectedAgentID,
                            companionManager: companionManager
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                }
                .panelRowRise(order: 1, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)
            }

            PanelSectionLabel(title: "Model") {
                PanelModelPicker(
                    selectedModelID: companionManager.selectedModel,
                    select: { companionManager.setSelectedModel($0) }
                )
            }
            .padding(.top, 8)
            .panelRowRise(order: 2, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)

            PanelSectionLabel(title: "Cursor") {
                HStack(spacing: 8) {
                    Text("Show Clicky")
                        .font(DS.TypeScale.caption.font)
                        .foregroundColor(DS.Colors.textSecondary)
                    PanelSwitch(
                        accessibilityLabel: "Show Clicky",
                        isOn: Binding(
                            get: { companionManager.isClickyCursorEnabled },
                            set: { companionManager.setClickyCursorEnabled($0) }
                        ),
                        accentColor: accentColor
                    )
                }
            }
            .panelRowRise(order: 3, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)

            PanelSectionLabel(title: "Theme") {
                PanelButton(
                    title: "All \(themeSettings.bundledThemes.count + themeSettings.savedCustomThemes.count) themes ›",
                    prominence: .quiet,
                    action: { presentation.page = .allThemes }
                )
            }
            .panelRowRise(order: 4, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)

            themeGrid(
                themes: panelHomeThemes(
                    selectedTheme: themeSettings.theme,
                    bundledThemes: themeSettings.bundledThemes,
                    savedThemesNewestFirst: themeSettings.savedCustomThemesWithSavedDates.sorted { $0.savedDate > $1.savedDate }.map(\.theme)
                )
            )
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .panelRowRise(order: 5, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)

            footer
                .panelRowRise(order: 6, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)
        }
        .transition(.opacity)
    }

    private func themeGrid(themes: [ClickyTheme]) -> some View {
        ThemeCardGrid(
            themes: themes,
            selectedTheme: themeSettings.theme,
            designATheme: { companionManager.designAThemeFromThePanel() },
            pick: { themeSettings.theme = $0 },
            rename: { theme, typedName in try themeSettings.renameSavedTheme(themeID: theme.id, to: typedName) },
            delete: { theme in try themeSettings.deleteSavedTheme(themeID: theme.id) }
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.white.opacity(0.07))
            HStack(spacing: 14) {
                PanelShortcutHint(keys: ["⌃", "⌥"], meaning: "talk", spokenKeys: "Control Option")
                PanelShortcutHint(keys: ["⇧", "⌥"], meaning: "settings dial", spokenKeys: "Shift Option")
                PanelShortcutHint(keys: ["esc"], meaning: "stop", spokenKeys: "Escape")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #if DEBUG
            PanelDebugToolCallLoggingRow(accentColor: accentColor)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            #endif
            Divider().overlay(Color.white.opacity(0.07))
            HStack(spacing: 0) {
                PanelButton(title: "Send feedback", prominence: .quiet, accessibilityHint: "Opens a new issue on GitHub") {
                    if let newIssueURL = URL(string: Self.newIssueURLString) { NSWorkspace.shared.open(newIssueURL) }
                }
                Spacer(minLength: 4)
                PanelButton(title: "Setup", prominence: .quiet, accessibilityHint: "The six setup steps, Chrome control included") {
                    presentation.page = .setup
                }
                Spacer(minLength: 4)
                PanelButton(title: "Replay intro", prominence: .quiet) { companionManager.replayOnboarding() }
                Spacer(minLength: 4)
                PanelButton(title: "Quit", prominence: .quiet) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// The All themes grid shows about three rows before it scrolls.
    private static let tallestThemeGridHeight: CGFloat = 420
    /// The All themes page's title bar, Shuffle row, and hint above its grid.
    private static let allThemesChromeHeight: CGFloat = 120

    static let newIssueURLString = "https://github.com/crodris/clicky-watch-along/issues/new"

    // MARK: - All themes

    private var allThemesPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelPageTitleBar(title: "All themes", back: { presentation.page = .home })

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuffle agents across themes")
                        .font(DS.TypeScale.title.font)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Each new agent takes a random theme's look. Your cursor stays.")
                        .font(DS.TypeScale.caption.font)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                PanelSwitch(accessibilityLabel: "Shuffle agents across themes", isOn: $themeSettings.shufflesAgentThemes, accentColor: accentColor)
            }
            .padding(.horizontal, 16)

            Text("Arrow keys move between cards. Return picks.")
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 16)

            ScrollView(.vertical) {
                themeGrid(themes: panelAllThemes(bundledThemes: themeSettings.bundledThemes, savedThemesByName: themeSettings.savedCustomThemes))
                    .padding(.horizontal, 16)
                    // Room for the focus ring under the last row.
                    .padding(.vertical, 6)
                    .padding(.bottom, 24)
            }
            // Three rows of cards, or less on a short screen, less the page's own title and Shuffle rows.
            .frame(maxHeight: min(Self.tallestThemeGridHeight, presentation.tallestPageHeight - Self.allThemesChromeHeight))
        }
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    // MARK: - Setup

    private var setupPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if companionManager.setupIsFinished {
                PanelPageTitleBar(title: "Setup", back: { presentation.page = .home })
            }
            SetupChecklistView(
                stepStates: setupStepStateList,
                isAFirstRun: !companionManager.setupIsFinished,
                isRequestingTheScreenTest: companionManager.isRequestingScreenContent,
                shownTheme: themeSettings.shownTheme,
                runStep: { step, action in companionManager.runSetupStep(step, action: action) },
                start: {
                    companionManager.finishSetup()
                    // A first run's Start closes the panel for the intro, so the next open finds the home. A Debug
                    // `--show-setup` run stays open, and goes to the home here.
                    presentation.page = .home
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, companionManager.setupIsFinished ? 4 : 0)
            .padding(.bottom, 14)
            .panelRowRise(order: 1, hasGlidedIn: hasGlidedIn, reduceMotion: reduceMotion)

            if !companionManager.setupIsFinished {
                // Quit stays reachable on a first run, since the home's footer is not there yet.
                Divider().overlay(Color.white.opacity(0.07))
                HStack {
                    Spacer()
                    PanelButton(title: "Quit", prominence: .quiet) { NSApp.terminate(nil) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Row rise

extension View {
    /// A row of the panel rises 8 points into place as the panel opens, `order` times 30 ms after the first. With Reduce
    /// Motion on it only fades with the card.
    func panelRowRise(order: Int, hasGlidedIn: Bool, reduceMotion: Bool) -> some View {
        self
            .offset(y: hasGlidedIn || reduceMotion ? 0 : PanelMetrics.risePoints)
            .opacity(hasGlidedIn ? 1 : 0)
            .animation(
                DS.Move.glide.animation(reduceMotionIsOn: reduceMotion)?.delay(reduceMotion ? 0 : Double(order) * PanelMetrics.secondsBetweenRows),
                value: hasGlidedIn
            )
    }
}

/// The panel's motion and layout numbers.
enum PanelMetrics {
    /// How far below its place a row starts.
    static let risePoints: CGFloat = 8
    /// The gap between one row's rise and the next one's.
    static let secondsBetweenRows = 0.03
    /// The card grows from this scale as it Glides in.
    static let cardStartScale: CGFloat = 0.96
    /// A page under a tall approval card still shows this much before it scrolls.
    static let shortestScrollingPageHeight: CGFloat = 160
}

// MARK: - Header

/// The shown theme's cursor on a dark tile, "Clicky", and the state line, with the close button.
struct PanelHeaderView: View {
    let shownTheme: ClickyTheme
    let status: PanelHeaderStatus
    let close: () -> Void
    /// The Stop quiz button the state line shows while a quiz runs.
    var stopTheQuiz: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(RadialGradient(colors: [DS.Colors.panelCursorTileTop, DS.Colors.panelCursorTileBottom], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 34))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                // A new theme's cursor Pops in: each theme is its own view, so the change is a removal and an insertion.
                SettingsDialCustomCursor(
                    customTheme: shownTheme,
                    picture: shownTheme.usesPicture ? CustomThemePictureCache.image(forThemeID: shownTheme.id) : nil,
                    longestSide: 22
                )
                .id(shownTheme.id)
                .transition(reduceMotion ? .opacity : .scale(scale: DS.Move.popStartScale).combined(with: .opacity))
            }
            .frame(width: 44, height: 44)
            .animation(DS.Move.pop.animation(reduceMotionIsOn: reduceMotion), value: shownTheme.id)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Clicky")
                    .font(DS.TypeScale.voice.font)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                // One spoken line, except that a running quiz's Stop quiz button stays a button VoiceOver can press.
                statusLine
                    .accessibilityElement(children: status.hasAButton ? .contain : .ignore)
                    .accessibilityLabel(status.spokenText)
            }
            Spacer(minLength: 0)
            PanelCloseButton(close: close)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .ready:
            HStack(spacing: 4) {
                Text("Ready · hold")
                PanelKeyCap(key: "⌃")
                PanelKeyCap(key: "⌥")
                Text("to talk")
            }
            .font(DS.TypeScale.caption.font)
            .foregroundColor(DS.Colors.textSecondary)
        case .quizRunning(let progress):
            HStack(spacing: 4) {
                Text(progress.stateLineText)
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .accessibilityHidden(true)
                PanelButton(title: "Stop quiz", prominence: .quiet, action: stopTheQuiz)
            }
        default:
            Text(status.spokenText)
                .font(DS.TypeScale.caption.font)
                .foregroundColor(status.isAProblem ? DS.Colors.warningText : DS.Colors.textSecondary)
        }
    }
}

private struct PanelCloseButton: View {
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isHovered ? DS.Colors.surface4 : DS.Colors.surface2))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PanelPressStyle())
        .hoverAndPointer { isHovered = $0 }
        .panelKeyboardControl(cornerRadius: 13, action: close)
        .accessibilityLabel("Close")
    }
}

/// A page's top bar: a back button to the home and the page's title.
private struct PanelPageTitleBar: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PanelButton(title: "Home", systemImageName: "chevron.left", prominence: .quiet, action: back)
            Text(title)
                .font(DS.TypeScale.title.font)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// A small upper-case label on the left of a row and its control on the right.
private struct PanelSectionLabel<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(DS.TypeScale.caption.font)
                .fontWeight(.semibold)
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Banner

/// A problem under the header: a red box with a title, a caption, and one button.
struct PanelBannerView: View {
    let words: PanelProblemBannerWords
    let run: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(words.title)
                    .font(DS.TypeScale.title.font)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(words.caption)
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            PanelButton(title: words.buttonTitle, prominence: .secondary, action: run)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.destructiveSurface))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DS.Colors.destructiveEdge, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Agents

/// The agents row: a chip for each agent with a disc, its words, and Open list. A chip that holds the keyboard focus puts
/// the focus ring and the peek card on its disc in the menu bar, and a picked chip shows its disc menu's actions here.
private struct PanelAgentsSection: View {
    let summary: PanelAgentsSummary
    let agents: [BackgroundAgent]
    @ObservedObject var store: BackgroundAgentStore
    @Binding var selectedAgentID: UUID?
    let companionManager: CompanionManager

    /// At most four chips fit beside the words. The rest are in the list.
    private static let mostChips = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(agents.prefix(Self.mostChips), id: \.id) { agent in
                        PanelAgentChip(
                            agent: agent,
                            isWaitingForApproval: store.agentIDsWaitingForApproval.contains(agent.id),
                            accessibilityLabel: agentDiscAccessibilityLabel(
                                agentName: agent.displayName,
                                peekContent: agentTokenPeekContent(
                                    for: agent,
                                    approvalCapability: store.approvalCapabilitiesByAgentID[agent.id],
                                    isWaitingForApproval: store.agentIDsWaitingForApproval.contains(agent.id),
                                    at: Date()
                                )
                            ),
                            isPicked: selectedAgentID == agent.id,
                            // Picking always shows the chip's actions, since a click also gives the chip the focus.
                            pick: { selectedAgentID = agent.id },
                            focusChanged: { hasTheFocus, theKeyboardMovedIt in
                                if hasTheFocus {
                                    selectedAgentID = agent.id
                                    // The disc takes the panel's ring only when the keyboard moved the focus, as every
                                    // control does.
                                    if theKeyboardMovedIt { companionManager.showTheKeyboardFocusOnTheAgentDisc(of: agent.id) }
                                } else {
                                    companionManager.endTheKeyboardFocusOnTheAgentDisc(of: agent.id)
                                }
                            }
                        )
                    }
                }
                PanelAgentsOpenListButton(summary: summary, open: { companionManager.openTheAgentListFromThePanel() })
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

            if let selectedAgentID, let pickedAgent = agents.first(where: { $0.id == selectedAgentID }) {
                pickedAgentActions(pickedAgent)
            }
        }
    }

    private func pickedAgentActions(_ pickedAgent: BackgroundAgent) -> some View {
        let peekContent = agentTokenPeekContent(
            for: pickedAgent,
            approvalCapability: store.approvalCapabilitiesByAgentID[pickedAgent.id],
            isWaitingForApproval: store.agentIDsWaitingForApproval.contains(pickedAgent.id),
            at: Date()
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text(peekContent.title)
                .font(DS.TypeScale.title.font)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Text(peekContent.caption)
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                ForEach(Array(companionManager.agentDiscMenuItemsForThePanel(agentID: pickedAgent.id).enumerated()), id: \.offset) { _, menuItem in
                    PanelButton(title: menuItem.title, prominence: menuItem == .cancelAgent ? .quiet : .secondary) {
                        companionManager.runTheAgentDiscMenuItemFromThePanel(menuItem, agentID: pickedAgent.id)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for \(peekContent.title)")
    }
}

/// One agent's disc in the agents row, which the keyboard can reach as it cannot reach the disc in the menu bar.
private struct PanelAgentChip: View {
    let agent: BackgroundAgent
    let isWaitingForApproval: Bool
    let accessibilityLabel: String
    let isPicked: Bool
    let pick: () -> Void
    /// The chip gained or lost the focus, and whether the keyboard moved it.
    let focusChanged: (_ hasTheFocus: Bool, _ theKeyboardMovedIt: Bool) -> Void

    @State private var isHovered = false
    @FocusState private var hasTheFocus: Bool
    @State private var showsTheFocusRing = false

    var body: some View {
        Button(action: pick) {
            AgentTokenDiscView(agent: agent, isWaitingForApproval: isWaitingForApproval, isHovered: isHovered)
                // A paused agent's chip grays, as its disc in the menu bar does before it folds into the paused disc.
                .grayscale(agent.pausedAt != nil ? 1 : 0)
                .animation(.easeOut(duration: AgentTokenGather.graySeconds), value: agent.pausedAt != nil)
                .frame(width: AgentTokenMetrics.discDiameter + 4, height: AgentTokenMetrics.discDiameter + 4)
                .background(Circle().fill(isPicked ? Color.white.opacity(0.12) : .clear).padding(-2))
                .contentShape(Circle())
        }
        .buttonStyle(PanelPressStyle())
        .hoverAndPointer { isHovered = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($hasTheFocus)
        .onKeyPress(keys: [.return, .space]) { _ in
            pick()
            return .handled
        }
        .onChange(of: hasTheFocus) { _, isNowFocused in
            showsTheFocusRing = isNowFocused && theKeyboardMovedTheFocus()
            focusChanged(isNowFocused, showsTheFocusRing)
        }
        .panelKeyboardFocusRing(isShowing: showsTheFocusRing && hasTheFocus, cornerRadius: (AgentTokenMetrics.discDiameter + 4) / 2)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows what you can do with this agent")
    }
}

/// "2 working · 1 result waiting ›", which opens the agent list.
private struct PanelAgentsOpenListButton: View {
    let summary: PanelAgentsSummary
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Text(summary.mainText)
                    .font(DS.TypeScale.title.font)
                    .foregroundColor(DS.Colors.textPrimary)
                if let secondaryText = summary.secondaryText {
                    Text("· \(secondaryText)")
                        .font(DS.TypeScale.caption.font)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            }
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(isHovered ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .hoverAndPointer { isHovered = $0 }
        .panelKeyboardControl(cornerRadius: 6, action: open)
        .accessibilityLabel([summary.mainText, summary.secondaryText].compactMap { $0 }.joined(separator: ", ") + ". Open the agent list")
    }
}

// MARK: - Model

/// Sonnet and Opus, each with a word for what it is good at, as a two-option radio group.
private struct PanelModelPicker: View {
    let selectedModelID: String
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            PanelModelOption(label: "Sonnet", detail: "fast", isSelected: selectedModelID == ClaudeVoiceModel.sonnetModelID) {
                select(ClaudeVoiceModel.sonnetModelID)
            }
            PanelModelOption(label: "Opus", detail: "deeper", isSelected: selectedModelID == ClaudeVoiceModel.opusModelID) {
                select(ClaudeVoiceModel.opusModelID)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Colors.surface2))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model")
    }
}

private struct PanelModelOption: View {
    let label: String
    let detail: String
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                Text(label)
                    .font(DS.TypeScale.caption.font)
                    .fontWeight(.semibold)
                    .foregroundColor(isSelected || isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                Text(detail)
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface4 : Color.white.opacity(isHovered ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .hoverAndPointer { isHovered = $0 }
        .panelKeyboardControl(cornerRadius: 7, action: select)
        .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: isSelected)
        .accessibilityLabel("\(label), \(detail)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#if DEBUG
/// Prints the full JSON of every voice command reply and tool result to the app log.
private struct PanelDebugToolCallLoggingRow: View {
    let accentColor: Color
    @AppStorage(CompanionManager.logsVoiceToolCallJSONDefaultsKey) private var logsVoiceToolCallJSON = false

    var body: some View {
        HStack {
            Text("Log tool call JSON (Debug)")
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            PanelSwitch(accessibilityLabel: "Log tool call JSON", isOn: $logsVoiceToolCallJSON, accentColor: accentColor)
        }
    }
}
#endif

// MARK: - Setup checklist

/// The six setup steps: what Clicky captures and where it goes, a bar that fills as steps finish, one row per step, and
/// a first question to try once every required step is done.
struct SetupChecklistView: View {
    let stepStates: [(step: SetupStep, state: SetupStepState)]
    /// A first run shows the "Set up Clicky" heading and the Start button.
    let isAFirstRun: Bool
    let isRequestingTheScreenTest: Bool
    let shownTheme: ClickyTheme
    let runStep: (SetupStep, SetupStepAction) -> Void
    let start: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pointingCursorNamespace

    private var nextStep: SetupStep? { nextSetupStep(in: stepStates) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if isAFirstRun {
                    Text("Set up Clicky")
                        .font(DS.TypeScale.headline.font)
                        .foregroundColor(DS.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(setupCaptureDisclosure)
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupProgressBar(fraction: setupProgressFraction(of: stepStates))

            VStack(spacing: 6) {
                ForEach(Array(stepStates.enumerated()), id: \.element.step) { stepIndex, stepAndState in
                    SetupStepRow(
                        step: stepAndState.step,
                        stepNumber: stepIndex + 1,
                        stepCount: stepStates.count,
                        state: stepAndState.state,
                        isNext: stepAndState.step == nextStep,
                        isRunning: stepAndState.step == .screenTest && isRequestingTheScreenTest,
                        shownTheme: shownTheme,
                        pointingCursorNamespace: pointingCursorNamespace,
                        run: { action in runStep(stepAndState.step, action) }
                    )
                }
            }
            .animation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion), value: nextStep)

            if everyRequiredSetupStepIsDone(stepStates) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("All set. Try a first question:")
                        .font(DS.TypeScale.title.font)
                        .foregroundColor(DS.Colors.textPrimary)
                    // One run of text, with no-break spaces inside the quoted question, so it never wraps inside the quote.
                    (Text("Open a YouTube video, hold ") + Text("⌃ ⌥").fontWeight(.bold).foregroundColor(DS.Colors.textPrimary) + Text(", and ask \u{201C}what\u{00A0}is\u{00A0}this?\u{201D}"))
                        .font(DS.TypeScale.caption.font)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Open a YouTube video, hold Control and Option, and ask what is this?")
                    if isAFirstRun {
                        PanelButton(title: "Start Clicky", prominence: .primary, accentColor: shownTheme.cursorColor, action: start)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.setupAllSetSurface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Colors.setupAllSetEdge, lineWidth: 1))
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion), value: everyRequiredSetupStepIsDone(stepStates))
    }
}

/// The bar that fills with the share of steps done, on the Glide move.
private struct SetupProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { barProxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.setupTrack)
                Capsule()
                    .fill(DS.Colors.success)
                    .frame(width: barProxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .animation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// One step: its number (a drawn check once done, a cross when turned off), its name and job, and its buttons.
private struct SetupStepRow: View {
    let step: SetupStep
    let stepNumber: Int
    let stepCount: Int
    let state: SetupStepState
    /// The step the checklist points at: its row is lit and the cursor points at its button.
    let isNext: Bool
    let isRunning: Bool
    let shownTheme: ClickyTheme
    let pointingCursorNamespace: Namespace.ID
    let run: (SetupStepAction) -> Void

    private var isTurnedOff: Bool { state == .turnedOff }

    var body: some View {
        HStack(spacing: 10) {
            SetupStepMark(stepNumber: stepNumber, state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(DS.TypeScale.title.font)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(isTurnedOff ? setupTurnedOffCaption(for: step) : (state == .needsChromeOpen ? "Open Chrome to check or allow" : step.purpose))
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(isTurnedOff ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(rowFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(rowEdge, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(stepNumber) of \(stepCount), \(step.title), \(spokenState)")
    }

    private var spokenState: String {
        switch state {
        case .done: return "done"
        case .notNeeded: return "not needed"
        case .toDo: return isNext ? "next" : "to do"
        case .turnedOff: return "turned off"
        case .needsChromeOpen: return "needs Chrome open"
        }
    }

    private var rowFill: Color {
        if isTurnedOff { return DS.Colors.destructiveSurface }
        return isNext ? DS.Colors.setupNextStepSurface : .clear
    }

    private var rowEdge: Color {
        if isTurnedOff { return DS.Colors.destructiveEdge }
        return isNext ? DS.Colors.setupNextStepEdge : .clear
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .done:
            Text("Done")
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.success)
        case .notNeeded:
            Text("Not needed")
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textTertiary)
        default:
            let buttons = setupStepButtons(for: step, in: state)
            HStack(spacing: 6) {
                if isNext {
                    // The theme's cursor points at the next button, and glides to the next row when this step is done.
                    SettingsDialCustomCursor(
                        customTheme: shownTheme,
                        picture: shownTheme.usesPicture ? CustomThemePictureCache.image(forThemeID: shownTheme.id) : nil,
                        longestSide: 16
                    )
                    // The triangle rests at its pointer angle, so it turns the rest of the way to point right at the button.
                    .rotationEffect(.degrees(shownTheme.cursorFacing == .pointerAngle ? 125 : 0))
                        .matchedGeometryEffect(id: "pointingCursor", in: pointingCursorNamespace)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { buttonIndex, button in
                        PanelButton(
                            title: isRunning ? "Testing…" : button.title,
                            prominence: buttonIndex == 0 && (isNext || isTurnedOff) ? (isNext ? .primary : .secondary) : (buttonIndex == 0 ? .secondary : .quiet),
                            accentColor: shownTheme.cursorColor,
                            action: { run(button.action) }
                        )
                        .disabled(isRunning)
                    }
                }
            }
        }
    }
}

/// The circle at the start of a step's row: its number, a check drawn in 220 ms when it is done, or a red cross.
private struct SetupStepMark: View {
    let stepNumber: Int
    let state: SetupStepState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawnShareOfTheCheck: CGFloat

    /// A done step's number turns into a check drawn in this long, as the spec says.
    private static let secondsToDrawTheCheck = 0.22

    init(stepNumber: Int, state: SetupStepState) {
        self.stepNumber = stepNumber
        self.state = state
        // A step that is already done when the row appears shows its whole check.
        _drawnShareOfTheCheck = State(initialValue: state.countsAsDone ? 1 : 0)
    }

    var body: some View {
        ZStack {
            Circle().fill(circleFill)
            if state.countsAsDone {
                SetupCheckShape()
                    .trim(from: 0, to: drawnShareOfTheCheck)
                    .stroke(DS.Colors.success, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 11)
            } else if state == .turnedOff {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.destructiveText)
            } else {
                Text("\(stepNumber)")
                    .font(DS.TypeScale.caption.font)
                    .fontWeight(.bold)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(width: 22, height: 22)
        .onChange(of: state.countsAsDone) { _, isNowDone in
            guard isNowDone else {
                drawnShareOfTheCheck = 0
                return
            }
            // The number turns into a check drawn in 220 ms. With Reduce Motion on it shows whole.
            if reduceMotion {
                drawnShareOfTheCheck = 1
            } else {
                drawnShareOfTheCheck = 0
                withAnimation(.easeOut(duration: Self.secondsToDrawTheCheck)) { drawnShareOfTheCheck = 1 }
            }
        }
        .accessibilityHidden(true)
    }

    private var circleFill: Color {
        if state.countsAsDone { return DS.Colors.setupDoneCircle }
        if state == .turnedOff { return DS.Colors.setupTurnedOffCircle }
        return DS.Colors.setupTrack
    }
}

/// A check mark in a square, drawn from its short arm to the end of its long one, so trimming it draws it.
struct SetupCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var checkPath = Path()
        checkPath.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.52))
        checkPath.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.72))
        checkPath.addLine(to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.28))
        return checkPath
    }
}

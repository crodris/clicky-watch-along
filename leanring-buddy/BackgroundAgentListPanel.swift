//
//  BackgroundAgentListPanel.swift
//  leanring-buddy
//
//  The clickable list of background agents. The Agents slice of the settings dial (shift + option) opens it next to the
//  mouse, and a click on an agent token beside the notch opens it under that token with the agent's row expanded.
//  It is a borderless, nonactivating panel that never becomes key, so Chrome keeps the keyboard while the learner
//  clicks a row. It closes on Escape, on a click outside, or on a second click on the token it opened from.
//
//  The list is a Tether Card. It Glides out of its origin (the disc it was opened from, or the cursor) on the shared
//  carrier panel with a tether line, and closes back into it at 0.7x (`TetherCarrier`). With Reduce Motion on it crossfades
//  in place instead. The window is larger than the Card by a transparent margin (`AgentListWindowMargins`), where the
//  Card's shadow draws.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Placement

/// The panel's bottom-left corner when its top-left corner should sit at `anchorTopLeft`, moved to keep the whole panel
/// inside the screen's visible frame. Points are in AppKit's screen coordinates, where y grows upward.
func agentListPanelOrigin(anchorTopLeft: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
    let originX = min(max(anchorTopLeft.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
    let originY = min(max(anchorTopLeft.y - panelSize.height, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
    return CGPoint(x: originX, y: originY)
}

/// The transparent margin around the list's Card inside its window, where the Card's two-layer shadow draws (radius 24 and
/// a 14 point drop, so it reaches farthest below). A shadow cut off by the window's edge shows as a hard line.
/// Everything that places the list places its Card: the window is the Card grown by these margins, and the margins may
/// reach past the screen's edge, where the shadow is out of sight anyway.
enum AgentListWindowMargins {
    static let top: CGFloat = 12
    static let leading: CGFloat = 24
    static let bottom: CGFloat = 40
    static let trailing: CGFloat = 24

    static var horizontal: CGFloat { leading + trailing }
    static var vertical: CGFloat { top + bottom }

    /// The window's top-left corner when the Card's top-left corner is at `cardTopLeft`, in AppKit's screen coordinates.
    static func windowTopLeft(forCardTopLeft cardTopLeft: CGPoint) -> CGPoint {
        CGPoint(x: cardTopLeft.x - leading, y: cardTopLeft.y + top)
    }

    /// The Card's frame inside a window frame: the window without its margins. A click in the margin is outside the Card.
    static func cardFrame(inWindowFrame windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + leading,
            y: windowFrame.minY + bottom,
            width: windowFrame.width - horizontal,
            height: windowFrame.height - vertical
        )
    }

    /// The frame that keeps the window's Card inside `visibleFrame` when the window is kept inside it, which is how
    /// `agentListPanelOrigin` clamps a panel.
    static func frameToKeepTheWindowIn(forCardVisibleFrame visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.minX - leading,
            y: visibleFrame.minY - bottom,
            width: visibleFrame.width + horizontal,
            height: visibleFrame.height + vertical
        )
    }

    /// The window's frame for a Card whose top-left corner should be at `cardTopLeft` and a window `windowSize` large, moved
    /// to keep the Card inside `visibleFrame`.
    static func windowFrame(cardTopLeft: CGPoint, windowSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let windowOrigin = agentListPanelOrigin(
            anchorTopLeft: windowTopLeft(forCardTopLeft: cardTopLeft),
            panelSize: windowSize,
            visibleFrame: frameToKeepTheWindowIn(forCardVisibleFrame: visibleFrame)
        )
        return CGRect(origin: windowOrigin, size: windowSize)
    }
}

/// Places a panel again with its new size each time it resizes. The hosting view grows the window from its top-left corner
/// as the SwiftUI content grows, and the size the content reports can be 0 while the window starts with no height, so a
/// card that opened low on the screen grew past its bottom edge, with the studio card's Save and Close buttons off screen.
/// Placing it again after each resize keeps it inside `visibleFrame`, by the same rule as the first placement.
/// The anchor and the visible frame are read at each resize from the controller, which sets them each time it opens.
func keepThePanelOnScreenAsItResizes(
    _ panel: NSPanel,
    currentPlacement: @escaping @MainActor () -> (anchorTopLeft: CGPoint, visibleFrame: CGRect)
) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak panel] _ in
        MainActor.assumeIsolated {
            guard let panel else { return }
            let placement = currentPlacement()
            let placedOrigin = agentListPanelOrigin(
                anchorTopLeft: placement.anchorTopLeft,
                panelSize: panel.frame.size,
                visibleFrame: placement.visibleFrame
            )
            if panel.frame.origin != placedOrigin {
                panel.setFrameOrigin(placedOrigin)
            }
        }
    }
}

/// Where the list opens for an approval request: the first corner around the mouse whose panel, at its tallest and
/// after it is kept on screen, does not cover the pointer, so a click the learner aimed at the page cannot be taken as
/// Yes. It returns the panel's top-left corner, the anchor `agentListPanelOrigin` takes.
func approvalListAnchorTopLeft(mouseLocation: CGPoint, panelSize: CGSize, visibleFrame: CGRect, gapFromTheMouse: CGFloat) -> CGPoint {
    let leftOfTheMouse = mouseLocation.x - gapFromTheMouse - panelSize.width
    let rightOfTheMouse = mouseLocation.x + gapFromTheMouse
    let belowTheMouse = mouseLocation.y - gapFromTheMouse
    let aboveTheMouse = mouseLocation.y + gapFromTheMouse + panelSize.height
    let candidateAnchors = [
        CGPoint(x: rightOfTheMouse, y: belowTheMouse),
        CGPoint(x: leftOfTheMouse, y: belowTheMouse),
        CGPoint(x: rightOfTheMouse, y: aboveTheMouse),
        CGPoint(x: leftOfTheMouse, y: aboveTheMouse),
    ]
    for candidateAnchor in candidateAnchors {
        let origin = agentListPanelOrigin(anchorTopLeft: candidateAnchor, panelSize: panelSize, visibleFrame: visibleFrame)
        if !CGRect(origin: origin, size: panelSize).contains(mouseLocation) {
            return candidateAnchor
        }
    }
    return candidateAnchors[0]
}

/// How far apart two seen ranges of the approval summary may be, in points, and still count as touching. Layout and
/// scrolling land on fractions of a point, so two ranges that meet can leave a sliver. A text line is about 13 points
/// tall, so a gap this small never hides one.
private let approvalSummaryRangeGapTolerance: CGFloat = 1

/// Sorts the ranges and joins any that overlap or sit within `approvalSummaryRangeGapTolerance` of each other.
private func mergedApprovalSummaryRanges(_ ranges: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
    var mergedRanges: [ClosedRange<CGFloat>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let lastMergedRange = mergedRanges.last, range.lowerBound <= lastMergedRange.upperBound + approvalSummaryRangeGapTolerance {
            mergedRanges[mergedRanges.count - 1] = lastMergedRange.lowerBound...max(lastMergedRange.upperBound, range.upperBound)
        } else {
            mergedRanges.append(range)
        }
    }
    return mergedRanges
}

/// Whether the ranges of the approval summary that have been inside the scroll area, in the summary's own coordinates
/// (0 is its top, `summaryHeight` its bottom), cover it from top to bottom. A learner who drags straight to the end
/// has seen the bottom but not the middle, so only coverage of the whole height counts as having read it.
func approvalSummaryWasShownWhole(seenRanges: [ClosedRange<CGFloat>], summaryHeight: CGFloat) -> Bool {
    guard summaryHeight > 0, let coveredRange = mergedApprovalSummaryRanges(seenRanges).first else { return false }
    return coveredRange.lowerBound <= approvalSummaryRangeGapTolerance
        && coveredRange.upperBound >= summaryHeight - approvalSummaryRangeGapTolerance
}

/// The part of the approval summary inside the scroll area, in the summary's own coordinates, from where the summary
/// sits in the scroll area's coordinates (`summaryMinY` is 0 at the top and goes negative as the learner scrolls down).
/// Nil when none of it is inside, such as a bounce past the end.
func approvalSummaryRangeInView(summaryMinY: CGFloat, summaryHeight: CGFloat, scrollAreaHeight: CGFloat) -> ClosedRange<CGFloat>? {
    let topInView = max(0, -summaryMinY)
    let bottomInView = min(summaryHeight, -summaryMinY + scrollAreaHeight)
    guard topInView <= bottomInView else { return nil }
    return topInView...bottomInView
}

/// The ranges of one approval request's summary that the card has had inside its scroll area. Each range is tagged
/// with the request it was seen for, so a card that starts showing another request starts with none.
struct ApprovalSummarySeenRanges: Equatable {
    private(set) var approvalID: String?
    private(set) var ranges: [ClosedRange<CGFloat>] = []

    mutating func record(_ range: ClosedRange<CGFloat>, forApprovalID newApprovalID: String) {
        if approvalID != newApprovalID {
            approvalID = newApprovalID
            ranges = []
        }
        ranges = mergedApprovalSummaryRanges(ranges + [range])
    }
}

// MARK: - Panel

/// A borderless panel that never becomes key or main, so the app under it keeps the keyboard. The agent list and the Theme
/// Studio card both use it.
final class NonKeyFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a panel that is not key would otherwise only be swallowed by AppKit.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Whether the agent list may show a waiting 3D model or experiment, or speak a waiting task answer. A question's scene and
/// speech belong to the question, so, like the voice tools for the same actions (`AppVoiceTool.showReadyModel` and
/// `.hearTaskAnswer`), the list waits until the learner answers or skips an open video quiz question.
func agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: Bool) -> Bool {
    !aVideoQuizQuestionIsOpen
}

/// What a row's buttons do besides cancelling a running agent.
struct AgentListActions {
    let cancelAgent: (UUID) -> Void
    /// Rises the 3D model or experiment that is waiting to be shown.
    let showReadyScene: () -> Void
    /// Speaks the task answer that is waiting to be heard.
    let hearTaskAnswer: () -> Void
    /// Starts a failed agent's work again, once (`BackgroundAgent.canBeTriedAgain`).
    let tryAgain: (UUID) -> Void
    /// Answers a task agent's approval request from the Yes, Always, and No buttons. The desk ignores a click that comes
    /// too soon after the request showed (`HarnessApprovalDesk.answerByClick`).
    let answerApproval: (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
}

/// What the list's rows share with the copy of the list that plays on the carrier panel, so a row the learner expanded
/// stays expanded while the list closes.
@MainActor
final class AgentListUIState: ObservableObject {
    @Published var expandedAgentID: UUID?

    /// Whether the approval card of the list that shows may start the approval desk's one second clock. The list is only
    /// listening from the moment its real panel is on screen until it starts to close, so the copies of the list that play on
    /// the carrier while it opens and closes, and the panel while it is still hidden, never start the clock for a card the
    /// learner cannot see.
    private(set) var deskIsListening = false
    private var hasClosed = false
    /// What the approval card last said about its summary, kept so the report goes out when the list starts listening.
    private var latestReportToTheDesk: (() -> Void)?

    init(expandedAgentID: UUID?) {
        self.expandedAgentID = expandedAgentID
    }

    /// The approval card's report on whether it has shown the whole summary. It reaches the desk now when the list is
    /// listening, and when it starts to.
    func report(toTheDesk report: @escaping () -> Void) {
        guard !hasClosed else { return }
        latestReportToTheDesk = report
        if deskIsListening { report() }
    }

    func startListeningForTheDesk() {
        guard !hasClosed else { return }
        deskIsListening = true
        latestReportToTheDesk?()
    }

    /// The list is closing, for good: it reports nothing and cannot start listening again.
    func stopListeningForTheDesk() {
        hasClosed = true
        deskIsListening = false
        latestReportToTheDesk = nil
    }
}

/// Whether the list's rows rise in as it opens. Only the copy that Glides out of its origin plays it, so the rows rise
/// while the Card grows, and the real list that appears at the landing starts with its rows in place.
enum AgentListEntrance: Equatable {
    case none
    /// Each row rises 40 ms after the one above it.
    case risingRows
}

@MainActor
final class AgentListPanelController {
    static let panelWidth: CGFloat = 300
    static let maximumPanelHeight: CGFloat = 360
    /// The approval card's summary scrolls past this height, so a long one cannot push the rows off the screen.
    static let maximumApprovalSummaryHeight: CGFloat = 200
    /// The rest of the approval card around its summary: the title line, the buttons, the hint, the padding, and the line
    /// under the card.
    static let approvalCardHeightOutsideTheSummary: CGFloat = 110
    /// The list's tallest, with an approval card above the rows.
    static let maximumPanelHeightWithAnApprovalCard: CGFloat = maximumPanelHeight + maximumApprovalSummaryHeight + approvalCardHeightOutsideTheSummary
    private static let gapFromTheMouse: CGFloat = 12
    /// One level above the cursor overlay windows, so the list is never under the cursor.
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    private let store: BackgroundAgentStore
    private let themeSettings: CompanionThemeSettings
    private let actions: AgentListActions
    /// The queue of requests the learner answers with the Yes, Always, and No buttons of the approval card.
    private let approvalDesk: HarnessApprovalDesk
    private var panel: NonKeyFloatingPanel?
    private var clickOutsideMonitor: Any?
    /// Sees a click that lands on the window's own shadow margin, which the global monitor never gets, since the window
    /// server delivers it to this panel.
    private var clickInTheShadowMonitor: Any?
    /// Where the Card's top-left corner sits, fixed when it opens so a row that expands grows the Card downward.
    private var anchorTopLeft: CGPoint = .zero
    private var visibleFrame: CGRect = .zero
    private var resizeObserver: NSObjectProtocol?
    /// The disc the list was opened from, nil when the settings dial opened it, so a second click on the same disc closes it.
    private var discTheListWasOpenedFrom: AgentTokenDiscID?
    private var uiState = AgentListUIState(expandedAgentID: nil)
    /// Where the Card Glides out of and closes back into: the disc it was opened from, or the cursor. Nil when no display
    /// holds it, and the list then crossfades.
    private var glideOrigin: GlideOrigin?
    /// The open Glide, held so a close before it lands can end it where it is.
    private var openingFlight: CarrierFlight?

    private struct GlideOrigin {
        let point: CGPoint
        let displayID: CGDirectDisplayID
    }

    init(store: BackgroundAgentStore, themeSettings: CompanionThemeSettings, approvalDesk: HarnessApprovalDesk, actions: AgentListActions) {
        self.store = store
        self.themeSettings = themeSettings
        self.approvalDesk = approvalDesk
        self.actions = actions
    }

    var isOpen: Bool { panel != nil }

    /// The settings dial's Agents slice: open next to the mouse with no row expanded, or close when it is already open.
    /// The list Glides out of the mouse, which is where the dial's center was.
    func toggle() {
        if isOpen {
            closeWithGlide()
        } else {
            let mouseLocation = NSEvent.mouseLocation
            let screen = screenUnderTheMouseCursor()
            open(
                anchorTopLeft: CGPoint(x: mouseLocation.x + Self.gapFromTheMouse, y: mouseLocation.y - Self.gapFromTheMouse),
                visibleFrame: screen?.visibleFrame ?? .zero,
                initiallyExpandedAgentID: nil,
                glideOriginPoint: mouseLocation,
                screen: screen
            )
        }
    }

    /// A click on an agent token: open the list under that disc with the agent's row expanded, and "+N" with none.
    /// A click on the disc the list is already open from closes it, and a click on another disc, including the same
    /// agent's disc on another display, moves it there. The list Glides out of the disc's center.
    func toggle(from discID: AgentTokenDiscID, discPanelFrame: CGRect, on screen: NSScreen) {
        let discWasAlreadyOpen = discTheListWasOpenedFrom == discID
        let listWasOpen = isOpen
        if listWasOpen && discWasAlreadyOpen {
            closeWithGlide()
            return
        }
        // Moving to another disc leaves no time for a close, which would play toward the disc it left.
        close()
        let agentIDToExpand: UUID?
        switch discID.tokenSlot {
        case .agent(let agentID): agentIDToExpand = agentID
        case .overflow: agentIDToExpand = nil
        }
        open(
            anchorTopLeft: CGPoint(x: discPanelFrame.minX, y: discPanelFrame.minY - Self.gapFromTheMouse / 4),
            visibleFrame: screen.visibleFrame,
            initiallyExpandedAgentID: agentIDToExpand,
            glideOriginPoint: CGPoint(x: discPanelFrame.midX, y: discPanelFrame.midY),
            screen: screen
        )
        discTheListWasOpenedFrom = discID
    }

    private func open(anchorTopLeft: CGPoint, visibleFrame: CGRect, initiallyExpandedAgentID: UUID?, glideOriginPoint: CGPoint, screen: NSScreen?) {
        guard panel == nil else { return }
        self.visibleFrame = visibleFrame
        self.anchorTopLeft = anchorTopLeft
        discTheListWasOpenedFrom = nil
        uiState = AgentListUIState(expandedAgentID: initiallyExpandedAgentID)
        glideOrigin = screen.map { GlideOrigin(point: glideOriginPoint, displayID: $0.displayID) }

        let hostingView = makeHostingView(entrance: .none)
        let initialSize = CGSize(
            width: Self.panelWidth + AgentListWindowMargins.horizontal,
            height: min(hostingView.fittingSize.height, Self.maximumPanelHeightWithAnApprovalCard + AgentListWindowMargins.vertical)
        )

        let agentListPanel = NonKeyFloatingPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        agentListPanel.isOpaque = false
        agentListPanel.backgroundColor = .clear
        agentListPanel.hasShadow = false
        agentListPanel.level = Self.panelLevel
        agentListPanel.hidesOnDeactivate = false
        agentListPanel.isReleasedWhenClosed = false
        agentListPanel.isExcludedFromWindowsMenu = true
        agentListPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        agentListPanel.contentView = hostingView
        panel = agentListPanel
        resizeObserver = keepThePanelOnScreenAsItResizes(agentListPanel) { [weak self] in
            self?.placementForTheWindow() ?? (.zero, .zero)
        }
        resizePanel(to: initialSize)
        showThePanel(agentListPanel)
        installClickOutsideMonitor()
    }

    /// Shows the list: it Glides out of its origin on the carrier and the real panel appears at the landing, or, with Reduce
    /// Motion on or no display for the origin, the panel crossfades in place. Never makeKeyAndOrderFront, which would take
    /// the keyboard from Chrome.
    private func showThePanel(_ agentListPanel: NonKeyFloatingPanel) {
        guard let glideOrigin, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            agentListPanel.alphaValue = 0
            agentListPanel.orderFrontRegardless()
            uiState.startListeningForTheDesk()
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = DS.Move.fadeSeconds
                agentListPanel.animator().alphaValue = 1
            }
            return
        }
        let panelFrame = agentListPanel.frame
        openingFlight = TetherCarrier.shared.play(
            .glideFromOrigin(glideOrigin.point, into: panelFrame),
            carrying: carriedListView(entrance: .risingRows, windowSize: panelFrame.size),
            onDisplay: glideOrigin.displayID,
            tetherColor: NSColor(themeSettings.shownTheme.cursorColor),
            onLanded: { [weak self, weak agentListPanel] in
                // A list closed before the landing is no longer this panel.
                guard let self, let agentListPanel, self.panel === agentListPanel else { return }
                self.openingFlight = nil
                agentListPanel.orderFrontRegardless()
                self.uiState.startListeningForTheDesk()
            }
        )
    }

    private func makeHostingView(entrance: AgentListEntrance) -> FirstMouseHostingView<AgentListView> {
        let hostingView = FirstMouseHostingView(rootView: makeListView(entrance: entrance, reportsItsSize: true))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        return hostingView
    }

    private func makeListView(entrance: AgentListEntrance, reportsItsSize: Bool) -> AgentListView {
        AgentListView(
            store: store,
            themeSettings: themeSettings,
            approvalDesk: approvalDesk,
            actions: actions,
            uiState: uiState,
            entrance: entrance
        ) { [weak self] contentSize in
            guard reportsItsSize else { return }
            self?.resizePanel(to: contentSize)
        }
    }

    /// The list as the carrier carries it: the same view at the window's size, which reports no size back to the panel.
    private func carriedListView(entrance: AgentListEntrance, windowSize: CGSize) -> some View {
        makeListView(entrance: entrance, reportsItsSize: false)
            .frame(width: windowSize.width, height: windowSize.height, alignment: .top)
    }

    /// An approval request arrived: open the list next to the mouse with the requesting agent's row expanded. An open
    /// list stays where it is, since its approval card shows the oldest request by itself. It Glides out of the cursor.
    func openForAnApprovalRequest(fromAgentID agentID: UUID) {
        guard !isOpen else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = screenUnderTheMouseCursor()
        let visibleFrame = screen?.visibleFrame ?? .zero
        open(
            anchorTopLeft: approvalListAnchorTopLeft(
                mouseLocation: mouseLocation,
                panelSize: CGSize(width: Self.panelWidth, height: Self.maximumPanelHeightWithAnApprovalCard),
                visibleFrame: visibleFrame,
                gapFromTheMouse: Self.gapFromTheMouse
            ),
            visibleFrame: visibleFrame,
            initiallyExpandedAgentID: agentID,
            glideOriginPoint: agentTokenServeStartPoint(mouseLocation: mouseLocation),
            screen: screen
        )
    }

    /// Closes the list at once, with no move. Opening another surface over it, and the app stopping, use this.
    func close() {
        let closingPanel = tearDownTheOpenList()
        closingPanel?.orderOut(nil)
        // Dropping the view stops the running agents' clocks, which tick only while the list is open.
        closingPanel?.contentView = nil
    }

    /// Closes the list back into its origin: the Card shrinks into the disc or cursor it opened from at 0.7x of the Glide,
    /// with the tether line, or, with Reduce Motion on, crossfades out in place.
    func closeWithGlide() {
        let origin = glideOrigin
        let closingFrame = panel?.frame
        let closingUIState = uiState
        guard let closingPanel = tearDownTheOpenList(), let closingFrame else { return }
        let reduceMotionIsOn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let origin, !reduceMotionIsOn else {
            NSAnimationContext.runAnimationGroup({ animationContext in
                animationContext.duration = DS.Move.fadeSeconds
                closingPanel.animator().alphaValue = 0
            }, completionHandler: {
                closingPanel.orderOut(nil)
                closingPanel.contentView = nil
            })
            return
        }
        // The carrier draws the Card for the move, so the real panel goes at once.
        closingPanel.orderOut(nil)
        closingPanel.contentView = nil
        TetherCarrier.shared.play(
            .glideClose(from: closingFrame, into: origin.point),
            carrying: AgentListView(
                store: store,
                themeSettings: themeSettings,
                approvalDesk: approvalDesk,
                actions: actions,
                uiState: closingUIState,
                entrance: .none,
                onContentSizeChange: { _ in }
            )
            .frame(width: closingFrame.width, height: closingFrame.height, alignment: .top),
            onDisplay: origin.displayID,
            tetherColor: NSColor(themeSettings.shownTheme.cursorColor),
            onLanded: {}
        )
    }

    /// Marks the list closed and removes what watches for clicks and resizes, and returns the panel for the caller to hide.
    private func tearDownTheOpenList() -> NonKeyFloatingPanel? {
        discTheListWasOpenedFrom = nil
        // The copy that plays while the list closes shares this state, so it reports nothing to the desk.
        uiState.stopListeningForTheDesk()
        approvalDesk.theCardHasNotShownTheWholeSummary()
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        if let clickInTheShadowMonitor {
            NSEvent.removeMonitor(clickInTheShadowMonitor)
            self.clickInTheShadowMonitor = nil
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        // A Glide still playing ends where it is, so its tether and copy of the list never outlast the list.
        let flightToEnd = openingFlight
        openingFlight = nil
        let closingPanel = panel
        panel = nil
        flightToEnd?.landAtOnce()
        return closingPanel
    }

    /// The anchor and visible frame that keep the window's Card where `anchorTopLeft` puts it, for the resize observer.
    private func placementForTheWindow() -> (anchorTopLeft: CGPoint, visibleFrame: CGRect) {
        (
            AgentListWindowMargins.windowTopLeft(forCardTopLeft: anchorTopLeft),
            AgentListWindowMargins.frameToKeepTheWindowIn(forCardVisibleFrame: visibleFrame)
        )
    }

    private func resizePanel(to contentSize: CGSize) {
        guard let panel else { return }
        let windowSize = CGSize(
            width: Self.panelWidth + AgentListWindowMargins.horizontal,
            height: min(contentSize.height, Self.maximumPanelHeightWithAnApprovalCard + AgentListWindowMargins.vertical)
        )
        panel.setFrame(AgentListWindowMargins.windowFrame(cardTopLeft: anchorTopLeft, windowSize: windowSize, visibleFrame: visibleFrame), display: true)
    }

    /// A global monitor sees only clicks that go to other apps, so a click on the Card never closes it. A click in the
    /// window's shadow margin is outside the Card, so it closes the list whether it reaches another app (the global monitor)
    /// or lands on this panel (the local one).
    private func installClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel,
                      !AgentListWindowMargins.cardFrame(inWindowFrame: panel.frame).contains(NSEvent.mouseLocation) else { return }
                self.closeWithGlide()
            }
        }
        clickInTheShadowMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window === panel else { return }
                let clickInTheWindow = event.locationInWindow
                let clickOnTheScreen = CGPoint(x: panel.frame.minX + clickInTheWindow.x, y: panel.frame.minY + clickInTheWindow.y)
                if !AgentListWindowMargins.cardFrame(inWindowFrame: panel.frame).contains(clickOnTheScreen) {
                    self.closeWithGlide()
                }
            }
            return event
        }
    }
}

// MARK: - Hover and pointer

/// This panel never becomes key, so its rows get hover and the pointing hand from an always-active tracking area
/// instead of SwiftUI's hover or cursor rects, the same way LiveSceneWebView gets mouse moves.
private final class HoverAndPointerNSView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onHoverChange?(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct HoverAndPointerView: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverAndPointerNSView {
        let hoverAndPointerView = HoverAndPointerNSView()
        hoverAndPointerView.onHoverChange = onHoverChange
        return hoverAndPointerView
    }

    func updateNSView(_ nsView: HoverAndPointerNSView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }
}

extension View {
    /// Shows the pointing hand over this view and reports whether the mouse is over it. A disabled control passes
    /// `isEnabled: false`, so it keeps the arrow and never looks clickable.
    func hoverAndPointer(isEnabled: Bool = true, _ onHoverChange: @escaping (Bool) -> Void) -> some View {
        overlay {
            if isEnabled {
                HoverAndPointerView(onHoverChange: onHoverChange)
            }
        }
    }
}

// MARK: - Live line

/// What the line under a row's title says, and how it reads.
nonisolated struct AgentListLiveLine: Equatable {
    enum Tone: Equatable {
        case normal
        /// The agent waits for the learner's OK.
        case needsYou
        case failure
        case quiet
    }

    let text: String
    let tone: Tone
}

/// The line under a row's title: what the agent is doing now, its own step text and the site it reads, or why it stopped.
/// Nil for a row with nothing to add, such as a finished study guide, whose subject says what it is.
nonisolated func agentListLiveLine(for agent: BackgroundAgent, approvalState: AgentListApprovalState) -> AgentListLiveLine? {
    if let approvalStatusText = approvalState.rowStatusText {
        return AgentListLiveLine(text: approvalStatusText, tone: .needsYou)
    }
    switch agent.phase {
    case .running:
        guard let currentStepIndex = agent.stepStatuses.firstIndex(of: .current), agent.stepNames.indices.contains(currentStepIndex) else { return nil }
        let currentStepText = agent.stepNames[currentStepIndex]
        guard let readingHost = agent.readingHost, !readingHost.isEmpty else {
            return AgentListLiveLine(text: currentStepText, tone: .normal)
        }
        return AgentListLiveLine(text: "\(currentStepText) · \(readingHost)", tone: .normal)
    case .finished:
        guard agent.resultIsWaitingToBeDelivered else { return nil }
        switch agent.finishedResult {
        case .readyScene: return AgentListLiveLine(text: agent.kind == .experiment ? "Experiment ready to show" : "Model ready to show", tone: .normal)
        case .answer: return AgentListLiveLine(text: "Answer ready to hear", tone: .normal)
        case .notionPage, nil: return nil
        }
    case .failed(let reason):
        return AgentListLiveLine(text: reason, tone: .failure)
    case .cancelled:
        return AgentListLiveLine(text: "Cancelled", tone: .quiet)
    }
}

/// Whether a failed agent's work may start again now, by the rules the voice tools that start it keep: nothing starts while a
/// quiz question is open, one experiment builds at a time and none starts while one is on screen, and a 3D model is built
/// from a video in front. `aVideoIsInFront` only matters for a 3D model.
nonisolated func backgroundAgentMayBeTriedAgain(
    agentKind: BackgroundAgentKind,
    aQuizQuestionIsOpen: Bool,
    experimentRequestStep: ExperimentRequestStep,
    anExperimentIsOnScreen: Bool,
    aVideoIsInFront: Bool
) -> Bool {
    guard !aQuizQuestionIsOpen else { return false }
    switch agentKind {
    case .experiment: return experimentRequestStep == .startBuilding && !anExperimentIsOnScreen
    case .threeDModel: return aVideoIsInFront
    case .studyGuide, .studyGuideUpdate, .task: return true
    }
}

/// What the list's header counts: the agents running, and the agents that wait for the learner's OK.
nonisolated func agentListHeaderCounts(runningAgentCount: Int, agentsNeedingAnOKCount: Int) -> (running: String, needsYou: String?) {
    ("\(runningAgentCount) running", agentsNeedingAnOKCount > 0 ? "\(agentsNeedingAnOKCount) \(agentsNeedingAnOKCount == 1 ? "needs" : "need") you" : nil)
}

/// The site a link points to, for a row's live line: its host in lowercase with a leading "www." cut off. Nil for a link
/// with no host.
nonisolated func agentListHost(ofLink link: String) -> String? {
    guard let host = URL(string: link)?.host?.lowercased(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

// MARK: - List

private struct AgentListSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct AgentListView: View {
    @ObservedObject var store: BackgroundAgentStore
    @ObservedObject var themeSettings: CompanionThemeSettings
    let actions: AgentListActions
    @ObservedObject var approvalDesk: HarnessApprovalDesk
    @ObservedObject var uiState: AgentListUIState
    let onContentSizeChange: (CGSize) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False until the rows have risen, for the copy of the list that plays on the carrier.
    @State private var rowsHaveRisen: Bool

    private static let headerHeight: CGFloat = 40
    /// Each row rises this long after the one above it.
    private static let secondsBetweenRowRises = 0.04

    init(
        store: BackgroundAgentStore,
        themeSettings: CompanionThemeSettings,
        approvalDesk: HarnessApprovalDesk,
        actions: AgentListActions,
        uiState: AgentListUIState,
        entrance: AgentListEntrance,
        onContentSizeChange: @escaping (CGSize) -> Void
    ) {
        self.store = store
        self.themeSettings = themeSettings
        self.approvalDesk = approvalDesk
        self.actions = actions
        self.uiState = uiState
        self.onContentSizeChange = onContentSizeChange
        _rowsHaveRisen = State(initialValue: entrance == .none)
    }

    /// A theme whose agents all wear its accent, such as a team in its jersey color, borders the Card in that color.
    /// Every other theme keeps the Card's own edge.
    private var agentsWearTheAccent: Bool {
        themeSettings.shownTheme.agents.ring == .accent
    }

    /// The theme's name after a small square in its accent, with every name coming from the theme's file.
    @ViewBuilder private var headerTitle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(themeSettings.shownTheme.cursorColor)
            .frame(width: 10, height: 10)
        // A saved name runs to 24 characters, so it is cut before it pushes the running count off the header.
        Text(themeSettings.shownTheme.name)
            .font(DS.TypeScale.title.font)
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var headerCounts: (running: String, needsYou: String?) {
        agentListHeaderCounts(
            runningAgentCount: store.agents.filter(\.isRunning).count,
            agentsNeedingAnOKCount: Set(approvalDesk.waitingRequests.map(\.taskID)).count
        )
    }

    private func riseAnimation(forRowAt rowIndex: Int) -> Animation? {
        DS.Move.pop.animation(reduceMotionIsOn: reduceMotion)?.delay(Double(rowIndex) * Self.secondsBetweenRowRises)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                headerTitle
                Spacer()
                (Text(headerCounts.running)
                    + Text(headerCounts.needsYou.map { " · \($0)" } ?? "").foregroundColor(DS.Colors.warningText))
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

            // The oldest request sits above the rows, so no scroll position can hide it.
            if let oldestRequest = approvalDesk.oldestWaitingRequest {
                ApprovalCardView(
                    approvalRequest: oldestRequest,
                    agentName: store.agents.first { agent in agent.id == oldestRequest.taskID }.map(\.displayName) ?? "An agent",
                    isAnswering: approvalDesk.answeringApprovalIDs.contains(oldestRequest.approvalID),
                    summaryShownSince: approvalDesk.oldestRequestVisibleSince,
                    answerApproval: actions.answerApproval,
                    summaryWasShownWhole: { summaryWasShownWhole in
                        uiState.report(toTheDesk: {
                            if summaryWasShownWhole {
                                approvalDesk.theCardShowedTheWholeSummary(ofApprovalID: oldestRequest.approvalID)
                            } else {
                                approvalDesk.theCardHasNotShownTheWholeSummary()
                            }
                        })
                    }
                )
                // A new request gets a new card, so its summary is measured from the top.
                .id(oldestRequest.approvalID)

                Rectangle()
                    .fill(DS.Colors.borderSubtle)
                    .frame(height: 1)
            }

            if store.agents.isEmpty {
                Text("No agents yet. Ask for a study guide while a video plays.")
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.agents.enumerated()), id: \.element.id) { rowIndex, agent in
                            let approvalState = agentListApprovalState(forAgentID: agent.id, waitingRequests: approvalDesk.waitingRequests)
                            AgentRowView(
                                agent: agent,
                                resultsMayBeDeliveredNow: agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: store.aVideoQuizQuestionIsOpen),
                                isExpanded: uiState.expandedAgentID == agent.id,
                                approvalState: approvalState,
                                onToggle: {
                                    withAnimation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion)) {
                                        uiState.expandedAgentID = uiState.expandedAgentID == agent.id ? nil : agent.id
                                    }
                                },
                                actions: actions
                            )
                            .opacity(rowsHaveRisen ? 1 : 0)
                            .offset(y: rowsHaveRisen || reduceMotion ? 0 : 8)
                            .animation(riseAnimation(forRowAt: rowIndex), value: rowsHaveRisen)
                        }
                    }
                }
                // The scroll view takes its content's height up to the panel's maximum, so a short list has no empty space.
                .frame(maxHeight: AgentListPanelController.maximumPanelHeight - Self.headerHeight - 1)
            }
        }
        .frame(width: AgentListPanelController.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous))
        .tetherCard()
        .overlay {
            if agentsWearTheAccent {
                RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous)
                    .strokeBorder(themeSettings.shownTheme.cursorColor, lineWidth: 1.5)
            }
        }
        // The window is larger than the Card, so the Card's shadow has room to draw.
        .padding(EdgeInsets(
            top: AgentListWindowMargins.top,
            leading: AgentListWindowMargins.leading,
            bottom: AgentListWindowMargins.bottom,
            trailing: AgentListWindowMargins.trailing
        ))
        .background(
            GeometryReader { geometryProxy in
                Color.clear.preference(key: AgentListSizePreferenceKey.self, value: geometryProxy.size)
            }
        )
        .onPreferenceChange(AgentListSizePreferenceKey.self) { contentSize in
            onContentSizeChange(contentSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            rowsHaveRisen = true
        }
    }
}

private struct AgentRowView: View {
    let agent: BackgroundAgent
    /// False while a video quiz question is open, when the Show and Hear buttons wait (`agentListMayDeliverAWaitingResult`).
    let resultsMayBeDeliveredNow: Bool
    let isExpanded: Bool
    let approvalState: AgentListApprovalState
    let onToggle: () -> Void
    let actions: AgentListActions

    @State private var isHovered = false

    /// The meter's filled segments and the token's ring share one color for each phase.
    private var meterColor: Color {
        switch agent.phase {
        // The agent's own color only shows while it runs, so it never stands for a state.
        case .running: return agent.displayColor.color
        case .finished: return DS.Colors.success
        case .failed: return DS.Colors.destructive
        case .cancelled: return DS.Colors.textTertiary
        }
    }

    private var liveLine: AgentListLiveLine? {
        agentListLiveLine(for: agent, approvalState: approvalState)
    }

    private func color(of tone: AgentListLiveLine.Tone) -> Color {
        switch tone {
        case .normal: return DS.Colors.textPrimary
        case .needsYou: return DS.Colors.warningText
        case .failure: return DS.Colors.destructiveText
        case .quiet: return DS.Colors.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        rowDisc
                        VStack(alignment: .leading, spacing: 2) {
                            rowTitle
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(agent.subject ?? "Finding the video")
                                .font(DS.TypeScale.caption.font)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let liveLine {
                                Text(verbatim: liveLine.text)
                                    .font(DS.TypeScale.caption.font)
                                    .foregroundColor(color(of: liveLine.tone))
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        elapsedTimeText
                    }
                    stepMeter
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? DS.Colors.surface3 : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverAndPointer { isHovered = $0 }

            if !agent.isRunning, hasRowButtons {
                rowButtons
                    // Lines up under the title, which starts after the disc.
                    .padding(.leading, 52)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isExpanded {
                expandedDetails
                    .transition(.opacity)
            }
        }
        .clipped()
    }

    /// The same disc the agent has beside the notch, with the same badges and loops, at its own size in the row's slot. It is
    /// not scaled, since the disc's orbiting dot and approval pulse are Core Animation layers pinned to the disc's size, which
    /// a SwiftUI scale does not reach.
    private var rowDisc: some View {
        AgentTokenDiscView(agent: agent, isWaitingForApproval: approvalState != .none)
            .frame(width: Self.discSlotDiameter, height: Self.discSlotDiameter)
    }

    /// The slot the disc sits in, which sets where the title starts.
    private static let discSlotDiameter: CGFloat = 28

    /// "Hinata #10 · Study guide" for a player, with the number quieter, and just the kind's name otherwise.
    private var rowTitle: Text {
        let kindName = Text(agent.kind.displayName)
            .font(DS.TypeScale.title.font)
            .foregroundColor(DS.Colors.textPrimary)
        guard let player = agent.rosterFace?.player else { return kindName }
        let playerName = Text(player.name)
            .font(DS.TypeScale.title.font)
            .foregroundColor(DS.Colors.textPrimary)
        let jerseyNumber = Text(player.number.map { " #\($0)" } ?? "")
            .font(DS.TypeScale.caption.font)
            .foregroundColor(DS.Colors.textSecondary)
        let separator = Text(" · ")
            .font(DS.TypeScale.title.font)
            .foregroundColor(DS.Colors.textPrimary)
        return playerName + jerseyNumber + separator + kindName
    }

    /// Only a running agent's time ticks, and the clock stops with the list, since the list's view is dropped on close.
    @ViewBuilder
    private var elapsedTimeText: some View {
        if agent.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
                Text(backgroundAgentElapsedTimeText(seconds: agent.elapsedSeconds(at: timelineContext.date)))
            }
            .font(DS.TypeScale.data.font)
            .foregroundColor(DS.Colors.textSecondary)
        } else {
            Text(backgroundAgentElapsedTimeText(seconds: agent.elapsedSeconds(at: Date())))
                .font(DS.TypeScale.data.font)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    /// One segment per step, filled by the same progress the token's ring shows, so the list and the notch agree.
    private var stepMeter: some View {
        ZStack {
            HStack(spacing: Self.stepMeterGap) {
                ForEach(Array(agent.kind.stepNames.indices), id: \.self) { _ in
                    Capsule().fill(DS.Colors.surface3)
                }
            }
            AgentProgressView(agent: agent) { shownProgress in
                StepMeterFill(progress: shownProgress, stepCount: agent.kind.steps.count, gap: Self.stepMeterGap)
                    .fill(meterColor)
            }
        }
        .frame(height: 3)
    }

    private static let stepMeterGap: CGFloat = 3

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(agent.stepStatuses.enumerated()), id: \.offset) { stepIndex, stepStatus in
                HStack(spacing: 8) {
                    if stepStatus == .done {
                        DrawnCheckMark()
                            .frame(width: 12)
                    } else {
                        Text(stepStatus.symbol)
                            .font(.system(size: 11, weight: stepStatus == .current ? .bold : .regular))
                            .foregroundColor(stepStatus == .current ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .frame(width: 12)
                    }
                    // A task agent writes its own step lines, so a long one is cut instead of growing the row.
                    Text(agent.stepNames[stepIndex])
                        .font(.system(size: 11, weight: stepStatus == .current ? .bold : .regular))
                        .foregroundColor(stepStatus == .pending ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            if agent.isRunning {
                AgentActionButton(title: "Cancel", titleColor: DS.Colors.destructiveText) { actions.cancelAgent(agent.id) }
            }
        }
        // Lines up under the title, which starts after the disc.
        .padding(.leading, 52)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A check mark that draws itself in when its row's steps appear, as the Snap move. With Reduce Motion it fades in.
private struct DrawnCheckMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrawn = false

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY - rect.height * 0.15))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.05, y: rect.minY + rect.height * 0.15))
            return path
        }
    }

    var body: some View {
        CheckShape()
            .trim(from: 0, to: reduceMotion || isDrawn ? 1 : 0)
            .stroke(DS.Colors.success, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .opacity(reduceMotion ? (isDrawn ? 1 : 0) : 1)
            .frame(width: 10, height: 10)
            .onAppear {
                withAnimation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion)) { isDrawn = true }
            }
    }
}

extension AgentRowView {
    /// Whether the row shows buttons under its title: a failed agent that can start again, or a finished agent's result.
    fileprivate var hasRowButtons: Bool {
        if agent.phase.isFailed { return agent.canBeTriedAgain }
        return agent.finishedResult != nil
    }

    /// What an ended agent's row allows: try a failed agent again, show a waiting 3D model or experiment, hear a waiting
    /// task answer, and open its Notion page. A result that was already delivered offers only the page.
    @ViewBuilder fileprivate var rowButtons: some View {
        HStack(spacing: 6) {
            if agent.phase.isFailed, agent.canBeTriedAgain {
                AgentActionButton(title: "Try again", titleColor: DS.Colors.textPrimary) { actions.tryAgain(agent.id) }
            }
            if agent.resultIsWaitingToBeDelivered && resultsMayBeDeliveredNow {
                switch agent.finishedResult {
                case .readyScene:
                    AgentActionButton(title: agent.kind == .experiment ? "Show experiment" : "Show model", titleColor: DS.Colors.textPrimary, action: actions.showReadyScene)
                case .answer:
                    AgentActionButton(title: "Hear answer", titleColor: DS.Colors.textPrimary, action: actions.hearTaskAnswer)
                case .notionPage, nil:
                    EmptyView()
                }
            }
            if let pageURL = agent.finishedResult?.pageURL {
                // Brings the page forward, unlike the background tab the finished agent opened it in.
                AgentActionButton(title: "Open page", titleColor: DS.Colors.textPrimary) {
                    NSWorkspace.shared.open(pageURL)
                }
            }
        }
    }
}

private struct AgentActionButton: View {
    let title: String
    let titleColor: Color
    /// A dimmed button is one whose click would not count yet, so it keeps the arrow, shows no hover, and does nothing.
    var isDimmed = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(titleColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small).fill(isHovered && !isDimmed ? DS.Colors.surface4 : DS.Colors.surface3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDimmed)
        .opacity(isDimmed ? 0.5 : 1)
        .hoverAndPointer(isEnabled: !isDimmed) { isHovered = $0 }
        .padding(.top, 2)
    }
}

/// The filled part of the list's step meter: each step's segment fills by its share of the progress.
/// Animatable, so it moves in step with the token's ring.
private struct StepMeterFill: Shape {
    var progress: Double
    let stepCount: Int
    let gap: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard stepCount > 0 else { return path }
        let segmentWidth = (rect.width - gap * CGFloat(stepCount - 1)) / CGFloat(stepCount)
        for stepIndex in 0..<stepCount {
            let shareOfThisStepDone = min(1, max(0, progress * Double(stepCount) - Double(stepIndex)))
            guard shareOfThisStepDone > 0 else { continue }
            let segmentRect = CGRect(
                x: rect.minX + CGFloat(stepIndex) * (segmentWidth + gap),
                y: rect.minY,
                width: segmentWidth * CGFloat(shareOfThisStepDone),
                height: rect.height
            )
            path.addRoundedRect(in: segmentRect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        }
        return path
    }
}

// MARK: - Approval card

/// Where the summary text sits in the scroll area's coordinates: its top goes negative as the learner scrolls down.
private struct ApprovalSummaryFrame: Equatable {
    var minY: CGFloat
    var height: CGFloat
}

private struct ApprovalSummaryFramePreferenceKey: PreferenceKey {
    static let defaultValue = ApprovalSummaryFrame(minY: 0, height: 0)
    static func reduce(value: inout ApprovalSummaryFrame, nextValue: () -> ApprovalSummaryFrame) {
        value = nextValue()
    }
}

private struct ApprovalSummaryScrollAreaHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The oldest approval request, pinned above the agent rows: the harness's summary shown whole as plain text, which a
/// web page or an MCP server may have written, and the Yes, Always, and No buttons. The summary scrolls inside the card
/// when it is long, and the card tells the desk whether it has shown all of it, from top to bottom, since an answer
/// counts only after it has.
private struct ApprovalCardView: View {
    let approvalRequest: HarnessApprovalRequest
    let agentName: String
    /// The answer went to the harness, whose gate takes the first answer, and its settlement has not come back yet, so
    /// the card shows no buttons and never a decline that the gate did not take.
    let isAnswering: Bool
    /// `HarnessApprovalDesk.oldestRequestVisibleSince`: the same value `answerByClick` checks, so the buttons look ready
    /// exactly when a click counts.
    let summaryShownSince: Date?
    let answerApproval: (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
    let summaryWasShownWhole: (Bool) -> Void

    @State private var summaryFrame = ApprovalSummaryFrame(minY: 0, height: 0)
    @State private var scrollAreaHeight: CGFloat = 0
    @State private var seenRanges = ApprovalSummarySeenRanges()
    /// Bumped when the 1 second after the whole summary showed has passed, so the card draws again with the buttons ready.
    @State private var readinessClockTick = Date()

    private static let scrollAreaCoordinateSpaceName = "approvalSummaryScrollArea"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(agentName) needs your OK. Allow this?")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.warningText)
            ScrollView {
                Text(verbatim: approvalRequest.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        GeometryReader { summaryProxy in
                            let frameInScrollArea = summaryProxy.frame(in: .named(Self.scrollAreaCoordinateSpaceName))
                            Color.clear.preference(
                                key: ApprovalSummaryFramePreferenceKey.self,
                                value: ApprovalSummaryFrame(minY: frameInScrollArea.minY, height: frameInScrollArea.height)
                            )
                        }
                    )
            }
            .frame(maxHeight: AgentListPanelController.maximumApprovalSummaryHeight)
            .fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(name: Self.scrollAreaCoordinateSpaceName)
            .background(
                GeometryReader { scrollAreaProxy in
                    Color.clear.preference(key: ApprovalSummaryScrollAreaHeightPreferenceKey.self, value: scrollAreaProxy.size.height)
                }
            )
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small).fill(DS.Colors.surface2))
            .onPreferenceChange(ApprovalSummaryFramePreferenceKey.self) { newSummaryFrame in
                summaryFrame = newSummaryFrame
                recordWhatTheScrollAreaShows()
            }
            .onPreferenceChange(ApprovalSummaryScrollAreaHeightPreferenceKey.self) { newScrollAreaHeight in
                scrollAreaHeight = newScrollAreaHeight
                recordWhatTheScrollAreaShows()
            }
            if isAnswering {
                Text(verbatim: "Sending your answer...")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    // The buttons' own padding (5 point rows and 2 points above), so the card keeps its height while an answer is sent.
                    .padding(.vertical, 5)
                    .padding(.top, 2)
            } else {
                HStack(spacing: 6) {
                    AgentActionButton(title: "Yes", titleColor: DS.Colors.success, isDimmed: answerReadiness.buttonsAreDimmed) {
                        answerApproval(approvalRequest.approvalID, true, .once)
                    }
                    AgentActionButton(title: "Always", titleColor: DS.Colors.textPrimary, isDimmed: answerReadiness.buttonsAreDimmed) {
                        answerApproval(approvalRequest.approvalID, true, .always)
                    }
                    AgentActionButton(title: "No", titleColor: DS.Colors.destructiveText, isDimmed: answerReadiness.buttonsAreDimmed) {
                        answerApproval(approvalRequest.approvalID, false, .once)
                    }
                }
            }
            // The panel is never key, so a tooltip would not show. One line in the same spot says why the buttons are
            // dimmed, then how long Always lasts, so the card keeps its height in every state.
            Text(verbatim: answerReadiness.waitingLine ?? "Always lasts until this task ends. Or say yes or no.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Syncs the redraw with the clock: nothing else changes when the second passes. Stops once the answer counts.
        .task(id: summaryShownSince) {
            while approvalAnswerReadiness(wholeSummaryShownSince: summaryShownSince, at: Date()) == .readyInAMoment {
                try? await Task.sleep(for: .milliseconds(100))
                readinessClockTick = Date()
            }
        }
    }

    private var answerReadiness: ApprovalAnswerReadiness {
        // Reads the tick so SwiftUI draws this again when it changes.
        _ = readinessClockTick
        return approvalAnswerReadiness(wholeSummaryShownSince: summaryShownSince, at: Date())
    }

    /// Adds the part of the summary the scroll area shows now to the ranges seen, and tells the desk whether the ranges
    /// cover the whole summary. A jump to the end records only the end, so the middle stays unseen until it scrolls by.
    private func recordWhatTheScrollAreaShows() {
        guard summaryFrame.height > 0, scrollAreaHeight > 0,
              let rangeInView = approvalSummaryRangeInView(
                  summaryMinY: summaryFrame.minY,
                  summaryHeight: summaryFrame.height,
                  scrollAreaHeight: scrollAreaHeight
              ) else { return }
        seenRanges.record(rangeInView, forApprovalID: approvalRequest.approvalID)
        summaryWasShownWhole(approvalSummaryWasShownWhole(seenRanges: seenRanges.ranges, summaryHeight: summaryFrame.height))
    }
}


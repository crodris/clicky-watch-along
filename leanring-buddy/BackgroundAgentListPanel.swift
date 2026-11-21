//
//  BackgroundAgentListPanel.swift
//  leanring-buddy
//
//  The clickable list of background agents. The Agents slice of the settings dial (shift + option) opens it next to the
//  mouse, and a click on an agent token beside the notch opens it under that token with the agent's row expanded.
//  It is a borderless, nonactivating panel that never becomes key, so Chrome keeps the keyboard while the learner
//  clicks a row. It closes on Escape, on a click outside, or on a second click on the token it opened from.
//

import AppKit
import SwiftUI

// MARK: - Placement

/// The panel's bottom-left corner when its top-left corner should sit at `anchorTopLeft`, moved to keep the whole panel
/// inside the screen's visible frame. Points are in AppKit's screen coordinates, where y grows upward.
func agentListPanelOrigin(anchorTopLeft: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
    let originX = min(max(anchorTopLeft.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
    let originY = min(max(anchorTopLeft.y - panelSize.height, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
    return CGPoint(x: originX, y: originY)
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
    /// Answers a task agent's approval request from the card's Don't allow, Allow once, and For this task buttons. The
    /// desk takes a no at once and ignores a yes that comes before the list's card showed the whole summary for a second
    /// (`HarnessApprovalDesk.answerByClick`).
    let answerApproval: (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
}

@MainActor
final class AgentListPanelController {
    static let panelWidth: CGFloat = 300
    static let maximumPanelHeight: CGFloat = 360
    /// The approval card's summary scrolls past this height, so a long one cannot push the rows off the screen.
    static let maximumApprovalSummaryHeight: CGFloat = 200
    /// The rest of the approval card around its summary at its tallest: the title on two lines and the kind line, "You
    /// said" on two lines, the status line, the buttons, the two line hint, the gaps and padding, and the line under it.
    static let approvalCardHeightOutsideTheSummary: CGFloat = 230
    /// The list's tallest, with an approval card above the rows.
    static let maximumPanelHeightWithAnApprovalCard: CGFloat = maximumPanelHeight + maximumApprovalSummaryHeight + approvalCardHeightOutsideTheSummary
    private static let gapFromTheMouse: CGFloat = 12
    /// One level above the cursor overlay windows, so the list is never under the cursor.
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    private let store: BackgroundAgentStore
    private let themeSettings: CompanionThemeSettings
    private let actions: AgentListActions
    /// The queue of requests the learner answers with the buttons of the approval card.
    private let approvalDesk: HarnessApprovalDesk
    private var panel: NonKeyFloatingPanel?
    private var clickOutsideMonitor: Any?
    /// Where the panel's top-left corner sits, fixed when it opens so a row that expands grows the panel downward.
    private var anchorTopLeft: CGPoint = .zero
    private var visibleFrame: CGRect = .zero
    private var resizeObserver: NSObjectProtocol?
    /// The disc the list was opened from, nil when the settings dial opened it, so a second click on the same disc closes it.
    private var discTheListWasOpenedFrom: AgentTokenDiscID?

    init(store: BackgroundAgentStore, themeSettings: CompanionThemeSettings, approvalDesk: HarnessApprovalDesk, actions: AgentListActions) {
        self.store = store
        self.themeSettings = themeSettings
        self.approvalDesk = approvalDesk
        self.actions = actions
    }

    var isOpen: Bool { panel != nil }

    /// The settings dial's Agents slice: open next to the mouse with no row expanded, or close when it is already open.
    func toggle() {
        if isOpen {
            close()
        } else {
            let mouseLocation = NSEvent.mouseLocation
            open(
                anchorTopLeft: CGPoint(x: mouseLocation.x + Self.gapFromTheMouse, y: mouseLocation.y - Self.gapFromTheMouse),
                visibleFrame: screenUnderTheMouseCursor()?.visibleFrame ?? .zero,
                initiallyExpandedAgentID: nil
            )
        }
    }

    /// A click on an agent token: open the list under that disc with the agent's row expanded, and "+N" with none.
    /// A click on the disc the list is already open from closes it, and a click on another disc, including the same
    /// agent's disc on another display, moves it there.
    func toggle(from discID: AgentTokenDiscID, discPanelFrame: CGRect, on screen: NSScreen) {
        let discWasAlreadyOpen = discTheListWasOpenedFrom == discID
        let listWasOpen = isOpen
        close()
        if listWasOpen && discWasAlreadyOpen { return }
        let agentIDToExpand: UUID?
        switch discID.tokenSlot {
        case .agent(let agentID): agentIDToExpand = agentID
        case .overflow: agentIDToExpand = nil
        }
        open(
            anchorTopLeft: CGPoint(x: discPanelFrame.minX, y: discPanelFrame.minY - Self.gapFromTheMouse / 4),
            visibleFrame: screen.visibleFrame,
            initiallyExpandedAgentID: agentIDToExpand
        )
        discTheListWasOpenedFrom = discID
    }

    private func open(anchorTopLeft: CGPoint, visibleFrame: CGRect, initiallyExpandedAgentID: UUID?) {
        guard panel == nil else { return }
        self.visibleFrame = visibleFrame
        self.anchorTopLeft = anchorTopLeft
        discTheListWasOpenedFrom = nil

        let agentListView = AgentListView(
            store: store,
            themeSettings: themeSettings,
            approvalDesk: approvalDesk,
            actions: actions,
            initiallyExpandedAgentID: initiallyExpandedAgentID
        ) { [weak self] contentSize in
            self?.resizePanel(to: contentSize)
        }
        let hostingView = FirstMouseHostingView(rootView: agentListView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        let initialSize = CGSize(width: Self.panelWidth, height: min(hostingView.fittingSize.height, Self.maximumPanelHeightWithAnApprovalCard))

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
            (self?.anchorTopLeft ?? .zero, self?.visibleFrame ?? .zero)
        }
        resizePanel(to: initialSize)
        // Not makeKeyAndOrderFront, which would take the keyboard from Chrome.
        agentListPanel.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    /// An approval request arrived: open the list next to the mouse with the requesting agent's row expanded. An open
    /// list stays where it is, since its approval card shows the oldest request by itself.
    func openForAnApprovalRequest(fromAgentID agentID: UUID) {
        guard !isOpen else { return }
        let mouseLocation = NSEvent.mouseLocation
        let visibleFrame = screenUnderTheMouseCursor()?.visibleFrame ?? .zero
        open(
            anchorTopLeft: approvalListAnchorTopLeft(
                mouseLocation: mouseLocation,
                panelSize: CGSize(width: Self.panelWidth, height: Self.maximumPanelHeightWithAnApprovalCard),
                visibleFrame: visibleFrame,
                gapFromTheMouse: Self.gapFromTheMouse
            ),
            visibleFrame: visibleFrame,
            initiallyExpandedAgentID: agentID
        )
    }

    func close() {
        discTheListWasOpenedFrom = nil
        approvalDesk.theCardHasNotShownTheWholeSummary(on: .agentList)
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        panel?.orderOut(nil)
        // Dropping the view stops the running agents' clocks, which tick only while the list is open.
        panel?.contentView = nil
        panel = nil
    }

    private func resizePanel(to contentSize: CGSize) {
        guard let panel else { return }
        let panelSize = CGSize(width: Self.panelWidth, height: min(contentSize.height, Self.maximumPanelHeightWithAnApprovalCard))
        let panelOrigin = agentListPanelOrigin(anchorTopLeft: anchorTopLeft, panelSize: panelSize, visibleFrame: visibleFrame)
        panel.setFrame(CGRect(origin: panelOrigin, size: panelSize), display: true)
    }

    /// A global monitor sees only clicks that go to other apps, so a click inside the panel never closes it.
    private func installClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.close()
            }
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
    let onContentSizeChange: (CGSize) -> Void

    @State private var expandedAgentID: UUID?

    private static let headerHeight: CGFloat = 40

    init(
        store: BackgroundAgentStore,
        themeSettings: CompanionThemeSettings,
        approvalDesk: HarnessApprovalDesk,
        actions: AgentListActions,
        initiallyExpandedAgentID: UUID?,
        onContentSizeChange: @escaping (CGSize) -> Void
    ) {
        self.store = store
        self.themeSettings = themeSettings
        self.approvalDesk = approvalDesk
        self.actions = actions
        self.onContentSizeChange = onContentSizeChange
        _expandedAgentID = State(initialValue: initiallyExpandedAgentID)
    }

    /// A theme whose agents all wear its accent, such as a team in its jersey color, borders the panel in that color.
    /// Every other theme keeps the thin gray border.
    private var agentsWearTheAccent: Bool {
        themeSettings.shownTheme.agents.ring == .accent
    }

    private var panelBorderColor: Color {
        agentsWearTheAccent ? themeSettings.shownTheme.cursorColor : DS.Colors.borderSubtle
    }

    private var panelBorderWidth: CGFloat {
        agentsWearTheAccent ? 1.5 : 1
    }

    /// The theme's name after a small square in its accent, with every name coming from the theme's file.
    @ViewBuilder private var headerTitle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(themeSettings.shownTheme.cursorColor)
            .frame(width: 10, height: 10)
        // A saved name runs to 24 characters, so it is cut before it pushes the running count off the header.
        Text(themeSettings.shownTheme.name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                headerTitle
                Spacer()
                Text("\(store.agents.filter(\.isRunning).count) running")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

            // The oldest request sits above the rows, so no scroll position can hide it. For a moment after it ends, the
            // card says how it ended.
            if let shownCard = approvalDesk.cardToShow(on: .agentList, at: Date()) {
                let requestingAgent = store.agents.first { agent in agent.id == shownCard.request.taskID }
                ApprovalCardView(
                    shownCard: shownCard,
                    agentName: requestingAgent?.displayName ?? "An agent",
                    learnerWords: requestingAgent?.learnerWords,
                    wholeSummaryShownSince: approvalDesk.wholeSummaryShownSinceBySurface[.agentList],
                    answerApproval: actions.answerApproval,
                    summaryWasShownWhole: { summaryWasShownWhole in
                        if summaryWasShownWhole {
                            approvalDesk.theCardShowedTheWholeSummary(ofApprovalID: shownCard.request.approvalID, on: .agentList)
                        } else {
                            approvalDesk.theCardHasNotShownTheWholeSummary(on: .agentList)
                        }
                    }
                )
                // A new request gets a new card, so its summary is measured from the top.
                .id(shownCard.request.approvalID)

                Rectangle()
                    .fill(DS.Colors.borderSubtle)
                    .frame(height: 1)
            }

            if store.agents.isEmpty {
                Text("No agents yet. Ask for a study guide while a video plays.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.agents) { agent in
                            let approvalState = agentListApprovalState(forAgentID: agent.id, waitingRequests: approvalDesk.waitingRequests)
                            AgentRowView(
                                agent: agent,
                                resultsMayBeDeliveredNow: agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: store.aVideoQuizQuestionIsOpen),
                                isExpanded: expandedAgentID == agent.id,
                                approvalState: approvalState,
                                onToggle: { expandedAgentID = expandedAgentID == agent.id ? nil : agent.id },
                                actions: actions
                            )
                        }
                    }
                }
                // The scroll view takes its content's height up to the panel's maximum, so a short list has no empty space.
                .frame(maxHeight: AgentListPanelController.maximumPanelHeight - Self.headerHeight - 1)
            }
        }
        .frame(width: AgentListPanelController.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(panelBorderColor, lineWidth: panelBorderWidth))
        .background(
            GeometryReader { geometryProxy in
                Color.clear.preference(key: AgentListSizePreferenceKey.self, value: geometryProxy.size)
            }
        )
        .onPreferenceChange(AgentListSizePreferenceKey.self) { contentSize in
            onContentSizeChange(contentSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        rowIcon
                        VStack(alignment: .leading, spacing: 2) {
                            rowTitle
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(agent.subject ?? "Finding the video")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let approvalStatusText = approvalState.rowStatusText {
                                Text(approvalStatusText)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(DS.Colors.warningText)
                                    .lineLimit(1)
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

            if isExpanded {
                expandedDetails
            }
        }
    }

    @ViewBuilder private var rowIcon: some View {
        if case .rosterFace(let rosterFace) = agent.face {
            RosterFaceView(rosterFace: rosterFace, size: 28, isGrayscale: agent.phase.isFailed)
                .overlay(Circle().stroke(agentListPortraitBorderColor(phase: agent.phase, agentColor: agent.displayColor.color), lineWidth: 2))
                // A finished agent's portrait steps back, as its meter turns green.
                .opacity(agent.finishedResult == nil ? 1 : 0.5)
        } else if case .themePicture(let themeID) = agent.face, let themePicture = CustomThemePictureCache.image(forThemeID: themeID) {
            ThemePictureFaceView(picture: themePicture, size: 28, isGrayscale: agent.phase.isFailed)
                .overlay(Circle().stroke(meterColor, lineWidth: 2))
                .opacity(agent.finishedResult == nil ? 1 : 0.5)
        } else {
            AgentTriangleView(agent: agent, size: 11)
                .frame(width: 16, height: 16)
        }
    }

    /// "Hinata #10 · Study guide" for a player, with the number quieter, and just the kind's name otherwise.
    private var rowTitle: Text {
        let kindName = Text(agent.kind.displayName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
        guard let player = agent.rosterFace?.player else { return kindName }
        let playerName = Text(player.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
        let jerseyNumber = Text(player.number.map { " #\($0)" } ?? "")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
        let separator = Text(" · ")
            .font(.system(size: 12, weight: .semibold))
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
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(DS.Colors.textSecondary)
        } else {
            Text(backgroundAgentElapsedTimeText(seconds: agent.elapsedSeconds(at: Date())))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
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
                    Text(stepStatus.symbol)
                        .font(.system(size: 11, weight: stepStatus == .current ? .bold : .regular))
                        .foregroundColor(stepStatus == .done ? DS.Colors.success : stepStatus == .current ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .frame(width: 12)
                    // A task agent writes its own step lines, so a long one is cut instead of growing the row.
                    Text(agent.stepNames[stepIndex])
                        .font(.system(size: 11, weight: stepStatus == .current ? .bold : .regular))
                        .foregroundColor(stepStatus == .pending ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            if case .failed(let reason) = agent.phase {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .cancelled = agent.phase {
                Text("Cancelled")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            if agent.isRunning {
                AgentActionButton(title: "Cancel", titleColor: DS.Colors.destructiveText) { actions.cancelAgent(agent.id) }
            } else if agent.finishedResult != nil {
                resultButtons
            }
        }
        // Lines up under the title, which starts after the icon.
        .padding(.leading, agent.face == .triangle ? 40 : 52)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AgentRowView {
    /// What a finished agent's result allows: show a waiting 3D model or experiment, hear a waiting task answer, and open
    /// its Notion page. A result that was already delivered offers only the page.
    @ViewBuilder fileprivate var resultButtons: some View {
        HStack(spacing: 6) {
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

/// The portrait took the triangle's place in the list, so its border carries the state the triangle's color used to:
/// red for a failed agent and gray for a cancelled one. The agent's own color only marks a running or finished agent.
func agentListPortraitBorderColor(phase: BackgroundAgentPhase, agentColor: Color) -> Color {
    switch phase {
    case .running, .finished: return agentColor
    case .failed: return DS.Colors.destructive
    case .cancelled: return DS.Colors.textTertiary
    }
}

// MARK: - Approval card

extension HarnessCapability {
    /// The title's verb, after the agent's name: "Hinata wants to send something out".
    var approvalCardVerbPhrase: String {
        switch self {
        case .sends: return "wants to send something out"
        case .deletes: return "wants to delete something"
        case .spends: return "wants to spend money"
        case .readsPrivate: return "wants to read something private"
        // The desk declines a capability it does not know before any card shows it.
        case .unknown: return "wants to do something"
        }
    }

    /// The line under the title, which says what the kind of action can do.
    var approvalCardKindLine: String {
        switch self {
        case .sends: return "Sends data out of your Mac"
        case .deletes: return "Deletes data"
        case .spends: return "Spends money"
        case .readsPrivate: return "Reads your screen, clipboard, or files"
        case .unknown: return "An action Clicky cannot name"
        }
    }

    /// One icon per kind of action, on the card's amber disc.
    var approvalCardSymbolName: String {
        switch self {
        case .sends: return "paperplane.fill"
        case .deletes: return "trash.fill"
        case .spends: return "creditcard.fill"
        case .readsPrivate: return "eye.fill"
        case .unknown: return "questionmark"
        }
    }
}

/// The share of the summary's height that its seen ranges cover, from 0 to 1, which the rail draws and VoiceOver reads.
func approvalSummaryShareSeen(seenRanges: [ClosedRange<CGFloat>], summaryHeight: CGFloat) -> Double {
    guard summaryHeight > 0 else { return 0 }
    let coveredHeight = mergedApprovalSummaryRanges(seenRanges).reduce(CGFloat(0)) { coveredHeight, range in
        coveredHeight + (range.upperBound - range.lowerBound)
    }
    return min(1, Double(coveredHeight / summaryHeight))
}

/// The summary split at its line breaks, one row per line, so each row is its own VoiceOver element and moving
/// through them scrolls the box. The text stays as the harness wrote it, and an empty line keeps its height.
func approvalSummaryRows(_ summary: String) -> [String] {
    summary.split(separator: "\n", omittingEmptySubsequences: false).map { row in row.isEmpty ? " " : String(row) }
}

/// The words on the status line above the buttons for each phase of the card. `reduceMotionIsOn` swaps the ring for
/// words while the 1 second runs, since the ring is the only sign of the clock.
func approvalCardStatusText(phase: ApprovalCardPhase, reduceMotionIsOn: Bool) -> String {
    switch phase {
    case .waiting(.summaryNotYetSeen): return "Read the whole request to allow it"
    case .waiting(.readyInAMoment): return reduceMotionIsOn ? "Ready in 1 s" : "All read · one moment"
    case .waiting(.ready): return "You can answer now"
    case .sending: return "Sending your answer…"
    case .ended(.allowed(.once)): return "Allowed once. The task goes on."
    case .ended(.allowed(.always)): return "Allowed for this task."
    case .ended(.declined): return "Declined. The agent skips this step."
    case .ended(.timedOut): return "Declined after 2 minutes with no answer."
    case .ended(.noReply): return "Sent, but the agent never confirmed it."
    }
}

/// The approval card's surface, pinned above the agent rows. It shows the oldest request, or for a moment how the last
/// one ended: the title verb and the kind of action, the learner's own words that started the agent, the harness's
/// summary shown whole as plain text, which a web page or an MCP server may have written, a rail that fills in each
/// part of the summary that has been in view, a ring for the 1 second, and three equal buttons with the safe one
/// first. Don't allow counts at once. Allow once and For this task enable together once this surface has shown the
/// whole summary for a second, which the card reports to the desk.
struct ApprovalCardView: View {
    let shownCard: ShownApprovalCard
    let agentName: String
    /// The learner's own push-to-talk words that started the agent, or nil when no spoken request did.
    let learnerWords: String?
    /// When this surface's card first showed the whole summary (`HarnessApprovalDesk.wholeSummaryShownSinceBySurface`),
    /// the same value `answerByClick` checks, so the buttons look ready exactly when a click counts.
    let wholeSummaryShownSince: Date?
    let answerApproval: (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
    let summaryWasShownWhole: (Bool) -> Void
    /// Set by renders and tests, since the environment's Reduce Motion cannot be set from outside.
    var reduceMotionOverride: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var summaryFrame = CGRect.zero
    @State private var scrollAreaHeight: CGFloat = 0
    @State private var seenRanges = ApprovalSummarySeenRanges()
    /// Bumped while the 1 second runs, so the card draws again with the buttons ready when it has passed.
    @State private var readinessClockTick = Date()

    private static let scrollAreaCoordinateSpaceName = "approvalSummaryScrollArea"
    private static let railWidth: CGFloat = 4
    private static let ringDiameter: CGFloat = 14

    private var reduceMotionIsOn: Bool { reduceMotionOverride ?? systemReduceMotion }
    private var approvalRequest: HarnessApprovalRequest { shownCard.request }

    /// The desk's phase, with a waiting card's readiness read again on this card's own clock.
    private var phase: ApprovalCardPhase {
        guard case .waiting = shownCard.phase else { return shownCard.phase }
        // Reads the tick so SwiftUI draws this again when it changes.
        _ = readinessClockTick
        return .waiting(approvalAnswerReadiness(wholeSummaryShownSince: wholeSummaryShownSince, at: Date()))
    }

    private var isWaiting: Bool {
        if case .waiting = phase { return true }
        return false
    }

    private var allowButtonsAreEnabled: Bool { phase == .waiting(.ready) }

    private var percentRead: Int {
        Int((approvalSummaryShareSeen(seenRanges: seenRanges.ranges, summaryHeight: summaryFrame.height) * 100).rounded(.down))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let learnerWords, !learnerWords.isEmpty {
                youSaid(learnerWords)
            }
            summaryBox
            statusRow
            HStack(spacing: 6) {
                ApprovalAnswerButton(title: "Don't allow", isEnabled: isWaiting) {
                    answerApproval(approvalRequest.approvalID, false, .once)
                }
                .accessibilityHint("Counts at once")
                ApprovalAnswerButton(title: "Allow once", isEnabled: allowButtonsAreEnabled) {
                    answerApproval(approvalRequest.approvalID, true, .once)
                }
                .accessibilityHint("Available once the whole request has been read")
                ApprovalAnswerButton(title: "For this task", isEnabled: allowButtonsAreEnabled) {
                    answerApproval(approvalRequest.approvalID, true, .always)
                }
                .accessibilityHint("Allows this tool and kind of access until the agent finishes")
            }
            // The panel is never key, so a tooltip would not show. This line says how to answer by voice and what the
            // third button covers.
            Text(verbatim: "Or say yes or no. For this task lasts until the agent finishes.")
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval request. \(agentName) \(approvalRequest.capability.approvalCardVerbPhrase)")
        // Syncs the redraw with the clock: nothing else changes when the second passes. Stops once a yes counts.
        .task(id: wholeSummaryShownSince) {
            while approvalAnswerReadiness(wholeSummaryShownSince: wholeSummaryShownSince, at: Date()) == .readyInAMoment {
                try? await Task.sleep(for: .milliseconds(100))
                readinessClockTick = Date()
            }
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .waiting(.ready): AccessibilityNotification.Announcement("Ready to answer").post()
            case .ended: AccessibilityNotification.Announcement(approvalCardStatusText(phase: newPhase, reduceMotionIsOn: reduceMotionIsOn)).post()
            default: break
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: approvalRequest.capability.approvalCardSymbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.inkOnAccent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(DS.Colors.warning))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(agentName) \(approvalRequest.capability.approvalCardVerbPhrase)")
                    .font(DS.TypeScale.title.font)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: approvalRequest.capability.approvalCardKindLine)
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func youSaid(_ learnerWords: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "You said, when it started:")
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textSecondary)
            Text(verbatim: "\u{201C}\(learnerWords)\u{201D}")
                .font(DS.TypeScale.body.font)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("You said, when it started: \(learnerWords)")
    }

    private var summaryBox: some View {
        let summaryRows = approvalSummaryRows(approvalRequest.summary)
        return HStack(alignment: .top, spacing: 6) {
            rail
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(summaryRows.enumerated()), id: \.offset) { _, summaryRow in
                        Text(verbatim: summaryRow)
                            .font(DS.TypeScale.data.font)
                            .foregroundColor(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                // A geometry change, not a preference: on macOS 26 the preference fired once with zeros and never again
                // in the Tether prototype, so the box never counted as read.
                .onGeometryChange(for: CGRect.self) { summaryProxy in
                    summaryProxy.frame(in: .named(Self.scrollAreaCoordinateSpaceName))
                } action: { newSummaryFrame in
                    summaryFrame = newSummaryFrame
                    recordWhatTheScrollAreaShows()
                }
            }
            .frame(maxHeight: AgentListPanelController.maximumApprovalSummaryHeight)
            .fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(name: Self.scrollAreaCoordinateSpaceName)
            .onGeometryChange(for: CGFloat.self) { scrollAreaProxy in
                scrollAreaProxy.size.height
            } action: { newScrollAreaHeight in
                scrollAreaHeight = newScrollAreaHeight
                recordWhatTheScrollAreaShows()
            }
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(DS.Colors.surface2))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Request details, \(percentRead) percent read")
        }
    }

    /// Beside the box, the whole summary scaled to the box's height, filled in amber for each part that has been in
    /// view, gaps included, so jumping to the end does not look read.
    private var rail: some View {
        GeometryReader { railProxy in
            let summaryHeight = max(summaryFrame.height, 1)
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.1))
                ForEach(Array(seenRanges.ranges.enumerated()), id: \.offset) { _, seenRange in
                    Capsule()
                        .fill(DS.Colors.warning)
                        .frame(height: max(2, (seenRange.upperBound - seenRange.lowerBound) / summaryHeight * railProxy.size.height))
                        .offset(y: seenRange.lowerBound / summaryHeight * railProxy.size.height)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(width: Self.railWidth)
        .accessibilityHidden(true)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            switch phase {
            case .waiting(.readyInAMoment) where !reduceMotionIsOn:
                TimelineView(.animation) { timelineContext in
                    readyRing(progress: approvalReadyClockProgress(wholeSummaryShownSince: wholeSummaryShownSince, at: timelineContext.date))
                }
            case .waiting(.ready):
                readyRing(progress: 1)
            case .sending:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: Self.ringDiameter, height: Self.ringDiameter)
            default:
                EmptyView()
            }
            Text(verbatim: approvalCardStatusText(phase: phase, reduceMotionIsOn: reduceMotionIsOn))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: Self.ringDiameter, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusTextColor: Color {
        switch phase {
        case .waiting(.summaryNotYetSeen), .sending, .ended(.declined), .ended(.noReply): return DS.Colors.textSecondary
        case .waiting: return DS.Colors.warningText
        case .ended(.allowed): return DS.Colors.success
        case .ended(.timedOut): return DS.Colors.destructiveText
        }
    }

    private func readyRing(progress: Double) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(DS.Colors.warning, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .accessibilityHidden(true)
    }

    /// Adds the part of the summary the scroll area shows now to the ranges seen, and tells the desk whether the ranges
    /// cover the whole summary. A jump to the end records only the end, so the middle stays unseen until it scrolls by.
    private func recordWhatTheScrollAreaShows() {
        guard isWaiting, summaryFrame.height > 0, scrollAreaHeight > 0,
              let rangeInView = approvalSummaryRangeInView(
                  summaryMinY: summaryFrame.minY,
                  summaryHeight: summaryFrame.height,
                  scrollAreaHeight: scrollAreaHeight
              ) else { return }
        seenRanges.record(rangeInView, forApprovalID: approvalRequest.approvalID)
        summaryWasShownWhole(approvalSummaryWasShownWhole(seenRanges: seenRanges.ranges, summaryHeight: summaryFrame.height))
    }
}

/// One of the card's three equal buttons. They share one look, with no red or green, so no color picks a side. A
/// disabled button keeps the arrow, shows no hover, and does nothing. Plain `.focusable()` lets Tab reach it with Full
/// Keyboard Access off, once the card sits on a surface that takes the keyboard.
private struct ApprovalAnswerButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .fill(isHovered && isEnabled ? DS.Colors.surface4 : DS.Colors.surface3)
                )
                .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusable()
        .hoverAndPointer(isEnabled: isEnabled) { isHovered = $0 }
        .accessibilityLabel(title)
    }
}

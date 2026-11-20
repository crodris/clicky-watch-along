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

// MARK: - Panel

private final class AgentListPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a panel that is not key would otherwise only be swallowed by AppKit.
private final class AgentListHostingView<Content: View>: NSHostingView<Content> {
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
    /// Answers a task agent's approval request from the Yes, Always, and No buttons. The desk ignores a click that comes
    /// too soon after the request showed (`HarnessApprovalDesk.answerByClick`).
    let answerApproval: (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
}

@MainActor
final class AgentListPanelController {
    static let panelWidth: CGFloat = 300
    static let maximumPanelHeight: CGFloat = 360
    private static let gapFromTheMouse: CGFloat = 12
    /// One level above the cursor overlay windows, so the list is never under the cursor.
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    private let store: BackgroundAgentStore
    private let themeSettings: CompanionThemeSettings
    private let actions: AgentListActions
    /// The queue of requests the learner answers with the Yes, Always, and No buttons of the oldest one's row.
    private let approvalDesk: HarnessApprovalDesk
    private var panel: AgentListPanel?
    private var clickOutsideMonitor: Any?
    /// Where the panel's top-left corner sits, fixed when it opens so a row that expands grows the panel downward.
    private var anchorTopLeft: CGPoint = .zero
    private var visibleFrame: CGRect = .zero
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
        approvalDesk.theListShowedTheOldestRequest()

        let agentListView = AgentListView(
            store: store,
            themeSettings: themeSettings,
            approvalDesk: approvalDesk,
            actions: actions,
            initiallyExpandedAgentID: initiallyExpandedAgentID
        ) { [weak self] contentSize in
            self?.resizePanel(to: contentSize)
        }
        let hostingView = AgentListHostingView(rootView: agentListView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        let initialSize = CGSize(width: Self.panelWidth, height: min(hostingView.fittingSize.height, Self.maximumPanelHeight))

        let agentListPanel = AgentListPanel(
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
        resizePanel(to: initialSize)
        // Not makeKeyAndOrderFront, which would take the keyboard from Chrome.
        agentListPanel.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    /// An approval request arrived: open the list next to the mouse with the requesting agent's row expanded. An open
    /// list stays where it is, since the row that holds the request expands by itself.
    func openForAnApprovalRequest(fromAgentID agentID: UUID) {
        guard !isOpen else { return }
        let mouseLocation = NSEvent.mouseLocation
        let visibleFrame = screenUnderTheMouseCursor()?.visibleFrame ?? .zero
        open(
            anchorTopLeft: approvalListAnchorTopLeft(
                mouseLocation: mouseLocation,
                panelSize: CGSize(width: Self.panelWidth, height: Self.maximumPanelHeight),
                visibleFrame: visibleFrame,
                gapFromTheMouse: Self.gapFromTheMouse
            ),
            visibleFrame: visibleFrame,
            initiallyExpandedAgentID: agentID
        )
    }

    func close() {
        discTheListWasOpenedFrom = nil
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        panel?.orderOut(nil)
        // Dropping the view stops the running agents' clocks, which tick only while the list is open.
        panel?.contentView = nil
        panel = nil
    }

    private func resizePanel(to contentSize: CGSize) {
        guard let panel else { return }
        let panelSize = CGSize(width: Self.panelWidth, height: min(contentSize.height, Self.maximumPanelHeight))
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

private extension View {
    /// Shows the pointing hand over this view and reports whether the mouse is over it.
    func hoverAndPointer(_ onHoverChange: @escaping (Bool) -> Void) -> some View {
        overlay(HoverAndPointerView(onHoverChange: onHoverChange))
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

    /// A school theme borders the panel in the team's color. Every other theme keeps today's thin gray border.
    private var panelBorderColor: Color {
        if case .school(let school) = themeSettings.theme { return school.accentColor }
        return DS.Colors.borderSubtle
    }

    private var panelBorderWidth: CGFloat {
        if case .school = themeSettings.theme { return 1.5 }
        return 1
    }

    /// "Agents" with Clicky blue, the team's name after a small accent square for a school, or "Random lineup".
    @ViewBuilder private var headerTitle: some View {
        switch themeSettings.theme {
        case .clickyBlue:
            Text("Agents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
        case .school(let school):
            RoundedRectangle(cornerRadius: 3)
                .fill(school.accentColor)
                .frame(width: 10, height: 10)
            Text(school.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        case .random:
            Text("Random lineup")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                headerTitle
                Spacer()
                Text("\(store.agents.filter(\.isRunning).count) \(themeSettings.theme == .clickyBlue ? "running" : "on court")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

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
                                // The row that holds the request stays open, so the learner can read it before answering.
                                isExpanded: expandedAgentID == agent.id || approvalState.needsAnAnswer,
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
        // The team's color only shows while the agent runs, so it never stands for a state.
        case .running: return agent.player?.school.accentColor ?? agent.displayColor.color
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
        if let player = agent.player {
            HaikyuPortraitView(player: player, size: 28, isGrayscale: agent.phase.isFailed)
                .overlay(Circle().stroke(agentListPortraitBorderColor(phase: agent.phase, school: player.school), lineWidth: 2))
                // A finished agent's portrait steps back, as its meter turns green.
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
        guard let player = agent.player else { return kindName }
        let playerName = Text(player.displayName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
        let jerseyNumber = Text(" #\(player.jerseyNumber)")
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
            if case .needsAnswer(let approvalRequest) = approvalState {
                approvalRequestBlock(approvalRequest)
            }
            ForEach(Array(agent.stepStatuses.enumerated()), id: \.offset) { stepIndex, stepStatus in
                HStack(spacing: 8) {
                    Text(stepStatus.symbol)
                        .font(.system(size: 11, weight: stepStatus == .current ? .bold : .regular))
                        .foregroundColor(stepStatus == .done ? DS.Colors.success : stepStatus == .current ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .frame(width: 12)
                    Text(agent.stepNames[stepIndex])
                        .font(.system(size: 11, weight: stepStatus == .current ? .bold : .regular))
                        .foregroundColor(stepStatus == .pending ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                }
            }
            if case .failed(let reason) = agent.phase {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructiveText)
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
        .padding(.leading, agent.player == nil ? 40 : 52)
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

    /// The harness's summary of what the tool will do, shown whole and never cut, since reading all of it is how the
    /// learner decides. It is text a web page or an MCP server may have written, so it is shown as plain text only.
    fileprivate func approvalRequestBlock(_ approvalRequest: HarnessApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Allow this?")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.warningText)
            Text(verbatim: approvalRequest.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small).fill(DS.Colors.surface2))
            HStack(spacing: 6) {
                AgentActionButton(title: "Yes", titleColor: DS.Colors.success) {
                    actions.answerApproval(approvalRequest.approvalID, true, .once)
                }
                AgentActionButton(title: "Always", titleColor: DS.Colors.textPrimary) {
                    actions.answerApproval(approvalRequest.approvalID, true, .always)
                }
                AgentActionButton(title: "No", titleColor: DS.Colors.destructiveText) {
                    actions.answerApproval(approvalRequest.approvalID, false, .once)
                }
            }
            Text(verbatim: "Or say yes or no.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.bottom, 4)
    }
}

private struct AgentActionButton: View {
    let title: String
    let titleColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(titleColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small).fill(isHovered ? DS.Colors.surface4 : DS.Colors.surface3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverAndPointer { isHovered = $0 }
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
/// red for a failed agent and gray for a cancelled one. The team's color only marks a running or finished agent.
func agentListPortraitBorderColor(phase: BackgroundAgentPhase, school: HaikyuSchool) -> Color {
    switch phase {
    case .running, .finished: return school.accentColor
    case .failed: return DS.Colors.destructive
    case .cancelled: return DS.Colors.textTertiary
    }
}

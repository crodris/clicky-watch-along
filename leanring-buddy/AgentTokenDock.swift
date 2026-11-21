//
//  AgentTokenDock.swift
//  leanring-buddy
//
//  The AppKit side of the agent tokens: one small borderless panel per disc, floating in the menu bar row just right of
//  the notch (or past the middle of a display with no notch). Each panel hosts one SwiftUI disc and takes its own clicks
//  without activating Clicky or taking the keyboard from Chrome. This file measures how much free space the menu bar
//  has, and the pure rules in `AgentTokenLayout.swift` decide which tokens fill it. It also runs the serve: a new agent's
//  token flies in from the blue cursor on the carrier panel (`TetherCarrier`) while its disc shows an open slot, as `AgentTokenServe.swift` plans.
//  And it runs Bring back, the spark from a disc to the cursor that carries an agent's ending chip (`AgentTokenBringBack.swift`),
//  the peek card a hovered disc shows (`AgentTokenPeek.swift`), and a disc's right-click menu (`AgentTokenMenu.swift`).
//
//  macOS draws no app window in the strip beside the notch during a full-screen space, so no disc shows there, and
//  nothing here works around that. Endings use the chip at the cursor.
//

import AppKit
import ApplicationServices
import Combine
import SwiftUI

// MARK: - Measuring the menu bar

/// The front app's menu titles, as read from its accessibility menu bar, in global screen coordinates.
/// Reading them needs the Accessibility permission Clicky already has, and an app that hangs answers late, so the call has a
/// short timeout and runs off the main thread.
private nonisolated func menuTitleFrames(ofApplicationWithProcessIdentifier processIdentifier: pid_t) -> [CGRect] {
    let applicationElement = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(applicationElement, 0.5)
    var menuBarValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(applicationElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
          let menuBarValue,
          CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return [] }
    // Forced cast: the type ID check above says this CFTypeRef is an AXUIElement, which Swift cannot conditionally cast.
    let menuBarElement = menuBarValue as! AXUIElement

    var menuTitleValues: CFTypeRef?
    guard AXUIElementCopyAttributeValue(menuBarElement, kAXChildrenAttribute as CFString, &menuTitleValues) == .success,
          let menuTitleElements = menuTitleValues as? [AXUIElement] else { return [] }

    return menuTitleElements.compactMap { menuTitleElement in
        // The frame attribute's name, which this SDK's headers do not define as a constant.
        var frameValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuTitleElement, "AXFrame" as CFString, &frameValue) == .success,
              let frameValue,
              CFGetTypeID(frameValue) == AXValueGetTypeID() else { return nil }
        var frame = CGRect.zero
        // Forced cast for the same reason: the type ID check says this is an AXValue.
        guard AXValueGetValue(frameValue as! AXValue, .cgRect, &frame), frame.width > 0 else { return nil }
        return frame
    }
}

/// The frames of the on-screen windows at the status window layer, in Quartz coordinates (y down from the main display's
/// top). Control Center owns nearly all of them, so the layer picks them, not the owner.
private func onScreenStatusWindowFramesInQuartzCoordinates() -> [CGRect] {
    let windowInfos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    return windowInfos.compactMap { windowInfo in
        guard let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
              windowLayer == Int(CGWindowLevelForKey(.statusWindow)),
              let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: boundsDictionary)
    }
}

private extension NSScreen {
    /// The notch's left and right edges in global x, from the widths of the menu bar space on each side of it.
    /// Nil when the display has no notch.
    var notchEdgesX: (minX: CGFloat, maxX: CGFloat)? {
        guard let leftArea = auxiliaryTopLeftArea, let rightArea = auxiliaryTopRightArea else { return nil }
        return (frame.minX + leftArea.width, frame.maxX - rightArea.width)
    }

    /// The menu bar's height. A notched display's bar is as tall as its notch.
    var menuBarHeight: CGFloat {
        safeAreaInsets.top > 0 ? safeAreaInsets.top : frame.maxY - visibleFrame.maxY
    }
}

// MARK: - Panel

/// One disc's panel. It takes a click and shows the pointing hand without ever becoming key, so Chrome keeps the keyboard.
private final class AgentTokenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a panel that is not key would otherwise only be swallowed by AppKit. This view also reports hover and shows
/// the pointing hand from an always-active tracking area, the way the agent list's rows do, since the panel never becomes key.
private final class AgentTokenHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

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
}

/// What one disc's SwiftUI view reads besides the store: whether the mouse is over the disc, whether the disc is an open
/// slot that the agent's token is still flying to, and the still ring a Reduce Motion serve leaves around it.
@MainActor
final class AgentTokenDiscModel: ObservableObject {
    @Published var isHovered = false
    @Published var isAnOpenSlotAwaitingItsToken: Bool
    /// The ring a serve leaves around the disc when Reduce Motion is on, in the tether's color, or nil.
    @Published var stillRingColor: Color?

    init(isAnOpenSlotAwaitingItsToken: Bool = false) {
        self.isAnOpenSlotAwaitingItsToken = isAnOpenSlotAwaitingItsToken
    }
}

/// One disc's content, shared by the disc in the dock and by the token while it flies there, so the two look the same.
struct AgentTokenDiscContent: View {
    @ObservedObject var store: BackgroundAgentStore
    @ObservedObject var discModel: AgentTokenDiscModel
    let tokenSlot: AgentTokenSlot
    let overflowCount: Int

    var body: some View {
        discView
            .overlay {
                if let stillRingColor = discModel.stillRingColor {
                    Circle()
                        .stroke(stillRingColor, lineWidth: 1.5)
                        .frame(width: AgentTokenMetrics.panelWidth - 2, height: AgentTokenMetrics.panelWidth - 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: DS.Move.send.reduceMotionForm.fadeSeconds), value: discModel.stillRingColor != nil)
            .frame(width: AgentTokenMetrics.panelWidth)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var discView: some View {
        switch tokenSlot {
        case .agent(let agentID):
            if discModel.isAnOpenSlotAwaitingItsToken {
                AgentOpenSlotView()
            } else if let agent = store.agents.first(where: { $0.id == agentID }) {
                AgentTokenDiscView(
                    agent: agent,
                    isWaitingForApproval: store.agentIDsWaitingForApproval.contains(agent.id),
                    isHovered: discModel.isHovered
                )
            }
        case .overflow:
            AgentOverflowDiscView(overflowCount: overflowCount, isHovered: discModel.isHovered)
        }
    }
}

/// A disc on screen: its panel, and the view that fills it.
@MainActor
private final class AgentTokenDisc {
    let panel: AgentTokenPanel
    let hostingView: AgentTokenHostingView<AgentTokenDiscContent>
    let discModel: AgentTokenDiscModel
    /// How many agents the "+N" disc stands for, which its peek card says.
    var overflowCount: Int

    init(
        tokenSlot: AgentTokenSlot,
        overflowCount: Int,
        isAnOpenSlotAwaitingItsToken: Bool,
        store: BackgroundAgentStore,
        onHoverChange: @escaping (Bool) -> Void,
        onRightClick: @escaping (NSEvent) -> Void,
        onClick: @escaping () -> Void
    ) {
        self.overflowCount = overflowCount
        discModel = AgentTokenDiscModel(isAnOpenSlotAwaitingItsToken: isAnOpenSlotAwaitingItsToken)
        hostingView = AgentTokenHostingView(rootView: AgentTokenDiscContent(
            store: store,
            discModel: discModel,
            tokenSlot: tokenSlot,
            overflowCount: overflowCount
        ))
        hostingView.onClick = onClick
        hostingView.onRightClick = onRightClick
        hostingView.onHoverChange = { [discModel] isHovered in
            discModel.isHovered = isHovered
            onHoverChange(isHovered)
        }
        panel = AgentTokenPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar (`.mainMenu`) and its status items, so the disc floats over the strip beside the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = hostingView
    }
}

// MARK: - Dock

/// What a click on one disc reports, so the agent list opens under it.
struct AgentTokenClick {
    let discID: AgentTokenDiscID
    /// The disc's panel, in global AppKit coordinates.
    let discPanelFrame: CGRect
    /// Read when the disc is clicked, since AppKit replaces its screen objects when the screen parameters change.
    let screen: NSScreen
}

/// Keeps one panel per disc on every display whose menu bar shows. It runs only while some agent has a token, and polls
/// the window list once a second then, so discs return when the status icons leave room again.
@MainActor
final class AgentTokenDockController {
    private let store: BackgroundAgentStore
    private let onDiscClicked: (AgentTokenClick) -> Void
    private var discsByID: [AgentTokenDiscID: AgentTokenDisc] = [:]
    /// The agents each display's discs showed at the last refresh, which is what keeps a shown token in its position.
    private var shownAgentIDsByDisplayID: [CGDirectDisplayID: [UUID]] = [:]
    /// The front app's menu titles, read when it became the front app, and the app they belong to.
    private var frontAppMenuTitleFrames: [CGRect] = []
    private var frontAppMenuTitleProcessIdentifier: pid_t?
    private var menuTitleReadIsRunning = false
    private var pollTimer: Timer?
    private var observers: [Any] = []
    private var storeCancellable: AnyCancellable?
    /// The token that flies to its slot right now, and the disc it lands on. Nil when no serve runs.
    private var flight: CarrierFlight?
    private var discIDTheFlightLandsOn: AgentTokenDiscID?
    /// The flight that has landed but whose token is still over its disc for a moment, and that disc. The disc waits to slide
    /// to close a gap until the carried token has left (`agentTokenDiscMustWaitForItsFlight`).
    private var lingeringFlight: CarrierFlight?
    private var discIDTheLingeringFlightSitsOn: AgentTokenDiscID?
    /// Callers waiting for the token to land (`waitForTheServeToLand`).
    private var callersWaitingForTheLanding: [CheckedContinuation<Void, Never>] = []
    /// True once a disc had to wait under a flight and may slide when the carried token leaves. The landed token's tether
    /// would then end where the disc used to be, so it ends first (`forgetTheLingeringFlight`).
    private var aDiscWaitedToSlideUnderTheFlight = false
    /// The Bring back sparks in the air, so a push-to-talk press can land them.
    private var bringBackFlights: [CarrierFlight] = []
    private let peekController = AgentTokenPeekController()
    /// The disc the peek card shows for, or the one whose hover is waiting to show it.
    private var discIDOfThePeek: AgentTokenDiscID?
    private var peekDelayTask: Task<Void, Never>?
    /// How long the mouse rests on a disc before its peek shows, so sweeping across the discs shows nothing.
    private static let secondsBeforeThePeekShows: TimeInterval = 0.3

    /// The serve's tether line takes the color of the cursor it leaves, which is the shown theme's accent.
    private let themeSettings: CompanionThemeSettings
    private let menuActions: AgentDiscMenuActions

    init(
        store: BackgroundAgentStore,
        themeSettings: CompanionThemeSettings,
        menuActions: AgentDiscMenuActions,
        onDiscClicked: @escaping (AgentTokenClick) -> Void
    ) {
        self.store = store
        self.themeSettings = themeSettings
        self.menuActions = menuActions
        self.onDiscClicked = onDiscClicked
    }

    func start() {
        // A store change publishes before the change lands, so the refresh waits one turn of the main run loop.
        storeCancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }

    func stop() {
        storeCancellable = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        removeEveryDisc()
        stopPolling()
    }

    // MARK: Refresh

    /// - `discIDAwaitingTheServe`: a new disc to make as an open slot, hidden until its token lands (`startServingTheToken`),
    ///   in place of the usual fade-in.
    private func refresh(discIDAwaitingTheServe: AgentTokenDiscID? = nil) {
        let now = Date()
        let rankedAgents = agentsWithTokens(from: store.agents, at: now)
        guard !rankedAgents.isEmpty else {
            removeEveryDisc()
            stopPolling()
            return
        }
        startPollingIfNeeded()
        readTheFrontAppMenuTitlesIfTheAppChanged()

        let rankedAgentIDs = rankedAgents.map(\.id)
        let statusWindowFrames = onScreenStatusWindowFramesInQuartzCoordinates()
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        var discIDsOnScreen: Set<AgentTokenDiscID> = []

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            guard menuBarIsShowing(screenFrame: screen.frame, visibleFrame: screen.visibleFrame) else {
                shownAgentIDsByDisplayID[displayID] = nil
                continue
            }
            let menuBarHeight = screen.menuBarHeight
            let freeSpaceMinX = agentTokenFreeSpaceMinX(
                notchMaxX: screen.notchEdgesX?.maxX,
                screenMidX: screen.frame.midX,
                lastMenuTitleMaxX: lastMenuTitleMaxX(on: screen)
            )
            let menuBarStripInQuartzCoordinates = CGRect(
                x: screen.frame.minX,
                y: mainDisplayHeight - screen.frame.maxY,
                width: screen.frame.width,
                height: menuBarHeight
            )
            let endOfFreeSpaceX = firstStatusIconMinX(
                statusWindowFrames: statusWindowFrames,
                menuBarStrip: menuBarStripInQuartzCoordinates,
                rightOf: freeSpaceMinX
            ) ?? screen.frame.maxX
            let layout = agentTokenLayout(
                previouslyShownAgentIDs: shownAgentIDsByDisplayID[displayID] ?? [],
                rankedAgentIDs: rankedAgentIDs,
                positionCount: agentTokenPositionCount(freeSpaceMinX: freeSpaceMinX, endOfFreeSpaceX: endOfFreeSpaceX)
            )
            shownAgentIDsByDisplayID[displayID] = layout.shownAgentIDs

            var tokenSlotsLeftToRight = layout.shownAgentIDs.map(AgentTokenSlot.agent)
            if layout.overflowCount > 0 { tokenSlotsLeftToRight.append(.overflow) }
            for (position, tokenSlot) in tokenSlotsLeftToRight.enumerated() {
                let discLeftEdgeX = freeSpaceMinX + AgentTokenMetrics.spaceBeforeTheFirstDisc + CGFloat(position) * AgentTokenMetrics.panelWidth
                let panelFrame = CGRect(
                    x: discLeftEdgeX - AgentTokenMetrics.gapBetweenDiscs / 2,
                    y: screen.frame.maxY - menuBarHeight,
                    width: AgentTokenMetrics.panelWidth,
                    height: menuBarHeight
                )
                let discID = AgentTokenDiscID(displayID: displayID, tokenSlot: tokenSlot)
                discIDsOnScreen.insert(discID)
                place(
                    discID: discID,
                    overflowCount: layout.overflowCount,
                    panelFrame: panelFrame,
                    isAnOpenSlotAwaitingItsToken: discID == discIDAwaitingTheServe
                )
            }
        }

        for (discID, disc) in discsByID where !discIDsOnScreen.contains(discID) {
            remove(disc)
            discsByID[discID] = nil
        }
        // A token cannot land on a disc that left, such as an agent cancelled mid-flight.
        if let discIDTheFlightLandsOn, !discIDsOnScreen.contains(discIDTheFlightLandsOn) {
            landTheServeAtOnce()
        }
        // A display that is gone or shows no disc forgets its positions, so the next tokens start from the left again.
        for displayID in shownAgentIDsByDisplayID.keys where !discIDsOnScreen.contains(where: { $0.displayID == displayID }) {
            shownAgentIDsByDisplayID[displayID] = nil
        }
    }

    private var reduceMotionIsOn: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Moves a disc's panel to its position, or creates it there. A new disc fades in at its position, and the others slide
    /// to close a gap. With Reduce Motion on, a disc just appears in its position. A disc made for a serve starts as an open
    /// slot that stays hidden until `startServingTheToken` decides how its token arrives.
    private func place(discID: AgentTokenDiscID, overflowCount: Int, panelFrame: CGRect, isAnOpenSlotAwaitingItsToken: Bool) {
        if let existingDisc = discsByID[discID] {
            if case .overflow = discID.tokenSlot {
                existingDisc.overflowCount = overflowCount
                existingDisc.hostingView.rootView = AgentTokenDiscContent(store: store, discModel: existingDisc.discModel, tokenSlot: .overflow, overflowCount: overflowCount)
            }
            guard existingDisc.panel.frame != panelFrame else { return }
            // The slide happens when the carried token leaves, which refreshes the dock (`forgetTheLingeringFlight`).
            guard !agentTokenDiscMustWaitForItsFlight(discID, flightLandsOn: discIDTheFlightLandsOn, lingeringFlightSitsOn: discIDTheLingeringFlightSitsOn) else {
                aDiscWaitedToSlideUnderTheFlight = true
                return
            }
            if reduceMotionIsOn {
                existingDisc.panel.setFrame(panelFrame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { animationContext in
                    animationContext.duration = 0.2
                    existingDisc.panel.animator().setFrame(panelFrame, display: true)
                }
            }
            return
        }

        let displayedDisc = AgentTokenDisc(
            tokenSlot: discID.tokenSlot,
            overflowCount: overflowCount,
            isAnOpenSlotAwaitingItsToken: isAnOpenSlotAwaitingItsToken,
            store: store,
            onHoverChange: { [weak self] isHovered in self?.discHoverChanged(discID, isHovered: isHovered) },
            onRightClick: { [weak self] event in self?.showTheMenu(ofDiscWithID: discID, for: event) },
            onClick: { [weak self] in self?.clickDisc(withID: discID) }
        )
        displayedDisc.panel.setFrame(panelFrame, display: false)
        discsByID[discID] = displayedDisc
        if isAnOpenSlotAwaitingItsToken {
            displayedDisc.panel.alphaValue = 0
            displayedDisc.panel.orderFrontRegardless()
        } else if reduceMotionIsOn {
            displayedDisc.panel.orderFrontRegardless()
        } else {
            displayedDisc.panel.alphaValue = 0
            displayedDisc.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.2
                displayedDisc.panel.animator().alphaValue = 1
            }
        }
    }

    private func remove(_ disc: AgentTokenDisc) {
        if let discID = discsByID.first(where: { $0.value === disc })?.key, discID == discIDOfThePeek { hideThePeek() }
        if reduceMotionIsOn {
            disc.panel.orderOut(nil)
            disc.panel.contentView = nil
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.2
            disc.panel.animator().alphaValue = 0
        } completionHandler: {
            disc.panel.orderOut(nil)
            // Dropping the view stops its ring's animation.
            disc.panel.contentView = nil
        }
    }

    private func removeEveryDisc() {
        finishTheServeAtOnce()
        hideThePeek()
        for disc in discsByID.values { remove(disc) }
        discsByID = [:]
        shownAgentIDsByDisplayID = [:]
    }

    // MARK: Serve

    /// Serves a new agent's token: it flies from the blue cursor glyph to its slot on the display the mouse is on, and the
    /// dock shows it in place. Call this right after the agent starts, in the same turn, before the dock has made its disc.
    /// The disc on the mouse's display is made now as an open slot, so it never fades in on its own first.
    /// With Reduce Motion on, the token fades in at its slot instead. An agent with no slot of its own, or a display with
    /// no room for discs, gets no serve (`agentTokenServePlan`). `waitForTheServeToLand` returns once the token has landed.
    /// The discs on the other displays fade in as usual.
    func startServingTheToken(of agentID: UUID) {
        finishTheServeAtOnce()
        let mouseLocation = NSEvent.mouseLocation
        let displayFramesByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.displayID, $0.frame) })
        guard let cursorDisplayID = agentTokenServeDisplayID(containing: mouseLocation, displayFrames: displayFramesByID) else { return }

        let slotDiscID = AgentTokenDiscID(displayID: cursorDisplayID, tokenSlot: .agent(agentID))
        refresh(discIDAwaitingTheServe: slotDiscID)

        let slotDisc = discsByID[slotDiscID]
        let plan = agentTokenServePlan(
            cursorPoint: agentTokenServeStartPoint(mouseLocation: mouseLocation),
            slotPoint: slotDisc.map { CGPoint(x: $0.panel.frame.midX, y: $0.panel.frame.midY) },
            slotDisplayCanShowDiscs: discsByID.keys.contains { $0.displayID == cursorDisplayID },
            reduceMotionIsOn: reduceMotionIsOn
        )
        // A disc made for the serve exists exactly when the plan is not "none".
        guard let slotDisc else {
            print("Agent token serve: no serve, the agent has no slot on the display the mouse is on")
            return
        }
        switch plan {
        case .none:
            return
        case .fadeInAtTheSlot:
            print("Agent token serve: Reduce Motion is on, so the token fades in at its slot with a still ring")
            slotDisc.discModel.isAnOpenSlotAwaitingItsToken = false
            // The move's Reduce Motion form: a fade in at the target that leaves a still ring there, in the tether's color.
            slotDisc.discModel.stillRingColor = themeSettings.shownTheme.cursorColor
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = DS.Move.send.reduceMotionForm.fadeSeconds
                slotDisc.panel.animator().alphaValue = 1
            }
            let stillRingModel = slotDisc.discModel
            DispatchQueue.main.asyncAfter(deadline: .now() + agentTokenServeStillRingSeconds) { stillRingModel.stillRingColor = nil }
        case .fly(let path):
            print("Agent token serve: the token flies to its slot in \(AgentTokenServePath.flightSeconds) s")
            slotDisc.panel.alphaValue = 1
            // The token flies in a square as wide as a disc's own panel, so its shadow fits and its center is the slot's.
            let tokenSide = AgentTokenMetrics.panelWidth
            discIDTheFlightLandsOn = slotDiscID
            flight = TetherCarrier.shared.play(
                .send(along: path, carriedSize: CGSize(width: tokenSide, height: tokenSide)),
                carrying: AgentTokenDiscContent(store: store, discModel: AgentTokenDiscModel(), tokenSlot: .agent(agentID), overflowCount: 0),
                onDisplay: cursorDisplayID,
                tetherColor: NSColor(themeSettings.shownTheme.cursorColor),
                onLanded: { [weak self] in self?.landTheToken(onDiscWithID: slotDiscID) },
                onGone: { [weak self] goneFlight in self?.forgetTheLingeringFlight(goneFlight) }
            )
        }
    }

    /// Returns once the token that is flying has landed, or at once when none flies. The router's spoken confirmation waits
    /// here, so the learner sees the hand-off before the voice speaks.
    func waitForTheServeToLand() async {
        guard flight != nil else { return }
        let waitStartedAt = Date()
        await withCheckedContinuation { callersWaitingForTheLanding.append($0) }
        print("Agent token serve: the spoken line waited \(Int(Date().timeIntervalSince(waitStartedAt) * 1000)) ms for the token to land")
    }

    /// A push-to-talk press ends the flight at once, and the token shows in its slot. It lands a Bring back spark too, and the
    /// chip it carries shows at once.
    func finishTheServeAtOnce() {
        landTheServeAtOnce()
        for bringBackFlight in bringBackFlights { bringBackFlight.landAtOnce() }
    }

    private func landTheServeAtOnce() {
        guard let flight else { return }
        print("Agent token serve: the token lands at once")
        flight.landAtOnce()
    }

    private func landTheToken(onDiscWithID discID: AgentTokenDiscID) {
        print("Agent token serve: the token landed in its slot")
        discsByID[discID]?.discModel.isAnOpenSlotAwaitingItsToken = false
        lingeringFlight = flight
        discIDTheLingeringFlightSitsOn = discID
        flight = nil
        discIDTheFlightLandsOn = nil
        let callersToResume = callersWaitingForTheLanding
        callersWaitingForTheLanding = []
        for callerToResume in callersToResume { callerToResume.resume() }
    }

    /// The flight's token has left the screen, so the disc under it may slide now if the layout moved it meanwhile. A newer
    /// flight that landed since stays.
    private func forgetTheLingeringFlight(_ goneFlight: CarrierFlight) {
        guard lingeringFlight === goneFlight else { return }
        lingeringFlight = nil
        discIDTheLingeringFlightSitsOn = nil
        // A disc that waited slides now, so the line, which still fades for a moment, must not end at its old place.
        if aDiscWaitedToSlideUnderTheFlight {
            goneFlight.endTheTetherNow()
            aDiscWaitedToSlideUnderTheFlight = false
        }
        refresh()
    }

    // MARK: Bring back

    /// Brings an ended agent's result back to the cursor: a spark runs from its disc along the top edge, then down to the
    /// cursor, tethered in the agent's color, and `showTheChip` runs as it lands, so the chip pops where the spark ends. With
    /// Reduce Motion on, a still ring fades in at the cursor instead. An agent with no disc on the mouse's display, a display
    /// with no discs, or a display that is gone gets no spark, and the chip shows at once. A push-to-talk press lands the
    /// spark at once (`finishTheServeAtOnce`).
    func bringBack(agentID: UUID, in agentColor: Color, showTheChip: @escaping () -> Void) {
        let mouseLocation = NSEvent.mouseLocation
        let displayFramesByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.displayID, $0.frame) })
        guard let cursorDisplayID = agentTokenServeDisplayID(containing: mouseLocation, displayFrames: displayFramesByID),
              let screen = NSScreen.screens.first(where: { $0.displayID == cursorDisplayID }),
              let disc = discsByID[AgentTokenDiscID(displayID: cursorDisplayID, tokenSlot: .agent(agentID))],
              disc.panel.isVisible else {
            print("Agent token bring back: no disc on the display the mouse is on, so the chip shows at once")
            showTheChip()
            return
        }
        let cursorPoint = agentTokenServeStartPoint(mouseLocation: mouseLocation)
        let carrierFlight: CarrierFlight
        let onGone: (CarrierFlight) -> Void = { [weak self] goneFlight in self?.bringBackFlights.removeAll { $0 === goneFlight } }
        if reduceMotionIsOn {
            print("Agent token bring back: Reduce Motion is on, so a still ring fades in at the cursor")
            let ringSide = AgentBringBackRingView.diameter + 4
            carrierFlight = TetherCarrier.shared.play(
                .bringBackWithReduceMotion(at: cursorPoint, ringSize: CGSize(width: ringSide, height: ringSide)),
                carrying: AgentBringBackRingView(color: agentColor).frame(width: ringSide, height: ringSide),
                onDisplay: cursorDisplayID,
                tetherColor: NSColor(agentColor),
                onLanded: showTheChip,
                onGone: onGone
            )
        } else {
            let route = agentTokenBringBackPath(from: CGPoint(x: disc.panel.frame.midX, y: disc.panel.frame.midY), to: cursorPoint, onScreenWithFrame: screen.frame)
            print("Agent token bring back: the spark runs from its disc to the cursor in \(AgentTokenBringBackPath.flightSeconds) s")
            let sparkSide = AgentBringBackSparkView.diameter + 6
            carrierFlight = TetherCarrier.shared.play(
                .bringBack(along: route, sparkSize: CGSize(width: sparkSide, height: sparkSide)),
                carrying: AgentBringBackSparkView(color: agentColor).frame(width: sparkSide, height: sparkSide),
                onDisplay: cursorDisplayID,
                tetherColor: NSColor(agentColor),
                onLanded: showTheChip,
                onGone: onGone
            )
        }
        bringBackFlights.append(carrierFlight)
    }

    // MARK: Click, hover, and right click

    private func clickDisc(withID discID: AgentTokenDiscID) {
        hideThePeek()
        guard let clickedDisc = discsByID[discID],
              let screen = NSScreen.screens.first(where: { $0.displayID == discID.displayID }) else { return }
        onDiscClicked(AgentTokenClick(discID: discID, discPanelFrame: clickedDisc.panel.frame, screen: screen))
    }

    /// The mouse rests on a disc: its peek card shows after a short wait. It leaves: the card goes.
    private func discHoverChanged(_ discID: AgentTokenDiscID, isHovered: Bool) {
        peekDelayTask?.cancel()
        guard isHovered else {
            if discIDOfThePeek == discID { hideThePeek() }
            return
        }
        discIDOfThePeek = discID
        peekDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.secondsBeforeThePeekShows))
            guard !Task.isCancelled, let self else { return }
            self.showThePeek(forDiscWithID: discID)
        }
    }

    private func showThePeek(forDiscWithID discID: AgentTokenDiscID) {
        guard let disc = discsByID[discID],
              let screen = NSScreen.screens.first(where: { $0.displayID == discID.displayID }) else { return }
        let store = store
        let contentAt: (Date) -> AgentTokenPeekContent?
        let accentColor: Color
        switch discID.tokenSlot {
        case .agent(let agentID):
            accentColor = store.agents.first(where: { $0.id == agentID })?.displayColor.color ?? DS.Colors.textSecondary
            contentAt = { now in
                guard let agent = store.agents.first(where: { $0.id == agentID }) else { return nil }
                return agentTokenPeekContent(
                    for: agent,
                    approvalCapability: store.approvalCapabilitiesByAgentID[agentID],
                    isWaitingForApproval: store.agentIDsWaitingForApproval.contains(agentID),
                    at: now
                )
            }
        case .overflow:
            accentColor = DS.Colors.textSecondary
            let overflowCount = disc.overflowCount
            contentAt = { _ in agentTokenOverflowPeekContent(overflowCount: overflowCount) }
        }
        discIDOfThePeek = discID
        peekController.show(contentAt: contentAt, accentColor: accentColor, discPanelFrame: disc.panel.frame, on: screen)
    }

    private func hideThePeek() {
        peekDelayTask?.cancel()
        peekDelayTask = nil
        discIDOfThePeek = nil
        peekController.hide()
    }

    /// Pops the disc's right-click menu: the actions of the agent list's row, one click from the disc.
    private func showTheMenu(ofDiscWithID discID: AgentTokenDiscID, for event: NSEvent) {
        guard let disc = discsByID[discID] else { return }
        hideThePeek()
        let agent: BackgroundAgent?
        var isWaitingForApproval = false
        if case .agent(let agentID) = discID.tokenSlot {
            agent = store.agents.first { $0.id == agentID }
            isWaitingForApproval = store.agentIDsWaitingForApproval.contains(agentID)
        } else {
            agent = nil
        }
        let menuItems = agentDiscMenuItems(for: agent, isWaitingForApproval: isWaitingForApproval, aVideoQuizQuestionIsOpen: store.aVideoQuizQuestionIsOpen)
        let menu = NSMenu()
        for menuItem in menuItems {
            if menuItem == .cancelAgent, !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(AgentDiscClosureMenuItem(title: menuItem.title) { [weak self] in
                self?.run(menuItem, forDiscWithID: discID, agent: agent)
            })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: disc.hostingView)
    }

    private func run(_ menuItem: AgentDiscMenuItem, forDiscWithID discID: AgentTokenDiscID, agent: BackgroundAgent?) {
        switch menuItem {
        case .reviewRequest, .openAgentList: clickDisc(withID: discID)
        case .showReadyScene: menuActions.showReadyScene()
        case .hearAnswer: menuActions.hearTaskAnswer()
        case .openPage:
            if let pageURL = agent?.finishedResult?.pageURL { NSWorkspace.shared.open(pageURL) }
        case .cancelAgent:
            if let agent { menuActions.cancelAgent(agent.id) }
        }
    }

    // MARK: Polling

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Front app menus

    /// The right edge of the front app's last menu title that sits on this screen, or nil when none does.
    private func lastMenuTitleMaxX(on screen: NSScreen) -> CGFloat? {
        frontAppMenuTitleFrames
            .filter { $0.midX >= screen.frame.minX && $0.midX < screen.frame.maxX }
            .map(\.maxX)
            .max()
    }

    /// Reads the front app's menu titles once each time the front app changes, which is when its menus change. The read
    /// runs off the main thread, and a refresh follows it.
    private func readTheFrontAppMenuTitlesIfTheAppChanged() {
        guard let frontApplication = NSWorkspace.shared.frontmostApplication,
              frontApplication.processIdentifier != frontAppMenuTitleProcessIdentifier,
              !menuTitleReadIsRunning else { return }
        let processIdentifier = frontApplication.processIdentifier
        menuTitleReadIsRunning = true
        Task.detached(priority: .utility) {
            let readMenuTitleFrames = menuTitleFrames(ofApplicationWithProcessIdentifier: processIdentifier)
            await MainActor.run {
                self.frontAppMenuTitleFrames = readMenuTitleFrames
                self.frontAppMenuTitleProcessIdentifier = processIdentifier
                self.menuTitleReadIsRunning = false
                self.refresh()
            }
        }
    }
}

/// A menu item that runs a closure, since the panel that pops the menu is never key and has no responder chain to send to.
private final class AgentDiscClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Created in code only") }

    @objc private func run() { handler() }
}

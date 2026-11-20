//
//  AgentTokenFlight.swift
//  leanring-buddy
//
//  The token in flight: a click-through panel, just big enough to hold the whole arc, that carries one agent's disc from the
//  blue cursor to its slot beside the notch (`AgentTokenServePath`). It draws the same disc the dock shows, so the token the
//  learner sees leave the cursor is the token that lands. A Core Animation keyframe animation moves the disc, so the render
//  server plays it. The main thread can stall for a few hundred milliseconds right after an agent starts (the build reads
//  Chrome through Apple Events), and a timer on the main thread would freeze the token mid-flight and then jump.
//

import AppKit
import SwiftUI

/// The panel that carries the token. It ignores the mouse, so a click during the flight reaches the window under it.
private final class AgentTokenFlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentTokenFlight {
    private let path: AgentTokenServePath
    private let panel: AgentTokenFlightPanel
    /// The view that holds the disc. Its frame sits at the slot, and the animation moves it from the cursor to there.
    private let carrierView: NSView
    private let onLanded: () -> Void
    private var hasLanded = false

    /// The carrier is as wide as a disc's own panel and as tall, so the disc's shadow fits and its center is the carrier's.
    private static let carrierSide = AgentTokenMetrics.panelWidth

    /// How long the flying panel stays over the dock's disc after the landing, so the disc has drawn its token underneath
    /// before the flying one goes, and the learner never sees the slot's outline again.
    private static let secondsTheFlyingPanelStaysAfterLanding: TimeInterval = 0.05

    /// How long past its half second a flight may take before it lands anyway.
    private static let secondsBeforeAStuckFlightLands: TimeInterval = 1

    /// The animation's keyframes: this many steps along the path, each moved to in a straight line. At 60 frames a second a
    /// half second flight has 30 frames, so a step is about one frame and the straight lines read as the curve.
    private static let keyframeStepCount = 30

    /// - `onLanded`: called once, when the token reaches its slot or when `landAtOnce` ends the flight early.
    init(path: AgentTokenServePath, agentID: UUID, store: BackgroundAgentStore, onLanded: @escaping () -> Void) {
        self.path = path
        self.onLanded = onLanded

        // The curve stays inside the box of its three points, so this box holds the whole flight and the disc around it.
        let flightBox = CGRect(
            x: min(path.start.x, path.control.x, path.end.x),
            y: min(path.start.y, path.control.y, path.end.y),
            width: max(path.start.x, path.control.x, path.end.x) - min(path.start.x, path.control.x, path.end.x),
            height: max(path.start.y, path.control.y, path.end.y) - min(path.start.y, path.control.y, path.end.y)
        ).insetBy(dx: -Self.carrierSide, dy: -Self.carrierSide)

        panel = AgentTokenFlightPanel(
            contentRect: flightBox,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Two above the cursor overlay windows (one above `.screenSaver`), so the token draws over the blue cursor it leaves.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true

        let flightView = NSView(frame: CGRect(origin: .zero, size: flightBox.size))
        flightView.wantsLayer = true
        carrierView = NSView(frame: CGRect(
            x: path.end.x - flightBox.minX - Self.carrierSide / 2,
            y: path.end.y - flightBox.minY - Self.carrierSide / 2,
            width: Self.carrierSide,
            height: Self.carrierSide
        ))
        carrierView.wantsLayer = true
        let hostingView = NSHostingView(rootView: AgentTokenDiscContent(
            store: store,
            discModel: AgentTokenDiscModel(),
            tokenSlot: .agent(agentID),
            overflowCount: 0
        ))
        hostingView.frame = carrierView.bounds
        hostingView.autoresizingMask = [.width, .height]
        carrierView.addSubview(hostingView)
        flightView.addSubview(carrierView)
        panel.contentView = flightView
    }

    func start() {
        // The carrier rests at the slot, which is where the flight ends. The animation adds an offset from there that begins at
        // the cursor and shrinks to nothing, so no frame of the flight depends on anything but the render server's clock.
        let offsetsFromTheSlot = (0...Self.keyframeStepCount).map { stepIndex -> NSValue in
            let point = path.point(atFlightProgress: Double(stepIndex) / Double(Self.keyframeStepCount))
            return NSValue(point: CGPoint(x: point.x - path.end.x, y: point.y - path.end.y))
        }
        let flightAnimation = CAKeyframeAnimation(keyPath: "position")
        flightAnimation.values = offsetsFromTheSlot
        flightAnimation.calculationMode = .linear
        flightAnimation.isAdditive = true
        flightAnimation.duration = AgentTokenServePath.flightSeconds

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.land() }
        }
        carrierView.layer?.add(flightAnimation, forKey: "serve")
        CATransaction.commit()
        // The animation is added before the panel shows, so the first frame the learner sees has the token at the cursor.
        panel.orderFrontRegardless()
        // The router's confirmation waits for the landing, so a flight whose completion never reports, such as one on a display
        // that went to sleep, still ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentTokenServePath.flightSeconds + Self.secondsBeforeAStuckFlightLands) { [weak self] in
            self?.land()
        }
    }

    /// Ends the flight where it is, as a push-to-talk press does. The token shows in its slot at once.
    func landAtOnce() {
        land()
    }

    private func land() {
        guard !hasLanded else { return }
        hasLanded = true
        carrierView.layer?.removeAllAnimations()
        onLanded()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondsTheFlyingPanelStaysAfterLanding) { [panel] in
            panel.orderOut(nil)
            // Dropping the view stops its ring's animation.
            panel.contentView = nil
        }
    }
}

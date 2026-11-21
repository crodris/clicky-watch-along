//
//  AgentTokenPeek.swift
//  leanring-buddy
//
//  The peek: hovering a disc in the menu bar shows a small Card 8 points below it that says what that agent is doing, so the
//  learner never has to open the agent list to look. It glides 8 points down into place on the Glide move, and with Reduce
//  Motion on it only crossfades. The card reads the agent's name, its state, and a hint for what a click or a right click
//  does. It never shows an approval's summary, since a web page or a server may have written it: it names only the capability
//  the request needs.
//
//  This file holds the pure content and placement rules, the card's view, and the panel that shows it. The dock
//  (`AgentTokenDockController`) decides when to show it. The card never takes the mouse, so hovering it cannot end the hover
//  that showed it.
//

import AppKit
import SwiftUI

// MARK: - Content

/// How the peek's second line reads.
enum AgentTokenPeekCaptionStyle: Equatable {
    case plain
    /// An approval waits: the amber of the "!" face.
    case needsYourOK
    case failed
}

/// The segments of the progress meter under a running agent's text: one per step, lit up to and including the current one.
struct AgentTokenPeekMeter: Equatable {
    let stepCount: Int
    let litStepCount: Int
}

/// What the peek says about one disc.
struct AgentTokenPeekContent: Equatable {
    let title: String
    let caption: String
    let captionStyle: AgentTokenPeekCaptionStyle
    /// A third, dimmer line about what to do next, or nil.
    let hint: String?
    let meter: AgentTokenPeekMeter?
}

/// What an approval request needs, in words that name no tool and no page: the capability is all the peek may read.
func agentTokenPeekApprovalCaption(for capability: HarnessCapability?) -> String {
    switch capability {
    case .sends: return "Needs your OK to send something"
    case .deletes: return "Needs your OK to delete something"
    case .spends: return "Needs your OK to spend something"
    case .readsPrivate: return "Needs your OK to read private data"
    case .unknown, nil: return "Needs your OK"
    }
}

/// The longest a failed agent's reason runs in the peek, in characters, so one long error never makes a tall card.
let agentTokenPeekLongestReason = 80

/// What the peek says about an agent's disc at `now`.
///
/// - `approvalCapability`: the capability of the agent's waiting approval request, or nil when none waits.
func agentTokenPeekContent(for agent: BackgroundAgent, approvalCapability: HarnessCapability?, isWaitingForApproval: Bool, at now: Date) -> AgentTokenPeekContent {
    let title = [agent.kind.displayName, agent.subject.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
    if isWaitingForApproval {
        return AgentTokenPeekContent(
            title: title,
            caption: agentTokenPeekApprovalCaption(for: approvalCapability),
            captionStyle: .needsYourOK,
            hint: "Click to review, or say yes or no",
            meter: nil
        )
    }
    switch agent.phase {
    case .running(let completedStepCount):
        let stepNames = agent.stepNames
        // A task agent is on its latest reported step, and every other kind is on the step after the ones it completed.
        let currentStepIndex = agent.kind == .task ? max(0, stepNames.count - 1) : min(completedStepCount, max(0, stepNames.count - 1))
        let currentStepName = stepNames.indices.contains(currentStepIndex) ? stepNames[currentStepIndex] : "Working"
        return AgentTokenPeekContent(
            title: title,
            caption: "\(currentStepName) · \(backgroundAgentElapsedTimeText(seconds: agent.elapsedSeconds(at: now)))",
            captionStyle: .plain,
            hint: nil,
            meter: AgentTokenPeekMeter(stepCount: stepNames.count, litStepCount: currentStepIndex + 1)
        )
    case .finished(let result):
        return AgentTokenPeekContent(title: title, caption: finishedCaption(for: agent, result: result), captionStyle: .plain, hint: finishedHint(for: result), meter: nil)
    case .failed(let reason):
        let shortReason = reason.count > agentTokenPeekLongestReason ? String(reason.prefix(agentTokenPeekLongestReason)) + "…" : reason
        return AgentTokenPeekContent(title: title, caption: "Couldn't finish", captionStyle: .failed, hint: shortReason.isEmpty ? nil : shortReason, meter: nil)
    case .cancelled:
        return AgentTokenPeekContent(title: title, caption: "Cancelled", captionStyle: .plain, hint: nil, meter: nil)
    }
}

private func finishedCaption(for agent: BackgroundAgent, result: BackgroundAgentResult) -> String {
    switch result {
    case .notionPage:
        return "Ready"
    case .readyScene:
        return agent.resultIsWaitingToBeDelivered ? "Ready · say \"\(agent.kind.waitingPhrase)\"" : "Ready"
    case .answer:
        return agent.resultIsWaitingToBeDelivered ? "Done · say what did you find" : "Done"
    }
}

private func finishedHint(for result: BackgroundAgentResult) -> String? {
    result.pageURL == nil ? nil : "Right-click to open the page"
}

/// What the peek says about the "+N" disc.
func agentTokenOverflowPeekContent(overflowCount: Int) -> AgentTokenPeekContent {
    AgentTokenPeekContent(
        title: "\(overflowCount) more \(overflowCount == 1 ? "agent" : "agents")",
        caption: "Click to open the agent list",
        captionStyle: .plain,
        hint: nil,
        meter: nil
    )
}

// MARK: - Placement

/// How far the card sits below the disc's panel, which is as tall as the menu bar.
let agentTokenPeekGapBelowTheMenuBar: CGFloat = 8
/// The card's width, which fits its longest line, "Needs your OK to read private data", on one line.
let agentTokenPeekCardWidth: CGFloat = 244
/// The room around the card for its shadow, which reaches about 38 points below and 24 to each side.
let agentTokenPeekShadowMargin: CGFloat = 40
/// How far the card keeps from the display's side edges.
let agentTokenPeekSideMargin: CGFloat = 8

/// The card's frame in global AppKit coordinates: `agentTokenPeekGapBelowTheMenuBar` under the disc's panel, centered on the
/// disc, and moved sideways as far as it needs to stay on the display.
func agentTokenPeekCardFrame(cardHeight: CGFloat, discPanelFrame: CGRect, screenFrame: CGRect) -> CGRect {
    let wantedMinX = discPanelFrame.midX - agentTokenPeekCardWidth / 2
    let leastMinX = screenFrame.minX + agentTokenPeekSideMargin
    let greatestMinX = screenFrame.maxX - agentTokenPeekSideMargin - agentTokenPeekCardWidth
    let cardMinX = min(max(wantedMinX, leastMinX), max(leastMinX, greatestMinX))
    return CGRect(
        x: cardMinX,
        y: discPanelFrame.minY - agentTokenPeekGapBelowTheMenuBar - cardHeight,
        width: agentTokenPeekCardWidth,
        height: cardHeight
    )
}

// MARK: - Card

/// The peek card. `contentAt` is read each second, so a running agent's elapsed time moves while the card is up.
struct AgentTokenPeekCardView: View {
    let contentAt: (Date) -> AgentTokenPeekContent?
    let accentColor: Color
    /// The distance the card glides down as it appears, which Reduce Motion drops.
    static let glideDistance: CGFloat = 8

    @State private var hasGlidedIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotionIsOn

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let content = contentAt(timeline.date) {
                cardBody(content)
            }
        }
        .padding(agentTokenPeekShadowMargin)
        .opacity(hasGlidedIn ? 1 : 0)
        .offset(y: hasGlidedIn || reduceMotionIsOn ? 0 : -Self.glideDistance)
        .onAppear {
            withAnimation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotionIsOn)) { hasGlidedIn = true }
        }
    }

    private func cardBody(_ content: AgentTokenPeekContent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(content.title)
                .font(DS.TypeScale.title.font)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Text(content.caption)
                .font(DS.TypeScale.caption.font)
                .foregroundColor(captionColor(content.captionStyle))
                .lineLimit(1)
            if let meter = content.meter {
                HStack(spacing: 3) {
                    ForEach(0..<meter.stepCount, id: \.self) { stepIndex in
                        Capsule()
                            .fill(stepIndex < meter.litStepCount ? accentColor : DS.Colors.agentTokenTrack)
                            .frame(height: 3)
                    }
                }
                .padding(.top, 4)
            }
            if let hint = content.hint {
                Text(hint)
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
            }
        }
        .frame(width: agentTokenPeekCardWidth - 24, alignment: .leading)
        .padding(12)
        .tetherCard()
    }

    private func captionColor(_ style: AgentTokenPeekCaptionStyle) -> Color {
        switch style {
        case .plain: return DS.Colors.textSecondary
        case .needsYourOK: return DS.Colors.warningText
        case .failed: return DS.Colors.destructiveText
        }
    }
}

// MARK: - Panel

/// The panel that shows the peek card. It takes no mouse events, so the disc under the pointer keeps its hover.
@MainActor
final class AgentTokenPeekController {
    private var panel: NSPanel?

    /// Above the discs (`.mainMenu + 3`).
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Shows the card under a disc, replacing a card that shows now.
    func show(contentAt: @escaping (Date) -> AgentTokenPeekContent?, accentColor: Color, discPanelFrame: CGRect, on screen: NSScreen) {
        hide(animated: false)
        let hostingView = NSHostingView(rootView: AgentTokenPeekCardView(contentAt: contentAt, accentColor: accentColor))
        let fittingSize = hostingView.fittingSize
        let cardHeight = fittingSize.height - 2 * agentTokenPeekShadowMargin
        let cardFrame = agentTokenPeekCardFrame(cardHeight: cardHeight, discPanelFrame: discPanelFrame, screenFrame: screen.frame)
        let windowFrame = cardFrame.insetBy(dx: -agentTokenPeekShadowMargin, dy: -agentTokenPeekShadowMargin)
        hostingView.frame = CGRect(origin: .zero, size: windowFrame.size)

        let peekPanel = NSPanel(contentRect: windowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        peekPanel.isOpaque = false
        peekPanel.backgroundColor = .clear
        peekPanel.hasShadow = false
        peekPanel.ignoresMouseEvents = true
        peekPanel.level = Self.panelLevel
        peekPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        peekPanel.hidesOnDeactivate = false
        peekPanel.isReleasedWhenClosed = false
        peekPanel.isExcludedFromWindowsMenu = true
        peekPanel.contentView = hostingView
        peekPanel.orderFrontRegardless()
        panel = peekPanel
    }

    /// Takes the card down: it fades over the move's one fade, or goes at once when `animated` is false.
    func hide(animated: Bool = true) {
        guard let closingPanel = panel else { return }
        panel = nil
        guard animated else {
            closingPanel.orderOut(nil)
            closingPanel.contentView = nil
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = DS.Move.fadeSeconds
            closingPanel.animator().alphaValue = 0
        } completionHandler: {
            closingPanel.orderOut(nil)
            // Dropping the view stops its once-a-second clock.
            closingPanel.contentView = nil
        }
    }
}

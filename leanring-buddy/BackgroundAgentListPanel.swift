//
//  BackgroundAgentListPanel.swift
//  leanring-buddy
//
//  The clickable list of background agents that shift + option opens next to the mouse. It is a borderless,
//  nonactivating panel that never becomes key, so Chrome keeps the keyboard while the learner clicks a row.
//  It closes on Escape, on a click outside, or on the shortcut again.
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

// MARK: - Panel

private final class AgentListPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a panel that is not key would otherwise only be swallowed by AppKit.
private final class AgentListHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AgentListPanelController {
    static let panelWidth: CGFloat = 300
    static let maximumPanelHeight: CGFloat = 360
    private static let gapFromTheMouse: CGFloat = 12
    /// One level above the cursor overlay windows, so the list is never under the wingmen.
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    private let store: BackgroundAgentStore
    private let cancelAgent: (UUID) -> Void
    private var panel: AgentListPanel?
    private var clickOutsideMonitor: Any?
    /// Where the panel's top-left corner sits, fixed when it opens so a row that expands grows the panel downward.
    private var anchorTopLeft: CGPoint = .zero
    private var visibleFrame: CGRect = .zero

    init(store: BackgroundAgentStore, cancelAgent: @escaping (UUID) -> Void) {
        self.store = store
        self.cancelAgent = cancelAgent
    }

    var isOpen: Bool { panel != nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard panel == nil else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = screenUnderTheMouseCursor()
        visibleFrame = screen?.visibleFrame ?? .zero
        anchorTopLeft = CGPoint(x: mouseLocation.x + Self.gapFromTheMouse, y: mouseLocation.y - Self.gapFromTheMouse)

        let agentListView = AgentListView(store: store, cancelAgent: cancelAgent) { [weak self] contentSize in
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

    func close() {
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
    let cancelAgent: (UUID) -> Void
    let onContentSizeChange: (CGSize) -> Void

    @State private var expandedAgentID: UUID?

    private static let headerHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text("\(store.agents.filter(\.isRunning).count) running")
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
                            AgentRowView(
                                agent: agent,
                                isExpanded: expandedAgentID == agent.id,
                                onToggle: { expandedAgentID = expandedAgentID == agent.id ? nil : agent.id },
                                onCancel: { cancelAgent(agent.id) }
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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.borderSubtle, lineWidth: 1))
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
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCancel: () -> Void

    @State private var isHovered = false

    /// The meter's filled segments and the wingman share one color for each phase.
    private var meterColor: Color {
        switch agent.phase {
        case .running: return agent.kind.color
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
                        WingmanTriangleView(agent: agent, size: 11)
                            .frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.kind.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(agent.subject ?? "Finding the video")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
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

    /// One segment per step. A finished step is solid and the step in progress is faint.
    private var stepMeter: some View {
        HStack(spacing: 3) {
            ForEach(Array(agent.kind.stepNames.indices), id: \.self) { stepIndex in
                let stepStatus = agent.stepStatuses.indices.contains(stepIndex) ? agent.stepStatuses[stepIndex] : .pending
                Capsule()
                    .fill(stepStatus == .done ? meterColor : stepStatus == .current ? meterColor.opacity(0.35) : DS.Colors.surface3)
                    .frame(height: 3)
            }
        }
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(agent.stepStatuses.enumerated()), id: \.offset) { stepIndex, stepStatus in
                HStack(spacing: 8) {
                    Text(stepStatus.symbol)
                        .font(.system(size: 11, weight: stepStatus == .current ? .bold : .regular))
                        .foregroundColor(stepStatus == .done ? DS.Colors.success : stepStatus == .current ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .frame(width: 12)
                    Text(agent.kind.stepNames[stepIndex])
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
                AgentActionButton(title: "Cancel", titleColor: DS.Colors.destructiveText, action: onCancel)
            } else if case .notionPage(let pageURL) = agent.finishedResult {
                // Brings the page forward, unlike the background tab the finished guide opened in.
                AgentActionButton(title: "Open page", titleColor: DS.Colors.textPrimary) {
                    NSWorkspace.shared.open(pageURL)
                }
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
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

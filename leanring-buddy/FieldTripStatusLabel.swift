//
//  FieldTripStatusLabel.swift
//  leanring-buddy
//
//  A small label at the bottom of the screen while a scene builds, so the wait
//  has something on screen and Clicky does not talk over nothing.
//

import AppKit
import Combine
import SwiftUI

@MainActor
private final class FieldTripStatusLabelModel: ObservableObject {
    @Published var statusText = ""
    @Published var isVisible = false
}

private struct FieldTripStatusLabelView: View {
    @ObservedObject var statusLabelModel: FieldTripStatusLabelModel

    var body: some View {
        Text(statusLabelModel.statusText)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.82)))
            .opacity(statusLabelModel.isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: statusLabelModel.isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@MainActor
final class FieldTripStatusLabel {
    static let shared = FieldTripStatusLabel()

    private static let panelSize = CGSize(width: 420, height: 60)
    private static let distanceFromCursor = CGPoint(x: 24, y: -50)
    private static let cursorFollowInterval: TimeInterval = 1.0 / 30.0

    private let statusLabelModel = FieldTripStatusLabelModel()
    private var statusLabelPanel: NSPanel?
    private var cursorFollowTimer: Timer?

    func show(_ statusText: String) {
        statusLabelModel.statusText = statusText
        let panel = statusLabelPanel ?? makeStatusLabelPanel()
        statusLabelPanel = panel
        moveStatusLabelToTheCursor()
        panel.orderFrontRegardless()
        statusLabelModel.isVisible = true
        // Runs only while the label is up, so it costs nothing the rest of the time.
        if cursorFollowTimer == nil {
            cursorFollowTimer = Timer.scheduledTimer(withTimeInterval: Self.cursorFollowInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.moveStatusLabelToTheCursor()
                }
            }
        }
    }

    func hide() {
        cursorFollowTimer?.invalidate()
        cursorFollowTimer = nil
        statusLabelModel.isVisible = false
    }

    private func moveStatusLabelToTheCursor() {
        guard let statusLabelPanel, let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        let mouseLocation = NSEvent.mouseLocation
        statusLabelPanel.setFrameOrigin(CGPoint(
            x: min(mouseLocation.x + Self.distanceFromCursor.x, screenFrame.maxX - Self.panelSize.width),
            y: max(mouseLocation.y + Self.distanceFromCursor.y, screenFrame.minY)
        ))
    }

    private func screenUnderTheMouseCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.screens.first
    }

    private func makeStatusLabelPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: FieldTripStatusLabelView(statusLabelModel: statusLabelModel)
        )
        return panel
    }
}

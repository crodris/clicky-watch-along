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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class FieldTripStatusLabel {
    static let shared = FieldTripStatusLabel()

    private static let panelSize = CGSize(width: 420, height: 60)
    private static let distanceFromScreenBottom: CGFloat = 96

    private let statusLabelModel = FieldTripStatusLabelModel()
    private var statusLabelPanel: NSPanel?

    func show(_ statusText: String) {
        statusLabelModel.statusText = statusText
        let panel = statusLabelPanel ?? makeStatusLabelPanel()
        statusLabelPanel = panel
        if let screenFrame = screenUnderTheMouseCursor()?.frame {
            panel.setFrameOrigin(CGPoint(
                x: screenFrame.midX - Self.panelSize.width / 2,
                y: screenFrame.minY + Self.distanceFromScreenBottom
            ))
        }
        panel.orderFrontRegardless()
        statusLabelModel.isVisible = true
    }

    func hide() {
        statusLabelModel.isVisible = false
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

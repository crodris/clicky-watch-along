//
//  MenuBarPanelCardFrameTests.swift
//  leanring-buddyTests
//
//  Pins where the menu bar panel's card sits inside its larger window, so a click on the shadow margin
//  counts as outside the card and a click on the card never does.
//

import SwiftUI
import Testing

@testable import Clicky

struct MenuBarPanelCardFrameTests {
    @MainActor @Test func theCardFrameIsTheWindowFrameWithoutTheShadowMargin() {
        let windowFrame = NSRect(x: 100, y: 200, width: 400, height: 300)
        let shadowMargin = EdgeInsets(top: 12, leading: 20, bottom: 32, trailing: 28)

        let cardFrame = MenuBarPanelManager.cardFrame(inWindowFrame: windowFrame, shadowMargin: shadowMargin)

        #expect(cardFrame == NSRect(x: 120, y: 232, width: 352, height: 256))
        #expect(!cardFrame.contains(NSPoint(x: 110, y: 300)))
        #expect(!cardFrame.contains(NSPoint(x: 300, y: 210)))
        #expect(cardFrame.contains(NSPoint(x: 300, y: 300)))
    }
}

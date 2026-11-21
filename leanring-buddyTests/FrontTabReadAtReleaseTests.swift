//
//  FrontTabReadAtReleaseTests.swift
//  leanring-buddyTests
//
//  The front tab that the cursor loop's media read and the voice command's screen read share at one push-to-talk release.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct FrontTabReadAtReleaseTests {
    private let volcanoTab = ChromeVideoTab(windowId: 3, tabId: 11, url: "https://www.youtube.com/watch?v=p1eE93vybrc", title: "Volcano")

    @Test func theLoopAndTheVoiceCommandShareOneReadOfTheFrontTab() async {
        let tab = volcanoTab
        let sharedRead = FrontTabReadAtRelease(readTheFrontTab: { tab })
        var tabTheLoopSaw: ChromeVideoTab?
        let controller = CursorLoopController(readTheMediaInTheFrontTab: { frontTabRead in
            tabTheLoopSaw = frontTabRead.frontTab()
            return nil
        })
        controller.pushToTalkWasReleased(frontTabRead: sharedRead)
        await controller.waitForTheMediaReadToFinish()
        // The voice command's screen read asks next, as it does in the release handler.
        let tabTheVoiceReadSaw = sharedRead.frontTab()

        #expect(tabTheLoopSaw?.url == tab.url)
        #expect(tabTheVoiceReadSaw?.url == tab.url)
        #expect(sharedRead.readCount == 1)
    }

    @Test func aReleaseThatNoReaderAsksForReadsNothing() {
        let sharedRead = FrontTabReadAtRelease(readTheFrontTab: { volcanoTab })
        #expect(sharedRead.readCount == 0)
    }

    @Test func aChromeWithNoWindowIsAskedOnceAndEveryReaderHearsNoTab() {
        let sharedRead = FrontTabReadAtRelease(readTheFrontTab: { nil })
        #expect(sharedRead.frontTab() == nil)
        #expect(sharedRead.frontTab() == nil)
        #expect(sharedRead.readCount == 1)
    }

    @Test func theLoopReadsNoTabWhenItsOwnChecksStopBeforeAskingForOne() async {
        // The real media read returns before the tab when Chrome is not the front app, so the voice command's read, which
        // asks next, is the one that reads it.
        let tab = volcanoTab
        let sharedRead = FrontTabReadAtRelease(readTheFrontTab: { tab })
        let controller = CursorLoopController(readTheMediaInTheFrontTab: { _ in nil })
        controller.pushToTalkWasReleased(frontTabRead: sharedRead)
        await controller.waitForTheMediaReadToFinish()
        #expect(sharedRead.readCount == 0)
        #expect(sharedRead.frontTab()?.tabId == 11)
        #expect(sharedRead.readCount == 1)
    }
}

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

    @Test func theLoopLeavesTheReadToTheVoiceCommandWhenChromeIsNotTheFrontApp() {
        let tab = volcanoTab
        let sharedRead = FrontTabReadAtRelease(readTheFrontTab: { tab })
        let tabTheLoopSaw = CursorLoopController.frontTabForTheLoop(frontTabRead: sharedRead, chromeIsTheFrontApp: { false })
        #expect(tabTheLoopSaw == nil)
        #expect(sharedRead.readCount == 0)
        // The voice command's read asks next and is the one that reads the tab.
        #expect(sharedRead.frontTab()?.tabId == 11)
        #expect(sharedRead.readCount == 1)
    }

    @Test func theLoopTakesTheSharedReadWhenChromeIsTheFrontApp() {
        let tab = volcanoTab
        let sharedRead = FrontTabReadAtRelease(readTheFrontTab: { tab })
        let tabTheLoopSaw = CursorLoopController.frontTabForTheLoop(frontTabRead: sharedRead, chromeIsTheFrontApp: { true })
        #expect(tabTheLoopSaw?.tabId == 11)
        #expect(sharedRead.readCount == 1)
    }

    @Test func aReleaseReadWithNoTabNeverMakesTheStudyGuideCheckReadChromeAgain() {
        var chromeReadCount = 0
        let urlFromARelease = FrontVideoURLSource.releaseRead(nil).url(readNow: {
            chromeReadCount += 1
            return "https://www.youtube.com/watch?v=p1eE93vybrc"
        })
        #expect(urlFromARelease == nil)
        #expect(chromeReadCount == 0)
    }

    @Test func aReleaseReadWithATabHandsOverItsURLWithoutReadingChrome() {
        var chromeReadCount = 0
        let url = FrontVideoURLSource.releaseRead(volcanoTab.url).url(readNow: {
            chromeReadCount += 1
            return nil
        })
        #expect(url == volcanoTab.url)
        #expect(chromeReadCount == 0)
    }

    @Test func aCommandWithNoReleaseReadReadsChromeOnce() {
        var chromeReadCount = 0
        let url = FrontVideoURLSource.readNow.url(readNow: {
            chromeReadCount += 1
            return "https://www.youtube.com/watch?v=p1eE93vybrc"
        })
        #expect(url == "https://www.youtube.com/watch?v=p1eE93vybrc")
        #expect(chromeReadCount == 1)
    }
}

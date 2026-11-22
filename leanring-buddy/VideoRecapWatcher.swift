//
//  VideoRecapWatcher.swift
//  leanring-buddy
//
//  Watches Chrome's front tab for the end of a video the learner took a quiz on or wrote a study guide for, and asks for
//  the recap Card when it ends. Until a quiz ends or a guide is written it reads nothing. After that it reads the front tab's
//  address every 3 seconds, which runs no page script, and runs the page script only on a watched video. A failed read backs
//  the watch off for 30 seconds. Chrome, the clock, and the Card come in as closures, so tests run it with none of them.
//
//  Both reads are raw Apple Events sent off the main actor (`ChromeFrontTabAppleEvents`). The same read through
//  `NSAppleScript`, which must run on the main thread, held the main actor for about 133 ms each time (360 ms the first time,
//  measured on 2026-11-22), and every 3 seconds that made an agent's spark on the cursor loop jump about 8 frames, since a
//  spark's place follows the clock. The raw event took 9 to 29 ms on a background thread.
//

import AppKit
import CoreServices
import Foundation

/// Chrome's front tab read with raw Apple Events, which `NSAppleEventDescriptor.sendEvent` may send from any thread, unlike
/// `NSAppleScript`. The four-character codes are Chrome's own, from its scripting dictionary (`sdef`): a window is `cwin`,
/// its active tab `acTa`, a tab's address `URL `, and the execute command `CrSu`/`ExJa` with its script in `JvSc`.
nonisolated enum ChromeFrontTabAppleEvents {
    static let chromeBundleIdentifier = "com.google.Chrome"
    static let secondsToWaitForChrome: TimeInterval = 2

    struct ChromeIsNotRunning: Error {}
    struct ChromeSentNoText: Error {}

    static func fourCharacterCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// An object specifier, the record that names "this property of that object" in an Apple Event.
    private static func objectSpecifier(want: FourCharCode, form: FourCharCode, selector: NSAppleEventDescriptor, from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(selector, forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return specifier
    }

    /// "active tab of window 1", the tab the learner sees in Chrome's front window.
    static func activeTabOfTheFrontWindow() -> NSAppleEventDescriptor {
        let frontWindow = objectSpecifier(want: fourCharacterCode("cwin"), form: FourCharCode(formAbsolutePosition), selector: NSAppleEventDescriptor(int32: 1), from: .null())
        return objectSpecifier(want: FourCharCode(cProperty), form: FourCharCode(formPropertyID), selector: NSAppleEventDescriptor(typeCode: fourCharacterCode("acTa")), from: frontWindow)
    }

    /// The event that gets the front tab's address.
    static func frontTabURLEvent() -> NSAppleEventDescriptor {
        let address = objectSpecifier(want: FourCharCode(cProperty), form: FourCharCode(formPropertyID), selector: NSAppleEventDescriptor(typeCode: fourCharacterCode("URL ")), from: activeTabOfTheFrontWindow())
        let getEvent = chromeEvent(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData))
        getEvent.setParam(address, forKeyword: AEKeyword(keyDirectObject))
        return getEvent
    }

    /// The event that runs `javaScript` in the front tab.
    static func runJavaScriptInTheFrontTabEvent(_ javaScript: String) -> NSAppleEventDescriptor {
        let executeEvent = chromeEvent(eventClass: fourCharacterCode("CrSu"), eventID: fourCharacterCode("ExJa"))
        executeEvent.setParam(activeTabOfTheFrontWindow(), forKeyword: AEKeyword(keyDirectObject))
        executeEvent.setParam(NSAppleEventDescriptor(string: javaScript), forKeyword: fourCharacterCode("JvSc"))
        return executeEvent
    }

    private static func chromeEvent(eventClass: AEEventClass, eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: chromeBundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// Sends the event and returns the text Chrome answers. Throws when Chrome is not running, since an event to a closed
    /// Chrome must never launch it, when Chrome has no window or refuses, and after 2 seconds with no answer.
    static func sendAndReadTheText(of event: NSAppleEventDescriptor) throws -> String {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleIdentifier).isEmpty else { throw ChromeIsNotRunning() }
        let reply = try event.sendEvent(options: [.waitForReply], timeout: secondsToWaitForChrome)
        guard let replyText = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { throw ChromeSentNoText() }
        return replyText
    }

    /// The front tab's address, read off the main actor.
    static func frontTabURLOffTheMainActor() async throws -> String {
        try await Task.detached { try sendAndReadTheText(of: frontTabURLEvent()) }.value
    }

    /// Whether the front tab's video has ended, read off the main actor with the page script.
    static func frontVideoEndReadingOffTheMainActor() async throws -> FrontVideoEndReading? {
        let scriptReply = try await Task.detached { try sendAndReadTheText(of: runJavaScriptInTheFrontTabEvent(FrontVideoEndReading.pageScript)) }.value
        return FrontVideoEndReading(scriptReply: scriptReply)
    }
}

@MainActor
final class VideoRecapWatcher {
    private let chromeIsTheFrontApp: () -> Bool
    private let clickyIsBusy: () -> Bool
    /// The front tab's address, read with no page script and off the main actor. Throws when Chrome has no window or refuses.
    private let readTheFrontTabURL: () async throws -> String
    /// Whether the front tab's video has ended, which runs a page script off the main actor. Throws when Chrome refuses or the
    /// script fails.
    private let readTheFrontVideo: () async throws -> FrontVideoEndReading?
    private let now: () -> Date
    /// The recap for the video at this address, built from its last quiz and its saved guide, or nil when it has none.
    private let recapForVideo: (_ videoURL: String) -> VideoRecap?
    private let showTheRecapAtTheEnd: (_ recap: VideoRecap, _ videoURL: String) -> Void

    private var videoKeysWithSomethingToRecap: Set<String> = []
    private var watchState = VideoEndWatchState()
    private var lastShownRecapsByVideoKey: [String: VideoRecap] = [:]
    private var watchTask: Task<Void, Never>?
    /// No read starts before this time, after a failed one.
    private var noReadBefore = Date.distantPast

    init(
        chromeIsTheFrontApp: @escaping () -> Bool,
        clickyIsBusy: @escaping () -> Bool,
        readTheFrontTabURL: @escaping () async throws -> String,
        readTheFrontVideo: @escaping () async throws -> FrontVideoEndReading?,
        now: @escaping () -> Date = Date.init,
        recapForVideo: @escaping (_ videoURL: String) -> VideoRecap?,
        showTheRecapAtTheEnd: @escaping (_ recap: VideoRecap, _ videoURL: String) -> Void
    ) {
        self.chromeIsTheFrontApp = chromeIsTheFrontApp
        self.clickyIsBusy = clickyIsBusy
        self.readTheFrontTabURL = readTheFrontTabURL
        self.readTheFrontVideo = readTheFrontVideo
        self.now = now
        self.recapForVideo = recapForVideo
        self.showTheRecapAtTheEnd = showTheRecapAtTheEnd
    }

    /// The learner took a quiz on this video or a guide was written for it, so its ending is worth a recap. Starts the watch.
    func startWatching(forVideoURL videoURL: String) {
        videoKeysWithSomethingToRecap.insert(studyGuideVideoKey(forVideoURL: videoURL))
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(videoEndWatchSecondsBetweenReads))
                guard let self else { return }
                await self.readTheFrontVideoOnce()
            }
        }
    }

    /// A Card showed this recap for the video, so its ending shows nothing new unless the recap changes.
    func recapWasShown(_ recap: VideoRecap, forVideoURL videoURL: String) {
        lastShownRecapsByVideoKey[studyGuideVideoKey(forVideoURL: videoURL)] = recap
    }

    /// One read of the front tab. It waits for Chrome to be the front app and for Clicky to be free, since the Card could not
    /// show meanwhile, and a video that ends meanwhile is still ended at the next read. It runs the page script only when the
    /// front tab is a watched video, and backs off after a read fails.
    func readTheFrontVideoOnce() async {
        guard !videoKeysWithSomethingToRecap.isEmpty, chromeIsTheFrontApp(), !clickyIsBusy(), now() >= noReadBefore else { return }
        let reading: FrontVideoEndReading?
        do {
            let frontTabURL = try await readTheFrontTabURL()
            guard videoKeysWithSomethingToRecap.contains(studyGuideVideoKey(forVideoURL: frontTabURL)) else { return }
            reading = try await readTheFrontVideo()
        } catch {
            noReadBefore = now().addingTimeInterval(videoEndWatchSecondsToWaitAfterAFailedRead)
            print("Video recap: could not read the front tab, so the watch waits \(Int(videoEndWatchSecondsToWaitAfterAFailedRead)) s: \(error)")
            return
        }
        let step = videoEndWatchStep(reading: reading, videoKeysWithSomethingToRecap: videoKeysWithSomethingToRecap, state: watchState)
        watchState = step.state
        guard case .showTheRecap(let videoKey) = step.decision, let videoURL = reading?.pageURL else { return }
        guard let recapToShow = videoRecapToShowAtTheEnd(recap: recapForVideo(videoURL), lastShownRecap: lastShownRecapsByVideoKey[videoKey]) else {
            print("Video recap: the video ended, and its recap has nothing new since the Card last showed")
            return
        }
        print("Video recap: the video ended, so its recap shows")
        showTheRecapAtTheEnd(recapToShow, videoURL)
    }
}

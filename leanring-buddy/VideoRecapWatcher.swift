//
//  VideoRecapWatcher.swift
//  leanring-buddy
//
//  Watches Chrome's front tab for the end of a video the learner took a quiz on or wrote a study guide for, and asks for
//  the recap Card when it ends. Until a quiz ends or a guide is written it reads nothing. After that it reads the front tab's
//  address every 3 seconds, which runs no page script, and runs the page script only on a watched video. A failed read backs
//  the watch off for 30 seconds. Chrome, the clock, and the Card come in as closures, so tests run it with none of them.
//

import AppKit
import Foundation

@MainActor
final class VideoRecapWatcher {
    private let chromeIsTheFrontApp: () -> Bool
    private let clickyIsBusy: () -> Bool
    /// The front tab's address, read with no page script. Throws when Chrome has no window or refuses.
    private let readTheFrontTabURL: () throws -> String
    /// Whether the front tab's video has ended, which runs a page script. Throws when Chrome refuses or the script fails.
    private let readTheFrontVideo: () throws -> FrontVideoEndReading?
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
        readTheFrontTabURL: @escaping () throws -> String,
        readTheFrontVideo: @escaping () throws -> FrontVideoEndReading?,
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
                self.readTheFrontVideoOnce()
            }
        }
    }

    /// A Card showed this recap for the video, so its ending shows nothing new unless the recap changes.
    func recapWasShown(_ recap: VideoRecap, forVideoURL videoURL: String) {
        lastShownRecapsByVideoKey[studyGuideVideoKey(forVideoURL: videoURL)] = recap
    }

    /// One read of the front tab. It waits for Chrome to be the front app and for Clicky to be free, since a read blocks the
    /// main actor for a moment, and a video that ends meanwhile is still ended at the next read. It runs the page script only
    /// when the front tab is a watched video, and backs off after a read fails.
    func readTheFrontVideoOnce() {
        guard !videoKeysWithSomethingToRecap.isEmpty, chromeIsTheFrontApp(), !clickyIsBusy(), now() >= noReadBefore else { return }
        let reading: FrontVideoEndReading?
        do {
            let frontTabURL = try readTheFrontTabURL()
            guard videoKeysWithSomethingToRecap.contains(studyGuideVideoKey(forVideoURL: frontTabURL)) else { return }
            reading = try readTheFrontVideo()
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

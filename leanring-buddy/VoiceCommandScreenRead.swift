//
//  VoiceCommandScreenRead.swift
//  leanring-buddy
//
//  What a voice command reads from the screen before it asks the model: the video in Chrome's front tab, the page's tools
//  and state, and whether the front video has a study guide. None of it needs the learner's words, so it is read when
//  push-to-talk is released, during the microphone's tail and the transcript's finalization, and the transcript of that
//  same press uses it.
//

import Foundation

/// The active tab of Chrome's front window, read at most once for one push-to-talk release. The cursor loop's media read and
/// the voice command's screen read both start at the release and both begin with this read, which is several Apple Events
/// to Chrome on the main actor, so the first to ask reads it and the other reuses the answer. Nothing here reads before
/// someone asks, so a release that no consumer needs reads nothing.
@MainActor
final class FrontTabReadAtRelease {
    private let readTheFrontTab: () -> ChromeVideoTab?
    private var frontTabRead: (tab: ChromeVideoTab?, tookSeconds: TimeInterval)?
    /// How many times the real read ran, for a test.
    private(set) var readCount = 0

    init(readTheFrontTab: @escaping () -> ChromeVideoTab? = { try? ChromeVideoTab.frontTabOfTheFrontWindow() }) {
        self.readTheFrontTab = readTheFrontTab
    }

    /// The front tab, or nil when Chrome has no window to read. A nil answer is kept too, so a Chrome that refuses is asked once.
    func frontTab() -> ChromeVideoTab? {
        if let frontTabRead {
            print("Release read: reused the front tab, which took \(Int(frontTabRead.tookSeconds * 1000)) ms to read the first time")
            return frontTabRead.tab
        }
        let readStartedAt = Date()
        let tab = readTheFrontTab()
        readCount += 1
        let tookSeconds = Date().timeIntervalSince(readStartedAt)
        frontTabRead = (tab, tookSeconds)
        print("Release read: read the front tab in \(Int(tookSeconds * 1000)) ms")
        return tab
    }
}

/// What the page and the study guide check answered, and when the last of them finished.
struct VoiceCommandPageRead {
    let pageTools: [VoiceToolDescriptor]
    let pageState: JSONValue?
    let studyGuideExistsForTheFrontVideo: Bool
    let finishedAt: Date
}

/// What tells one page on screen from another: whether the overlay shows a scene, how many scenes it has played, and which
/// kind of page Clicky's own record says is up. The tools and state a read took belong to this page only, so a read whose
/// identity differs from the current one describes a page that is gone.
nonisolated struct VoiceCommandPageIdentity: Equatable, Sendable {
    let overlayIsShowingAScene: Bool
    /// Bumped each time the overlay starts a new page (`LiveSceneOverlay.scenesPlayedCount`), so a page replaced by another
    /// of the same kind still differs.
    let scenesPlayedCount: Int
    let pageKind: VoiceCommandPageKind
}

/// Which kind of page Clicky's record (`liveScenePageOnScreen`) says is on screen.
nonisolated enum VoiceCommandPageKind: Equatable, Sendable {
    case none
    case generatedPage
    case simulation
    case framePopout
    case landmark
}

/// The read of one push-to-talk press, started at its release. The front video state is in hand when this exists, since it
/// is read in one step on the main actor, and the page reads may still run.
struct VoiceCommandScreenRead {
    /// The press this read was started for. Only the transcript of that press may use it.
    let pressCount: Int
    /// The page on screen when the read started. The page tools and state come from that page.
    let pageIdentityAtRelease: VoiceCommandPageIdentity
    let frontVideoState: JSONValue?
    let pageRead: Task<VoiceCommandPageRead, Never>
}

/// The read a transcript may use: the one started at the release of its own press, for the page that is still on screen.
/// A read from an older press, a read of a page that has since gone or been replaced, or none, is nil, so a command never
/// acts on a screen read before its own press was released and never offers the tools of a page that is gone.
func screenReadForTheTranscript(
    of pressCount: Int,
    from screenRead: VoiceCommandScreenRead?,
    currentPageIdentity: VoiceCommandPageIdentity
) -> VoiceCommandScreenRead? {
    guard let screenRead, screenRead.pressCount == pressCount, screenRead.pageIdentityAtRelease == currentPageIdentity else { return nil }
    return screenRead
}

/// Whether a release starts the screen read. A quiz answer goes to the judge and a building scene keeps the keyword path,
/// and neither reads the video.
nonisolated func screenReadStartsAtRelease(phaseIsWaitingForAQuizAnswer: Bool, sceneIsBuilding: Bool) -> Bool {
    !phaseIsWaitingForAQuizAnswer && !sceneIsBuilding
}

/// Where a transcript gets the front video state the router reads.
enum FrontVideoStateSource: Equatable {
    /// A quiz answer or a scene still building reads no video.
    case noVideoIsRead
    /// The read of the transcript's own press, which holds the state (nil when no video is in front).
    case fromTheRelease(JSONValue?)
    /// No usable read of the press, so the video is read now.
    case readNow
}

func frontVideoStateSourceForTheTranscript(
    phaseIsWaitingForAQuizAnswer: Bool,
    sceneIsBuilding: Bool,
    screenReadAtRelease: VoiceCommandScreenRead?
) -> FrontVideoStateSource {
    if phaseIsWaitingForAQuizAnswer || sceneIsBuilding { return .noVideoIsRead }
    if let screenReadAtRelease { return .fromTheRelease(screenReadAtRelease.frontVideoState) }
    return .readNow
}

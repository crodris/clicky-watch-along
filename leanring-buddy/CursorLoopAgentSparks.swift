//
//  CursorLoopAgentSparks.swift
//  leanring-buddy
//
//  The pure rules for the sparks background agents lap around the loop: which agents work on the video in front,
//  how fast a spark laps, and how it finishes. A spark's color is its agent's color and its pace follows the agent's
//  progress, so the learner sees the work where it happens with nothing new on the video. Nothing here reads Chrome,
//  the clock, or the agent store, so tests drive it with made-up values. `CursorLoopController` holds the state and
//  `CursorLoopAgentSparkView` draws it.
//

import Foundation

// MARK: - Which agents work on the video in front

/// Where an agent's work started, as the agent's kind knows it. `BackgroundAgent` keeps none of this, since a scene
/// agent learns its tab only when it reads the front tab, and a task agent hands it to the harness and forgets it.
enum AgentSourceTab: Equatable {
    /// An agent with no tab, such as one seeded for a screenshot. It works on no video.
    case unknown
    /// A 3D model, experiment, or task agent: the front tab's URL when it started.
    case tab(url: String)
    /// A study guide or update agent: the YouTube video's key (`studyGuideVideoKey`), which the same video keeps
    /// whatever else its URL holds, such as a timestamp or a playlist.
    case youTubeVideo(key: String)
}

/// Whether an agent works on the video in front, which is the media the loop goes around. It does when the agent started
/// from the tab that is still in front, and a guide agent when the front tab shows the guide's video. The loop's own
/// poll clears the line when the front tab changes, so the URL is compared the way the poll compares it.
func agentWorksOnTheVideoInFront(sourceTab: AgentSourceTab, frontTabURL: String) -> Bool {
    switch sourceTab {
    case .unknown:
        return false
    case .tab(let url):
        return url == frontTabURL
    case .youTubeVideo(let key):
        return studyGuideVideoKey(forVideoURL: frontTabURL) == key
    }
}

/// What the loop needs to know about an agent: whether it still works, finished, or ended without finishing.
enum LoopSparkAgentStatus: Equatable {
    case working
    /// The agent finished, so its spark completes the lap it is on and then goes.
    case finished
    /// The agent failed or was cancelled, so its spark goes at once. A lap would say it finished.
    case endedWithoutFinishing
}

extension BackgroundAgent {
    /// True while the learner has paused every agent, which holds the agent's spark still.
    var loopSparkIsHeldStill: Bool { pausedAt != nil }

    var loopSparkStatus: LoopSparkAgentStatus {
        switch phase {
        case .running: return .working
        case .finished: return .finished
        case .failed, .cancelled: return .endedWithoutFinishing
        }
    }
}

// MARK: - The spark's pace

enum AgentSparkTimeline {
    /// A lap at no progress takes as long as a request loop's lap during a build, and a lap at full progress is a little
    /// over half a request loop's normal lap, so the spark speeds up as the work nears its end.
    static let secondsPerLapAtNoProgress: TimeInterval = 4.0
    static let secondsPerLapAtFullProgress: TimeInterval = 1.2
    /// A finished agent's spark reaches the end of the lap it is on in exactly this long, whatever part of the lap is left,
    /// and the controller keeps the agent on the line for the same time, so the line fades as the spark arrives.
    static let secondsAFinishingLapTakes: TimeInterval = 1.2

    /// How long one lap takes at this progress, from 0 to 1. Progress outside that range counts as the nearest end.
    static func secondsPerLap(atProgress progress: Double) -> TimeInterval {
        let clampedProgress = min(1, max(0, progress.isNaN ? 0 : progress))
        return secondsPerLapAtNoProgress + (secondsPerLapAtFullProgress - secondsPerLapAtNoProgress) * clampedProgress
    }

    /// Where the spark of the agent that joined the line in this place starts, in laps. Up to four agents that join together
    /// start a quarter lap apart, and the fifth starts where the first did. The first agent starts at the line's start.
    static func startingLaps(forAgentNumber agentNumber: Int) -> Double {
        Double(agentNumber % 4) * 0.25
    }
}

/// How far around the line one agent's spark is. Its pace depends on the agent's progress, which changes as the work goes,
/// so the position is the sum of the small steps taken since the spark began, and a frame's position depends on the
/// ones before it. The view keeps one of these for each spark and advances it every frame.
struct AgentSparkPhase: Equatable {
    /// Laps since the line's start, counting whole laps, so it only grows.
    private(set) var laps: Double
    private var lastAdvancedAt: TimeInterval?

    /// Set when the agent finishes: where the spark was, and the whole lap it runs on to, which is the end of the lap it was
    /// on, so a spark at the start of a lap gets a full one.
    private struct LastLap: Equatable {
        let startedAt: TimeInterval
        let lapsAtStart: Double
        let endsAtLap: Double
    }
    private var lastLap: LastLap?

    init(startingLaps: Double = 0) {
        laps = startingLaps
    }

    /// The whole lap a finished agent's spark stops at, and nil while the agent works.
    var stopsAtLap: Double? { lastLap?.endsAtLap }

    /// Where the spark is on the line, from 0 at the start to 1 at the end of the overshoot.
    var shareAroundTheLine: Double {
        laps - laps.rounded(.down)
    }

    /// True once a finished agent's spark has completed its last lap.
    var hasCompletedItsLastLap: Bool {
        guard let lastLap else { return false }
        return laps >= lastLap.endsAtLap
    }

    /// Moves the spark on to `now`: at the pace of the agent's progress while it works, and once it has finished, in a
    /// straight run to the end of the lap that takes `secondsAFinishingLapTakes`. The first call only records the time.
    /// While the learner has paused the agent, the spark holds still and carries on from the same place after the resume.
    mutating func advance(to now: TimeInterval, agentProgress: Double, agentHasFinished: Bool, agentIsPaused: Bool) {
        defer { lastAdvancedAt = now }
        if agentHasFinished, lastLap == nil {
            lastLap = LastLap(startedAt: now, lapsAtStart: laps, endsAtLap: laps.rounded(.down) + 1)
        }
        // An agent that has finished is no longer paused, and its last lap runs regardless.
        if agentIsPaused, lastLap == nil { return }
        if let lastLap {
            let shareOfTheLastLapRun = min(1, max(0, (now - lastLap.startedAt) / AgentSparkTimeline.secondsAFinishingLapTakes))
            laps = lastLap.lapsAtStart + (lastLap.endsAtLap - lastLap.lapsAtStart) * shareOfTheLastLapRun
            return
        }
        guard let lastAdvancedAt, now > lastAdvancedAt else { return }
        laps += (now - lastAdvancedAt) / AgentSparkTimeline.secondsPerLap(atProgress: agentProgress)
    }
}

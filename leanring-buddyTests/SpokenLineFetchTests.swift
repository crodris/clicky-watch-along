//
//  SpokenLineFetchTests.swift
//  leanring-buddyTests
//
//  The TTS client's fetch of one line, against a stubbed Worker `/tts` route: every way out of a fetch stops its download
//  (a fetch never played, a player whose task is cancelled, and a stop that a newer line asked for while the line loaded),
//  an HTTP error fails the play, and starting a fetch stops nothing. Playing audio needs the app's audio engine, which the
//  test process cannot start, so the stop of a line that already plays is left to SpokenLineTokenLedger's tests.
//

import Foundation
import os
import Testing
@testable import Clicky

/// Answers the TTS client's requests to `http://tts.stub/<path>` with the reply a test set for that path, and records
/// which paths started and which a cancel stopped. Each test uses its own path, so tests running side by side never share one.
private final class StubbedTTSURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        /// An error status with a body.
        case status(Int)
        /// Streamed PCM: `byteCount` bytes, sent `delaySeconds` after the response, and then the stream stays open.
        case pcmThenHoldOpen(byteCount: Int, delaySeconds: Double)
    }

    static let replies = OSAllocatedUnfairLock<[String: Reply]>(initialState: [:])
    static let startedPaths = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    /// How many of each path's downloads a cancel stopped.
    static let stopCounts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tts.stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.withLock({ replies in replies[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.startedPaths.withLock { startedPaths in _ = startedPaths.insert(url.path) }
        switch reply {
        case .status(let statusCode):
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"stubbed"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .pcmThenHoldOpen(let byteCount, let delaySeconds):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/pcm"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard byteCount > 0 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + delaySeconds) { [self] in
                // Silence, so a test that plays the line plays nothing audible.
                client?.urlProtocol(self, didLoad: Data(count: byteCount))
            }
        }
    }

    override func stopLoading() {
        guard let path = request.url?.path else { return }
        Self.stopCounts.withLock { stopCounts in stopCounts[path, default: 0] += 1 }
    }
}

@MainActor
struct SpokenLineFetchTests {
    /// A client whose requests reach the stub at its own path, which answers with `reply`.
    private func clientAnsweredBy(_ reply: StubbedTTSURLProtocol.Reply, path: String = "/\(UUID().uuidString)") -> (ElevenLabsTTSClient, String) {
        StubbedTTSURLProtocol.replies.withLock { replies in replies[path] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedTTSURLProtocol.self]
        return (ElevenLabsTTSClient(proxyURL: "http://tts.stub\(path)", sessionConfiguration: configuration), path)
    }

    /// Waits up to 15 seconds, and returns as soon as the condition holds, so a busy machine slows the test without failing it.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func downloadStarted(_ path: String) -> Bool { StubbedTTSURLProtocol.startedPaths.withLock { $0.contains(path) } }
    private func downloadsStopped(_ path: String) -> Int { StubbedTTSURLProtocol.stopCounts.withLock { $0[path, default: 0] } }
    private func downloadStopped(_ path: String) -> Bool { downloadsStopped(path) > 0 }

    @Test func aFetchThatIsNeverPlayedStopsDownloadingWhenCancelled() async {
        let (client, path) = clientAnsweredBy(.pcmThenHoldOpen(byteCount: 9_600, delaySeconds: 0))
        let fetch = client.startFetching("turned it left")
        #expect(await eventually { downloadStarted(path) })
        fetch.cancel()
        #expect(await eventually { downloadStopped(path) })
    }

    @Test func aPlayerWhoseTaskIsCancelledWhileTheAudioLoadsStopsTheDownload() async {
        // The response arrives with no audio yet, so the player waits for its first chunk.
        let (client, path) = clientAnsweredBy(.pcmThenHoldOpen(byteCount: 0, delaySeconds: 0))
        let fetch = client.startFetching("turned it left")
        let playing = Task { try await client.play(fetch) }
        #expect(await eventually { downloadStarted(path) })
        playing.cancel()
        await #expect(throws: CancellationError.self) { try await playing.value }
        #expect(await eventually { downloadStopped(path) })
    }

    @Test func aStopThatANewerLineAskedForWhileTheLineLoadedStopsItsDownload() async {
        // The audio arrives after the stop, and the player must not start a line nobody wants any more.
        let (client, path) = clientAnsweredBy(.pcmThenHoldOpen(byteCount: 9_600, delaySeconds: 0.3))
        let fetch = client.startFetching("turned it left")
        let playing = Task { try await client.play(fetch) }
        #expect(await eventually { downloadStarted(path) })
        client.stopPlayback()
        await #expect(throws: CancellationError.self) { try await playing.value }
        #expect(await eventually { downloadStopped(path) })
        #expect(!client.isPlaying)
    }

    @Test func anHTTPErrorFailsThePlayWithItsStatus() async {
        let (client, _) = clientAnsweredBy(.status(500))
        do {
            try await client.play(client.startFetching("turned it left"))
            Issue.record("a 500 played")
        } catch {
            #expect((error as NSError).code == 500)
        }
    }

    @Test func startingAFetchStopsNothingThatPlaysOrLoads() async {
        // A line that is loading: its response arrived and its audio has not.
        let (client, path) = clientAnsweredBy(.pcmThenHoldOpen(byteCount: 0, delaySeconds: 0))
        let loadingFetch = client.startFetching("turned it left")
        let loading = Task { try await client.play(loadingFetch) }
        #expect(await eventually { downloadStarted(path) })
        let playingStateBefore = (client.playbackGeneration, client.isPlaying)

        // Every stop bumps the generation and drops the current line, so an unchanged generation means nothing was stopped.
        let earlyFetch = client.startFetching("zoomed in")
        #expect(client.playbackGeneration == playingStateBefore.0)
        #expect(client.isPlaying == playingStateBefore.1)
        #expect(downloadsStopped(path) == 0)

        earlyFetch.cancel()
        loading.cancel()
        #expect(await eventually { downloadsStopped(path) == 2 })
    }
}

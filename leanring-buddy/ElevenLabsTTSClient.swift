//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it as it
//  arrives. The Worker asks ElevenLabs for raw 24 kHz PCM from its stream
//  endpoint, so playback starts on the first fifth of a second of audio
//  instead of after the whole line has been generated and downloaded.
//

import AVFoundation
import Foundation

/// Collects little-endian 16-bit PCM bytes as they arrive, in any split, and hands back whole chunks of float samples.
struct PCM16StreamChunker {
    let samplesPerChunk: Int
    private var pendingBytes: [UInt8] = []

    init(samplesPerChunk: Int) {
        self.samplesPerChunk = samplesPerChunk
        pendingBytes.reserveCapacity(samplesPerChunk * 2)
    }

    /// Returns a full chunk once this byte completes one, otherwise nil.
    mutating func append(_ byte: UInt8) -> [Float]? {
        pendingBytes.append(byte)
        guard pendingBytes.count == samplesPerChunk * 2 else { return nil }
        defer { pendingBytes.removeAll(keepingCapacity: true) }
        return Self.floatSamples(fromLittleEndianPCM16: pendingBytes)
    }

    /// Returns the samples left at the end of the stream. A lone trailing byte is half a sample, so it is dropped.
    mutating func flush() -> [Float]? {
        defer { pendingBytes.removeAll() }
        let wholeSampleByteCount = pendingBytes.count / 2 * 2
        guard wholeSampleByteCount > 0 else { return nil }
        return Self.floatSamples(fromLittleEndianPCM16: Array(pendingBytes.prefix(wholeSampleByteCount)))
    }

    static func floatSamples(fromLittleEndianPCM16 bytes: [UInt8]) -> [Float] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { byteIndex in
            let sampleBits = UInt16(bytes[byteIndex]) | (UInt16(bytes[byteIndex + 1]) << 8)
            return Float(Int16(bitPattern: sampleBits)) / 32_768
        }
    }
}

/// Names one line the TTS client played, so a caller can stop the line it started without stopping whatever plays now.
/// Only `SpokenLineTokenLedger` makes one, and two lines never share a token.
nonisolated struct SpokenLineToken: Equatable, Sendable {
    fileprivate let sequenceNumber: Int
}

/// Keeps which line is current apart from the audio engine, so the rule for a stop request is testable without audio.
/// A flag set by the caller that wants to stop its own line cannot tell whether that line is still the one playing, since
/// another answer may have replaced it. A token can: it matches only the latest line, and only while that line plays.
nonisolated struct SpokenLineTokenLedger {
    private var lastIssuedSequenceNumber = 0
    private var latestToken: SpokenLineToken?

    /// Makes the token of a line that is about to start playing, which replaces the previous line as the current one.
    mutating func issueTokenForANewLine() -> SpokenLineToken {
        lastIssuedSequenceNumber += 1
        let newToken = SpokenLineToken(sequenceNumber: lastIssuedSequenceNumber)
        latestToken = newToken
        return newToken
    }

    /// The token of the line that is playing or still arriving, or nil when no line is. A line that has ended stays the
    /// latest one, so `audioIsPlayingOrArriving` is what says it is no longer current.
    func currentToken(audioIsPlayingOrArriving: Bool) -> SpokenLineToken? {
        audioIsPlayingOrArriving ? latestToken : nil
    }

    /// Whether a request to stop `token`'s line applies, which is only while that line is the current one.
    func stopRequestApplies(to token: SpokenLineToken, audioIsPlayingOrArriving: Bool) -> Bool {
        currentToken(audioIsPlayingOrArriving: audioIsPlayingOrArriving) == token
    }
}

/// The audio of one line, fetched from the Worker's `/tts` route and decoded into chunks of float samples as it streams in.
/// The chunks wait in `chunks` until someone plays them, so a line can be fetched ahead of the moment it is spoken.
/// `ElevenLabsTTSClient.startFetching` makes one and `play` plays it, once.
@MainActor
final class SpokenLineFetch {
    let text: String
    /// Each chunk holds `samplesPerChunk` samples, except the last, which holds what is left. The stream throws the
    /// fetch's error, such as an HTTP error before any audio, and finishes after the last chunk.
    let chunks: AsyncThrowingStream<[Float], Error>
    private let download: Task<Void, Never>

    init(text: String, request: URLRequest, session: URLSession, samplesPerChunk: Int) {
        self.text = text
        let (chunks, chunkContinuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        self.chunks = chunks
        let download = Task {
            do {
                try await SpokenLineFetch.streamTheAudio(of: request, session: session, samplesPerChunk: samplesPerChunk, into: chunkContinuation)
                chunkContinuation.finish()
            } catch let urlError as URLError where urlError.code == .cancelled {
                // A newer line or answer cancelled this one. Callers stay quiet on CancellationError, so it must not
                // reach them as a failure that plays the lost-voice line.
                chunkContinuation.finish(throwing: CancellationError())
            } catch {
                chunkContinuation.finish(throwing: error)
            }
        }
        self.download = download
        // A player whose task is cancelled ends the stream, and the download then has nobody left to read it.
        chunkContinuation.onTermination = { termination in
            if case .cancelled = termination { download.cancel() }
        }
    }

    /// Stops the download, for a line that will not be played. A fetch that is playing is stopped through the player.
    func cancel() {
        download.cancel()
    }

    nonisolated private static func streamTheAudio(
        of request: URLRequest,
        session: URLSession,
        samplesPerChunk: Int,
        into chunkContinuation: AsyncThrowingStream<[Float], Error>.Continuation
    ) async throws {
        let (audioBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            for try await errorBodyLine in audioBytes.lines {
                errorBodyLines.append(errorBodyLine)
            }
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBodyLines.joined(separator: "\n"))"])
        }
        // A Worker deployed before streaming ignores output_format and sends MP3, which would play as noise if read as PCM.
        guard httpResponse.mimeType?.contains("pcm") == true else {
            throw NSError(domain: "ElevenLabsTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "TTS returned \(httpResponse.mimeType ?? "no content type") instead of streamed PCM. Deploy the current Worker."])
        }
        var pcmChunker = PCM16StreamChunker(samplesPerChunk: samplesPerChunk)
        for try await audioByte in audioBytes {
            if let chunk = pcmChunker.append(audioByte) {
                chunkContinuation.yield(chunk)
            }
        }
        // A line shorter than one chunk ends before the first chunk fills.
        if let lastChunk = pcmChunker.flush() {
            chunkContinuation.yield(lastChunk)
        }
        try Task.checkCancellation()
    }
}

@MainActor
final class ElevenLabsTTSClient {
    private static let sampleRate: Double = 24_000
    /// A fifth of a second per buffer: the first one plays almost at once, and ElevenLabs sends audio
    /// several times faster than it plays, so later buffers are queued long before they are needed.
    private static let samplesPerBuffer = 4_800

    private let proxyURL: URL
    private let session: URLSession
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: ElevenLabsTTSClient.sampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Reads the rest of the audio after playback has started.
    private var streamingTask: Task<Void, Never>?
    /// Bumped by every stopPlayback, so a buffer or stream from an earlier line cannot change the current one.
    private var playbackGeneration = 0
    private var isReceivingStream = false
    private var buffersWaitingToFinishPlaying = 0
    private var spokenLineTokenLedger = SpokenLineTokenLedger()
    /// The line now playing and how many of its samples have arrived, so a caption can follow the voice.
    private var currentLineText: String?
    private var currentLineScheduledSampleCount = 0
    private var engineConfigurationObserver: NSObjectProtocol?

    init(proxyURL: String) {
        var proxyURLComponents = URLComponents(string: proxyURL)!
        proxyURLComponents.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        self.proxyURL = proxyURLComponents.url!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)

        // The engine stops itself when the output device changes, and the buffers it held then never
        // report as played, so a line already playing ends here instead of leaving isPlaying true for good.
        // A line still waiting for its first audio is left alone, since speakText starts the engine again.
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isReceivingStream || self.buffersWaitingToFinishPlaying > 0 else { return }
                self.stopPlayback()
            }
        }
    }

    /// Sends `text` to ElevenLabs TTS and starts playing it as soon as the first audio arrives.
    /// Returns the line's token once playback has started, and the rest of the line keeps streaming in behind it.
    /// Throws on network or HTTP errors before playback starts. Cancellation-safe.
    @discardableResult
    func speakText(_ text: String) async throws -> SpokenLineToken {
        try await play(startFetching(text))
    }

    /// Starts fetching the audio of `text` without playing it. The audio streams into the fetch's own buffer until it is
    /// played or cancelled, so a line asked for ahead of time is ready when its moment comes. `speakText` is this followed
    /// by `play`, so a line fetched early and a line fetched now play through the same code.
    func startFetching(_ text: String) -> SpokenLineFetch {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_v4_turbo",
            "voice_settings": [
                "stability": 0.35,
                "similarity_boost": 0.75,
                "style": 0.4
            ]
        ]
        // A dictionary of strings and numbers always encodes.
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return SpokenLineFetch(text: text, request: request, session: session, samplesPerChunk: Self.samplesPerBuffer)
    }

    /// Plays a fetch as soon as its first audio is in, stopping whatever plays now, and returns the line's token once its
    /// audio has started. A fetch plays once, and this takes it over: every way out of it, a failure, a cancel of the
    /// caller's task, or a later `stopPlayback`, also cancels the fetch, so no download outlives the line it was for.
    @discardableResult
    func play(_ fetch: SpokenLineFetch) async throws -> SpokenLineToken {
        stopPlayback()
        let generation = playbackGeneration

        var chunkIterator = fetch.chunks.makeAsyncIterator()
        let firstChunk: [Float]?
        do {
            // A cancel of the caller's task ends the stream, which cancels the download (SpokenLineFetch's onTermination).
            firstChunk = try await chunkIterator.next()
        } catch {
            fetch.cancel()
            throw error
        }

        guard !Task.isCancelled else {
            fetch.cancel()
            throw CancellationError()
        }
        // A newer line or stopPlayback took over while this one loaded, so this line must not report that it is playing.
        guard generation == playbackGeneration else {
            fetch.cancel()
            throw CancellationError()
        }
        currentLineText = fetch.text
        guard let firstChunk else {
            throw NSError(domain: "ElevenLabsTTS", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "TTS returned no audio"])
        }

        if !audioEngine.isRunning {
            // The engine is paused between lines and stops after an output device change, so it starts again here.
            do {
                try audioEngine.start()
            } catch {
                fetch.cancel()
                throw error
            }
        }
        // The token is issued in the same synchronous run that starts the audio, so a caller that cancels its task before
        // this point never has a line playing that it holds no token for.
        let lineToken = spokenLineTokenLedger.issueTokenForANewLine()
        isReceivingStream = true
        scheduleBuffer(of: firstChunk, generation: generation)
        playerNode.play()
        print("🔊 ElevenLabs TTS: playing streamed audio")

        let chunkIteratorAfterFirstChunk = chunkIterator
        streamingTask = Task { [weak self] in
            // stopPlayback cancels this task, which ends the stream and so cancels the download.
            var remainingChunkIterator = chunkIteratorAfterFirstChunk
            do {
                while let chunk = try await remainingChunkIterator.next() {
                    guard let self, generation == self.playbackGeneration else { return }
                    self.scheduleBuffer(of: chunk, generation: generation)
                }
            } catch {
                if !(error is CancellationError) {
                    print("⚠️ ElevenLabs TTS: the audio stream ended early: \(error)")
                }
            }
            if let self, generation == self.playbackGeneration {
                self.isReceivingStream = false
                self.pauseEngineWhenTheLineHasFinished()
            }
        }
        return lineToken
    }

    private func scheduleBuffer(of samples: [Float], generation: Int) {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelSamples = pcmBuffer.floatChannelData?[0] else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { samplePointer in
            channelSamples.update(from: samplePointer.baseAddress!, count: samples.count)
        }
        buffersWaitingToFinishPlaying += 1
        currentLineScheduledSampleCount += samples.count
        playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // The audio engine calls this on its own thread.
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration else { return }
                self.buffersWaitingToFinishPlaying -= 1
                self.pauseEngineWhenTheLineHasFinished()
            }
        }
    }

    /// A running engine keeps the output device rendering silence, so it pauses once a line has fully played.
    private func pauseEngineWhenTheLineHasFinished() {
        guard !isReceivingStream, buffersWaitingToFinishPlaying == 0, audioEngine.isRunning else { return }
        audioEngine.pause()
    }

    /// Whether TTS audio is currently playing back, or still arriving for a line that has started playing.
    var isPlaying: Bool {
        audioEngine.isRunning && (isReceivingStream || buffersWaitingToFinishPlaying > 0)
    }

    /// How far through `text` the voice is, from 0 to 1, or nil when `text` is not the line Clicky is speaking.
    /// The player's clock starts at 0 for each line, since every line stops the player first.
    func spokenFraction(ofLine text: String) -> Double? {
        guard let currentLineText, currentLineText == text else { return nil }
        guard isPlaying else { return 1 }
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else { return 0 }
        return SpokenLineProgress.spokenFraction(
            playedSeconds: Double(playerTime.sampleTime) / Self.sampleRate,
            arrivedSeconds: Double(currentLineScheduledSampleCount) / Self.sampleRate,
            allAudioHasArrived: !isReceivingStream,
            characterCount: text.count
        )
    }

    /// Stops playback only when `token` names the line playing now. A caller that started a line and wants it gone uses this
    /// instead of `stopPlayback()`, since by then an unrelated answer may have replaced its line. Returns whether it stopped.
    @discardableResult
    func stopPlayback(ifTheCurrentLineIs token: SpokenLineToken) -> Bool {
        guard spokenLineTokenLedger.stopRequestApplies(to: token, audioIsPlayingOrArriving: isPlaying) else { return false }
        stopPlayback()
        return true
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        playbackGeneration += 1
        currentLineText = nil
        currentLineScheduledSampleCount = 0
        streamingTask?.cancel()
        streamingTask = nil
        isReceivingStream = false
        buffersWaitingToFinishPlaying = 0
        playerNode.stop()
        if audioEngine.isRunning {
            audioEngine.pause()
        }
    }
}

/// How far through a line the voice is. A line's audio streams in faster than it plays, so its full
/// length is usually known within a moment. Until then the text's length gives an estimate.
enum SpokenLineProgress {
    /// About how fast the voice speaks: three eleven_v4_turbo narration lines ran 13.6 to 15.7 characters a second.
    static let estimatedCharactersPerSecond = 15.0

    static func spokenFraction(playedSeconds: Double, arrivedSeconds: Double, allAudioHasArrived: Bool, characterCount: Int) -> Double {
        let lineSeconds = allAudioHasArrived
            ? arrivedSeconds
            : max(arrivedSeconds, Double(characterCount) / estimatedCharactersPerSecond)
        guard lineSeconds > 0 else { return 1 }
        return min(1, max(0, playedSeconds / lineSeconds))
    }

    /// The letters a caption shows for a spoken fraction. It runs two letters ahead, so the eye never waits on it.
    static func revealedCharacterCount(phraseLength: Int, spokenFraction: Double) -> Int {
        guard spokenFraction < 1 else { return phraseLength }
        return min(phraseLength, Int((spokenFraction * Double(phraseLength)).rounded(.up)) + 2)
    }
}

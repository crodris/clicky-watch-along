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
    /// Returns once playback has started, and the rest of the line keeps streaming in behind it.
    /// Throws on network or HTTP errors before playback starts. Cancellation-safe.
    func speakText(_ text: String) async throws {
        stopPlayback()
        let generation = playbackGeneration

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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let audioBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (audioBytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // A newer line or answer cancelled this one. Callers stay quiet on CancellationError,
            // so this must not reach them as a failure that plays the lost-voice line.
            throw CancellationError()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyLines: [String] = []
            do {
                for try await errorBodyLine in audioBytes.lines {
                    errorBodyLines.append(errorBodyLine)
                }
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            }
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBodyLines.joined(separator: "\n"))"])
        }

        // A Worker deployed before streaming ignores output_format and sends MP3, which would play as noise if read as PCM.
        guard httpResponse.mimeType?.contains("pcm") == true else {
            throw NSError(domain: "ElevenLabsTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "TTS returned \(httpResponse.mimeType ?? "no content type") instead of streamed PCM. Deploy the current Worker."])
        }

        var audioByteIterator = audioBytes.makeAsyncIterator()
        var pcmChunker = PCM16StreamChunker(samplesPerChunk: Self.samplesPerBuffer)
        var firstChunk: [Float]?
        do {
            while firstChunk == nil, let audioByte = try await audioByteIterator.next() {
                firstChunk = pcmChunker.append(audioByte)
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }
        // A line shorter than one buffer ends before the first chunk fills.
        if firstChunk == nil {
            firstChunk = pcmChunker.flush()
        }

        try Task.checkCancellation()
        // A newer line or stopPlayback took over while this one loaded, so this line must not report that it is playing.
        guard generation == playbackGeneration else { throw CancellationError() }
        guard let firstChunk else {
            throw NSError(domain: "ElevenLabsTTS", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "TTS returned no audio"])
        }

        if !audioEngine.isRunning {
            // The engine is paused between lines and stops after an output device change, so it starts again here.
            try audioEngine.start()
        }
        isReceivingStream = true
        scheduleBuffer(of: firstChunk, generation: generation)
        playerNode.play()
        print("🔊 ElevenLabs TTS: playing streamed audio")

        let audioBytesAfterFirstChunk = audioByteIterator
        let pcmChunkerAfterFirstChunk = pcmChunker
        streamingTask = Task { [weak self] in
            var remainingAudioByteIterator = audioBytesAfterFirstChunk
            var remainingPCMChunker = pcmChunkerAfterFirstChunk
            do {
                while let audioByte = try await remainingAudioByteIterator.next() {
                    guard let self, generation == self.playbackGeneration else { return }
                    if let chunk = remainingPCMChunker.append(audioByte) {
                        self.scheduleBuffer(of: chunk, generation: generation)
                    }
                }
                if let lastChunk = remainingPCMChunker.flush(), let self, generation == self.playbackGeneration {
                    self.scheduleBuffer(of: lastChunk, generation: generation)
                }
            } catch {
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    print("⚠️ ElevenLabs TTS: the audio stream ended early: \(error)")
                }
            }
            if let self, generation == self.playbackGeneration {
                self.isReceivingStream = false
                self.pauseEngineWhenTheLineHasFinished()
            }
        }
    }

    private func scheduleBuffer(of samples: [Float], generation: Int) {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelSamples = pcmBuffer.floatChannelData?[0] else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { samplePointer in
            channelSamples.update(from: samplePointer.baseAddress!, count: samples.count)
        }
        buffersWaitingToFinishPlaying += 1
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

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        playbackGeneration += 1
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

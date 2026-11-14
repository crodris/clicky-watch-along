// Records one display with system audio to a .mov until it receives SIGINT or SIGTERM.
// Usage: record <displayIndex> <output.mov>
// RECORDING_SOURCE_RECT="x,y,width,height", in the display's points, records only that part of it, at full pixel density.
import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let displayIndex = Int(arguments[1]), displayIndex >= 0 else {
    FileHandle.standardError.write("usage: record <displayIndex> <output.mov>\n".data(using: .utf8)!)
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[2])

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        print("recording started"); fflush(stdout)
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        print("recording failed: \(error)"); fflush(stdout)
        exit(1)
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        print("recording finished"); fflush(stdout)
        exit(0)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("stream stopped: \(error)"); fflush(stdout)
        exit(1)
    }
}

let recordingDelegate = RecordingDelegate()
var activeStream: SCStream?
var signalSources: [DispatchSourceSignal] = []

Task {
    do {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = shareableContent.displays.sorted { $0.displayID < $1.displayID }
        for (index, display) in displays.enumerated() {
            print("display \(index): id \(display.displayID) \(display.width)x\(display.height) frame \(display.frame)")
        }
        guard displayIndex < displays.count else { print("no display \(displayIndex)"); exit(1) }
        let display = displays[displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let pointPixelScale = Int(filter.pointPixelScale)
        let sourceRectValues = (ProcessInfo.processInfo.environment["RECORDING_SOURCE_RECT"] ?? "")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if ProcessInfo.processInfo.environment["RECORDING_SOURCE_RECT"]?.isEmpty == false && sourceRectValues.count != 4 {
            print("RECORDING_SOURCE_RECT must be x,y,width,height in points"); fflush(stdout)
            exit(2)
        }
        if sourceRectValues.count == 4 {
            let sourceRect = CGRect(x: sourceRectValues[0], y: sourceRectValues[1], width: sourceRectValues[2], height: sourceRectValues[3])
            configuration.sourceRect = sourceRect
            configuration.width = Int(sourceRect.width) * pointPixelScale
            configuration.height = Int(sourceRect.height) * pointPixelScale
        } else {
            configuration.width = display.width * pointPixelScale
            configuration.height = display.height * pointPixelScale
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.queueDepth = 8

        let stream = SCStream(filter: filter, configuration: configuration, delegate: recordingDelegate)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: recordingDelegate)
        try stream.addRecordingOutput(recordingOutput)
        try await stream.startCapture()
        activeStream = stream
    } catch {
        print("error: \(error)"); fflush(stdout)
        exit(1)
    }
}

for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Task {
            try? await activeStream?.stopCapture()
            // The recording delegate exits once the file is finalized; this is the fallback.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()

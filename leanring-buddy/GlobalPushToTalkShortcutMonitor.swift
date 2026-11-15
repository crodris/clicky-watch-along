//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    let pinchMagnificationPublisher = PassthroughSubject<Double, Never>()
    let escapeKeyPressPublisher = PassthroughSubject<Void, Never>()
    /// Sends once each time shift + option is held for 0.3 seconds with nothing else pressed.
    let agentListShortcutPublisher = PassthroughSubject<Void, Never>()
    private static let escapeKeyCode: UInt16 = 53

    // CoreGraphics has no public names for gesture events. These are the values
    // the window server uses for a gesture and for a trackpad zoom inside it.
    private static let gestureEventTypeRawValue: UInt32 = 29
    private static let gestureKindField = CGEventField(rawValue: 110)!
    private static let gestureKindZoom: Int64 = 8
    private static let gestureZoomAmountField = CGEventField(rawValue: 113)!

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    private var agentListShortcutRecognizer = AgentListShortcutRecognizer()
    /// Wakes the recognizer when a shift + option hold reaches its time, since no event arrives while the keys stay down.
    private var agentListHoldTimer: Timer?

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(1) << Self.gestureEventTypeRawValue) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        agentListHoldTimer?.invalidate()
        agentListHoldTimer = nil
        agentListShortcutRecognizer = AgentListShortcutRecognizer()

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if eventType.rawValue == Self.gestureEventTypeRawValue {
            if event.getIntegerValueField(Self.gestureKindField) == Self.gestureKindZoom {
                pinchMagnificationPublisher.send(event.getDoubleValueField(Self.gestureZoomAmountField))
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if eventType == .keyDown && eventKeyCode == Self.escapeKeyCode {
            escapeKeyPressPublisher.send()
        }
        feedTheAgentListShortcutRecognizer(eventType: eventType, event: event)
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    private func feedTheAgentListShortcutRecognizer(eventType: CGEventType, event: CGEvent) {
        switch eventType {
        case .flagsChanged:
            agentListShortcutRecognizer.modifiersChanged(
                NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                at: ProcessInfo.processInfo.systemUptime
            )
        case .keyDown:
            agentListShortcutRecognizer.keyWasPressed()
        default:
            return
        }
        agentListHoldTimer?.invalidate()
        agentListHoldTimer = nil
        guard let holdCompletesAt = agentListShortcutRecognizer.holdCompletesAt else { return }
        let secondsUntilTheHoldCompletes = max(0, holdCompletesAt - ProcessInfo.processInfo.systemUptime)
        agentListHoldTimer = Timer.scheduledTimer(withTimeInterval: secondsUntilTheHoldCompletes, repeats: false) { [weak self] _ in
            guard let self, let holdCompletesAt = self.agentListShortcutRecognizer.holdCompletesAt else { return }
            if self.agentListShortcutRecognizer.timeAdvanced(to: holdCompletesAt) {
                self.agentListShortcutPublisher.send()
            }
        }
    }
}

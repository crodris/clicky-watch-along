// Posts one real scroll wheel event at the mouse's current position, in pixels. Positive points scroll down, so the
// content moves up and later content shows, as a downward two-finger swipe on a trackpad would.
// Usage: swift scroll.swift <points>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let points = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: scroll <points>, a whole number, positive to scroll down\n".utf8))
    exit(2)
}
// A scroll wheel event's delta is positive when the content moves down, which is the opposite of the sign above.
guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points, wheel2: 0, wheel3: 0) else {
    FileHandle.standardError.write(Data("could not create the scroll event\n".utf8))
    exit(1)
}
scrollEvent.post(tap: .cghidEventTap)

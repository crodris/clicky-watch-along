// Moves, clicks, and drags the real mouse with CGEvents, in global screen points (top-left origin).
// Usage: mouse where | move x y | click x y | rightclick x y | drag fromX fromY toX toY seconds
import CoreGraphics
import Foundation

let usage = "usage: mouse where | move x y [seconds] | click x y | rightclick x y | drag fromX fromY toX toY seconds"
let arguments = CommandLine.arguments.dropFirst().map { $0 }

/// The argument at that position as a number, or the usage and exit 2, so a driver that passes an empty or bad value
/// stops with a message instead of a crash.
func number(at argumentIndex: Int) -> Double {
    guard argumentIndex < arguments.count, let value = Double(arguments[argumentIndex]) else {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
    return value
}
func point(at argumentIndex: Int) -> CGPoint { CGPoint(x: number(at: argumentIndex), y: number(at: argumentIndex + 1)) }
func post(_ type: CGEventType, _ location: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func glide(from start: CGPoint, to end: CGPoint, seconds: Double, type: CGEventType) {
    let steps = max(1, Int(seconds * 60))
    for step in 1...steps {
        let progress = Double(step) / Double(steps)
        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        post(type, CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased))
        usleep(useconds_t(1_000_000 / 60))
    }
}
func currentLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

switch arguments.first {
case "where":
    let location = currentLocation(); print("\(location.x) \(location.y)")
case "move":
    glide(from: currentLocation(), to: point(at: 1), seconds: arguments.count > 3 ? number(at: 3) : 0.6, type: .mouseMoved)
case "click":
    let target = point(at: 1)
    glide(from: currentLocation(), to: target, seconds: 0.6, type: .mouseMoved)
    usleep(150_000); post(.leftMouseDown, target); usleep(90_000); post(.leftMouseUp, target)
case "rightclick":
    let target = point(at: 1)
    glide(from: currentLocation(), to: target, seconds: 0.6, type: .mouseMoved)
    usleep(150_000)
    CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: target, mouseButton: .right)?.post(tap: .cghidEventTap)
    usleep(90_000)
    CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: target, mouseButton: .right)?.post(tap: .cghidEventTap)
case "drag":
    let start = point(at: 1), end = point(at: 3)
    glide(from: currentLocation(), to: start, seconds: 0.6, type: .mouseMoved)
    usleep(200_000); post(.leftMouseDown, start); usleep(150_000)
    glide(from: start, to: end, seconds: number(at: 5), type: .leftMouseDragged)
    usleep(150_000); post(.leftMouseUp, end)
default:
    FileHandle.standardError.write(Data("\(usage)\n".utf8)); exit(2)
}

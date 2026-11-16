// Moves, clicks, and drags the real mouse with CGEvents, in global screen points (top-left origin).
// Usage: mouse where | move x y | click x y | drag fromX fromY toX toY seconds
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst().map { $0 }
func point(_ xText: String, _ yText: String) -> CGPoint { CGPoint(x: Double(xText)!, y: Double(yText)!) }
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
    glide(from: currentLocation(), to: point(arguments[1], arguments[2]), seconds: Double(arguments.count > 3 ? arguments[3] : "0.6")!, type: .mouseMoved)
case "click":
    let target = point(arguments[1], arguments[2])
    glide(from: currentLocation(), to: target, seconds: 0.6, type: .mouseMoved)
    usleep(150_000); post(.leftMouseDown, target); usleep(90_000); post(.leftMouseUp, target)
case "drag":
    let start = point(arguments[1], arguments[2]), end = point(arguments[3], arguments[4])
    glide(from: currentLocation(), to: start, seconds: 0.6, type: .mouseMoved)
    usleep(200_000); post(.leftMouseDown, start); usleep(150_000)
    glide(from: start, to: end, seconds: Double(arguments[5])!, type: .leftMouseDragged)
    usleep(150_000); post(.leftMouseUp, end)
default:
    print("usage: mouse where | move x y [seconds] | click x y | drag fromX fromY toX toY seconds"); exit(2)
}

// Clicks the left mouse button at a point in global screen coordinates (top-left origin, in points), so a recording can
// show a real click on a page, such as a timestamp link in a study guide. Usage: click-mouse <x> <y>
// Posting mouse events needs the Accessibility permission for the app that runs this, such as the terminal.
import CoreGraphics
import Foundation

let commandLineArguments = CommandLine.arguments
guard commandLineArguments.count == 3,
      let pointX = Double(commandLineArguments[1]),
      let pointY = Double(commandLineArguments[2]) else {
    FileHandle.standardError.write("usage: click-mouse <x> <y>, both numbers\n".data(using: .utf8)!)
    exit(2)
}
let clickPoint = CGPoint(x: pointX, y: pointY)
for mouseEventType in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    guard let mouseEvent = CGEvent(mouseEventSource: nil, mouseType: mouseEventType, mouseCursorPosition: clickPoint, mouseButton: .left) else {
        FileHandle.standardError.write("could not make the \(mouseEventType) event\n".data(using: .utf8)!)
        exit(1)
    }
    mouseEvent.post(tap: .cghidEventTap)
    // A page treats a press and release in the same instant as a tap, but some handlers need a frame between them.
    usleep(60_000)
}

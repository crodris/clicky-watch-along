// Moves the mouse to a point in global screen coordinates, so a recording starts with the cursor where the
// status labels and chips should appear. Usage: move-mouse <x> <y>
import CoreGraphics
import Foundation

let commandLineArguments = CommandLine.arguments
guard commandLineArguments.count == 3,
      let pointX = Double(commandLineArguments[1]),
      let pointY = Double(commandLineArguments[2]) else {
    FileHandle.standardError.write("usage: move-mouse <x> <y>, both numbers\n".data(using: .utf8)!)
    exit(2)
}
CGWarpMouseCursorPosition(CGPoint(x: pointX, y: pointY))
CGAssociateMouseAndMouseCursorPosition(1)

import CoreGraphics
let a = CommandLine.arguments
CGWarpMouseCursorPosition(CGPoint(x: Double(a[1])!, y: Double(a[2])!))
CGAssociateMouseAndMouseCursorPosition(1)

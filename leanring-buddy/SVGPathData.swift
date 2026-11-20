//
//  SVGPathData.swift
//  leanring-buddy
//
//  A small SVG path parser for the custom cursors the Theme Studio draws. The model writes a `d` string, this turns it
//  into absolute move, line, curve, and close commands, and `SVGPathShape` draws them scaled into the cursor's 24 point
//  box. It accepts exactly the commands the Worker's `/theme-ideas` route accepts (M L H V C S Q T Z, in either case)
//  and refuses anything else, so a hand-edited theme file cannot draw outside the box or crash the overlay.
//

import CoreGraphics
import SwiftUI

/// One drawing step in absolute box coordinates. Relative commands, H, V, S, and T are already resolved into these.
nonisolated enum SVGPathCommand: Equatable, Sendable {
    case move(to: CGPoint)
    case line(to: CGPoint)
    case quadraticCurve(control: CGPoint, to: CGPoint)
    case cubicCurve(control1: CGPoint, control2: CGPoint, to: CGPoint)
    case close
}

nonisolated struct SVGPathData: Equatable, Sendable {
    let commands: [SVGPathCommand]

    /// The cursor is drawn in a 24 by 24 box. The Worker lets a path reach 2 units past it on every side, so a stroke at the
    /// edge is not clipped by the box.
    static let boxCoordinateRange: ClosedRange<CGFloat> = -2...26
    static let longestPathText = 600

    /// Nil for any path the Worker's rules refuse: an unknown command (an arc `A` included), a number with the wrong
    /// shape, a command with the wrong count of numbers, a path that does not start with a move, an empty path, a path
    /// over 600 characters, or any coordinate outside the box range.
    init?(parsing pathText: String) {
        guard !pathText.isEmpty, pathText.count <= Self.longestPathText else { return nil }
        guard let commands = Self.parseCommands(in: pathText), !commands.isEmpty else { return nil }
        self.commands = commands
    }

    // MARK: - Parsing

    /// How many numbers one use of each command takes.
    private static func numberCountPerUse(of commandLetter: Character) -> Int? {
        switch commandLetter {
        case "M", "L", "T": return 2
        case "H", "V": return 1
        case "C": return 6
        case "S", "Q": return 4
        case "Z": return 0
        default: return nil
        }
    }

    /// Reads the text as a list of (letter, numbers) groups, then resolves each group into absolute commands.
    private static func parseCommands(in pathText: String) -> [SVGPathCommand]? {
        var characters = Array(pathText)[...]
        var commands: [SVGPathCommand] = []
        var currentPoint = CGPoint.zero
        var subpathStartPoint = CGPoint.zero
        // The second control point of the last cubic and of the last quadratic, which S and T reflect. Cleared by any other command.
        var previousCubicControl: CGPoint?
        var previousQuadraticControl: CGPoint?
        var isFirstCommand = true

        skipSeparators(in: &characters)
        while let commandCharacter = characters.first {
            characters = characters.dropFirst()
            // ASCII only, since the uppercase form of some other letters is more than one character.
            guard commandCharacter.isASCII, commandCharacter.isLetter else { return nil }
            let isRelative = commandCharacter.isLowercase
            let uppercaseLetter = Character(commandCharacter.uppercased())
            guard let numberCount = numberCountPerUse(of: uppercaseLetter) else { return nil }
            // A path must start with a move, as SVG says.
            if isFirstCommand && uppercaseLetter != "M" { return nil }
            isFirstCommand = false

            if numberCount == 0 {
                // Z closes the subpath and takes no numbers.
                commands.append(.close)
                currentPoint = subpathStartPoint
                previousCubicControl = nil
                previousQuadraticControl = nil
                skipSeparators(in: &characters)
                continue
            }

            // A command letter takes one or more full groups of numbers. After the first group, M repeats as L.
            var groupIndex = 0
            repeat {
                var numbers: [CGFloat] = []
                for _ in 0..<numberCount {
                    skipSeparators(in: &characters)
                    guard let number = readNumber(from: &characters) else { return nil }
                    numbers.append(number)
                }
                let useRepeatsAsLine = uppercaseLetter == "M" && groupIndex > 0
                let effectiveLetter: Character = useRepeatsAsLine ? "L" : uppercaseLetter
                let originX = isRelative ? currentPoint.x : 0
                let originY = isRelative ? currentPoint.y : 0

                switch effectiveLetter {
                case "M":
                    let point = CGPoint(x: originX + numbers[0], y: originY + numbers[1])
                    commands.append(.move(to: point))
                    currentPoint = point
                    subpathStartPoint = point
                    previousCubicControl = nil
                    previousQuadraticControl = nil
                case "L":
                    let point = CGPoint(x: originX + numbers[0], y: originY + numbers[1])
                    commands.append(.line(to: point))
                    currentPoint = point
                    previousCubicControl = nil
                    previousQuadraticControl = nil
                case "H":
                    let point = CGPoint(x: originX + numbers[0], y: currentPoint.y)
                    commands.append(.line(to: point))
                    currentPoint = point
                    previousCubicControl = nil
                    previousQuadraticControl = nil
                case "V":
                    let point = CGPoint(x: currentPoint.x, y: originY + numbers[0])
                    commands.append(.line(to: point))
                    currentPoint = point
                    previousCubicControl = nil
                    previousQuadraticControl = nil
                case "C":
                    let control1 = CGPoint(x: originX + numbers[0], y: originY + numbers[1])
                    let control2 = CGPoint(x: originX + numbers[2], y: originY + numbers[3])
                    let point = CGPoint(x: originX + numbers[4], y: originY + numbers[5])
                    commands.append(.cubicCurve(control1: control1, control2: control2, to: point))
                    currentPoint = point
                    previousCubicControl = control2
                    previousQuadraticControl = nil
                case "S":
                    // The first control point mirrors the last cubic's second one around the current point, or sits on it.
                    let control1 = previousCubicControl.map { CGPoint(x: 2 * currentPoint.x - $0.x, y: 2 * currentPoint.y - $0.y) } ?? currentPoint
                    let control2 = CGPoint(x: originX + numbers[0], y: originY + numbers[1])
                    let point = CGPoint(x: originX + numbers[2], y: originY + numbers[3])
                    commands.append(.cubicCurve(control1: control1, control2: control2, to: point))
                    currentPoint = point
                    previousCubicControl = control2
                    previousQuadraticControl = nil
                case "Q":
                    let control = CGPoint(x: originX + numbers[0], y: originY + numbers[1])
                    let point = CGPoint(x: originX + numbers[2], y: originY + numbers[3])
                    commands.append(.quadraticCurve(control: control, to: point))
                    currentPoint = point
                    previousQuadraticControl = control
                    previousCubicControl = nil
                case "T":
                    let control = previousQuadraticControl.map { CGPoint(x: 2 * currentPoint.x - $0.x, y: 2 * currentPoint.y - $0.y) } ?? currentPoint
                    let point = CGPoint(x: originX + numbers[0], y: originY + numbers[1])
                    commands.append(.quadraticCurve(control: control, to: point))
                    currentPoint = point
                    previousQuadraticControl = control
                    previousCubicControl = nil
                default:
                    return nil
                }

                // Only the points the text names are range checked. A mirrored control point is derived, not written.
                let writtenPoints = writtenAbsolutePoints(letter: effectiveLetter, numbers: numbers, originX: originX, originY: originY)
                guard writtenPoints.allSatisfy({ boxCoordinateRange.contains($0.x) && boxCoordinateRange.contains($0.y) }) else { return nil }

                groupIndex += 1
                skipSeparators(in: &characters)
            } while characters.first.map({ !$0.isLetter }) == true
        }
        return commands
    }

    /// The absolute coordinates the text wrote for one group of numbers, to check against the box.
    /// H writes only an x and V only a y, so the other coordinate, which the previous point supplies, is zero here and inside the range.
    private static func writtenAbsolutePoints(letter: Character, numbers: [CGFloat], originX: CGFloat, originY: CGFloat) -> [CGPoint] {
        switch letter {
        case "H":
            return [CGPoint(x: originX + numbers[0], y: 0)]
        case "V":
            return [CGPoint(x: 0, y: originY + numbers[0])]
        default:
            return stride(from: 0, to: numbers.count, by: 2).map { pairStart in
                CGPoint(x: originX + numbers[pairStart], y: originY + numbers[pairStart + 1])
            }
        }
    }

    /// What SVG allows between numbers and commands: space, tab, carriage return, line feed, form feed, and comma. The Worker's
    /// tokenizer skips exactly these, so a path it accepts parses here. Anything else, a non-breaking space included, is refused.
    private static let separatorScalars: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n", "\u{0C}", ","]

    private static func skipSeparators(in characters: inout ArraySlice<Character>) {
        // Swift reads a carriage return and line feed together as one Character, so a character is a separator when
        // every scalar in it is one.
        while let character = characters.first, character.unicodeScalars.allSatisfy({ separatorScalars.contains($0) }) {
            characters = characters.dropFirst()
        }
    }

    /// Reads an SVG number: an optional minus, digits, and an optional fraction. Another minus or a second point starts the
    /// next number, so "10-5" is 10 and -5, and "1.5.5" is 1.5 and .5. Nothing else is a number, so an exponent or a plus is refused.
    private static func readNumber(from characters: inout ArraySlice<Character>) -> CGFloat? {
        var numberText = ""
        if characters.first == "-" {
            numberText.append("-")
            characters = characters.dropFirst()
        }
        var digitCount = 0
        while let character = characters.first, character.isASCII, character.isNumber {
            numberText.append(character)
            digitCount += 1
            characters = characters.dropFirst()
        }
        if characters.first == "." {
            numberText.append(".")
            characters = characters.dropFirst()
            while let character = characters.first, character.isASCII, character.isNumber {
                numberText.append(character)
                digitCount += 1
                characters = characters.dropFirst()
            }
        }
        guard digitCount > 0, let value = Double(numberText) else { return nil }
        return CGFloat(value)
    }
}

// MARK: - Drawing

/// Draws parsed path data scaled from the cursor's 24 point box into whatever rect it is given.
struct SVGPathShape: Shape {
    let pathData: SVGPathData

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for command in pathData.commands {
            switch command {
            case .move(let point):
                path.move(to: CursorDrawingBox.point(point.x, point.y, in: rect))
            case .line(let point):
                path.addLine(to: CursorDrawingBox.point(point.x, point.y, in: rect))
            case .quadraticCurve(let control, let point):
                path.addQuadCurve(
                    to: CursorDrawingBox.point(point.x, point.y, in: rect),
                    control: CursorDrawingBox.point(control.x, control.y, in: rect)
                )
            case .cubicCurve(let control1, let control2, let point):
                path.addCurve(
                    to: CursorDrawingBox.point(point.x, point.y, in: rect),
                    control1: CursorDrawingBox.point(control1.x, control1.y, in: rect),
                    control2: CursorDrawingBox.point(control2.x, control2.y, in: rect)
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}

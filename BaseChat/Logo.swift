import SwiftUI

/// The app mark — HugeIcons `ai-content-generator-01`, stroke-rounded.
/// Drawn from the original SVG path data so it stays sharp at any size and
/// takes whatever `foregroundStyle` the call site sets.
struct LogoShape: Shape {
    static let viewBox: CGFloat = 24

    static let paths = [
        "M11 21H10C6.22876 21 4.34315 21 3.17157 19.8284C2 18.6569 2 16.7712 2 13V10C2 6.22876 2 4.34315 3.17157 3.17157C4.34315 2 6.22876 2 10 2H12C15.7712 2 17.6569 2 18.8284 3.17157C20 4.34315 20 6.22876 20 10V10.5",
        "M17.4069 14.4036C17.6192 13.8655 18.3808 13.8655 18.5931 14.4036L18.6298 14.4969C19.1482 15.8113 20.1887 16.8518 21.5031 17.3702L21.5964 17.4069C22.1345 17.6192 22.1345 18.3808 21.5964 18.5931L21.5031 18.6298C20.1887 19.1482 19.1482 20.1887 18.6298 21.5031L18.5931 21.5964C18.3808 22.1345 17.6192 22.1345 17.4069 21.5964L17.3702 21.5031C16.8518 20.1887 15.8113 19.1482 14.4969 18.6298L14.4036 18.5931C13.8655 18.3808 13.8655 17.6192 14.4036 17.4069L14.4969 17.3702C15.8113 16.8518 16.8518 15.8113 17.3702 14.4969L17.4069 14.4036Z",
        "M7 7H15M7 11.5H15M7 16H11",
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Self.viewBox
        var transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
        var combined = Path()
        for data in Self.paths {
            let sub = Path(SVGPath.parse(data).copy(using: &transform) ?? SVGPath.parse(data))
            combined.addPath(sub)
        }
        return combined
    }
}

/// The app mark, stroked like the source icon.
struct LogoMark: View {
    var lineWidth: CGFloat = 1.7

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / LogoShape.viewBox
            LogoShape()
                .stroke(style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Absolute-command SVG path parser (M, L, H, V, C, Z) — all this icon needs.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var numbers: [CGFloat] = []
        var command: Character = " "
        var current = CGPoint.zero
        var start = CGPoint.zero

        func flush() {
            var i = 0
            switch command {
            case "M":
                while i + 1 < numbers.count {
                    let point = CGPoint(x: numbers[i], y: numbers[i + 1])
                    if i == 0 { path.move(to: point); start = point } else { path.addLine(to: point) }
                    current = point
                    i += 2
                }
            case "L":
                while i + 1 < numbers.count {
                    current = CGPoint(x: numbers[i], y: numbers[i + 1])
                    path.addLine(to: current)
                    i += 2
                }
            case "H":
                while i < numbers.count {
                    current = CGPoint(x: numbers[i], y: current.y)
                    path.addLine(to: current)
                    i += 1
                }
            case "V":
                while i < numbers.count {
                    current = CGPoint(x: current.x, y: numbers[i])
                    path.addLine(to: current)
                    i += 1
                }
            case "C":
                while i + 5 < numbers.count {
                    let end = CGPoint(x: numbers[i + 4], y: numbers[i + 5])
                    path.addCurve(to: end,
                                  control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                                  control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3]))
                    current = end
                    i += 6
                }
            case "Z":
                path.closeSubpath()
                current = start
            default:
                break
            }
            numbers = []
        }

        var token = ""
        func takeToken() {
            if !token.isEmpty, let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }

        for character in data {
            if "MLHVCZ".contains(character) {
                takeToken()
                flush()
                command = character
                if command == "Z" { flush() }
            } else if character == "-", !token.isEmpty {
                takeToken()
                token = "-"
            } else if character == " " || character == "," {
                takeToken()
            } else {
                token.append(character)
            }
        }
        takeToken()
        flush()
        return path
    }
}

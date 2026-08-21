import AppKit

func render(scale: CGFloat, to path: String) {
    let w: CGFloat = 640, h: CGFloat = 400
    let pw = Int(w * scale), ph = Int(h * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: scale, y: scale)

    // Warm background wash.
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(srgbRed: 1.0, green: 0.992, blue: 0.976, alpha: 1).cgColor,
                                 NSColor(srgbRed: 0.996, green: 0.945, blue: 0.855, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    let amber = NSColor(srgbRed: 0.898, green: 0.612, blue: 0.075, alpha: 1)
    let ink = NSColor(srgbRed: 0.15, green: 0.13, blue: 0.10, alpha: 1)

    // Arrow between the two icon slots (Finder y=185 from the top -> AppKit y = h-185).
    let y = h - 185
    let x0: CGFloat = 258, x1: CGFloat = 382
    cg.setStrokeColor(amber.withAlphaComponent(0.9).cgColor)
    cg.setLineWidth(7)
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: x0, y: y))
    cg.addLine(to: CGPoint(x: x1 - 16, y: y))
    cg.strokePath()
    cg.setFillColor(amber.withAlphaComponent(0.9).cgColor)
    cg.move(to: CGPoint(x: x1 + 6, y: y))
    cg.addLine(to: CGPoint(x: x1 - 22, y: y + 16))
    cg.addLine(to: CGPoint(x: x1 - 22, y: y - 16))
    cg.closePath()
    cg.fillPath()

    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        string.draw(in: CGRect(x: 0, y: h - top - size * 1.4, width: w, height: size * 1.6))
    }

    draw("BaseChat", size: 27, weight: .semibold, color: ink, top: 42)
    draw("Drag the app onto the Applications folder to install",
         size: 13, weight: .regular, color: ink.withAlphaComponent(0.55), top: 82)
    draw("Local LLM chat, powered by BaseRT",
         size: 11, weight: .regular, color: ink.withAlphaComponent(0.35), top: 340)

    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: CommandLine.arguments[1])
render(scale: 2, to: CommandLine.arguments[2])
print("rendered")

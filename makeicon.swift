import AppKit

// Rendert ein einfaches "Radar"-Icon in mehreren Größen und baut daraus ein .icns.
func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Hintergrund mit Farbverlauf + abgerundete Ecken.
    let radius = size * 0.22
    let path = CGPath(roundedRect: rect.insetBy(dx: size*0.06, dy: size*0.06),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [
        NSColor(calibratedRed: 0.16, green: 0.49, blue: 0.96, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.07, green: 0.27, blue: 0.66, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // Konzentrische Radar-Bögen.
    let center = CGPoint(x: size*0.5, y: size*0.42)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    for i in 1...3 {
        let r = size * 0.12 * CGFloat(i)
        ctx.setLineWidth(size * 0.018)
        ctx.addArc(center: center, radius: r, startAngle: .pi*0.15, endAngle: .pi*0.85, clockwise: false)
        ctx.strokePath()
    }
    // Zentraler Punkt.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addArc(center: center, radius: size*0.04, startAngle: 0, endAngle: .pi*2, clockwise: false)
    ctx.fillPath()

    img.unlockFocus()
    return img
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconsetDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = s * scale
        let img = drawIcon(size: CGFloat(px))
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
        try? png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
    }
}
print("Iconset erstellt: \(iconsetDir)")

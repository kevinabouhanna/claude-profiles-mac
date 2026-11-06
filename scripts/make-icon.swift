// Draws the app icon: run `swift scripts/make-icon.swift` to regenerate Resources/AppIcon.icns
// and docs/images/logo.png. A person with a swap arrow, like Claude Profiles for Windows,
// on the macOS icon grid (an 824 pt rounded square centered on a 1024 pt canvas).
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = size / 1024  // shadows are in pixels, not points, so they're scaled by hand
    ctx.scaleBy(x: k, y: k)

    // Body, with the drop shadow macOS icons carry.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let blue = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.24, green: 0.66, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.0, green: 0.42, blue: 0.90, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(blue, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft light from the top, as on the system icons.
    let shine = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shine, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()
    // A fine inner edge so the shape holds on light and dark backgrounds.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(3); ctx.strokePath()

    // The glyph, drawn on its own layer so the arrow can cut a gap into the shoulders.
    let glyph = CGLayer(ctx, size: CGSize(width: 1024, height: 1024), auxiliaryInfo: nil)!
    let g = glyph.context!
    let line: CGFloat = 46
    g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(line); g.setLineCap(.round); g.setLineJoin(.round)
    g.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 14 * k, color: NSColor(srgbRed: 0, green: 0.2, blue: 0.5, alpha: 0.35).cgColor)

    g.strokeEllipse(in: CGRect(x: 342, y: 568, width: 220, height: 220))   // head
    // Shoulders: rounded on top like a person's, gently rounded at the bottom.
    let shoulders = CGMutablePath()
    let (l, r, top, bottom): (CGFloat, CGFloat, CGFloat, CGFloat) = (262, 642, 494, 250)
    shoulders.move(to: CGPoint(x: (l + r) / 2, y: top))
    shoulders.addArc(tangent1End: CGPoint(x: r, y: top), tangent2End: CGPoint(x: r, y: bottom), radius: 130)
    shoulders.addArc(tangent1End: CGPoint(x: r, y: bottom), tangent2End: CGPoint(x: l, y: bottom), radius: 44)
    shoulders.addArc(tangent1End: CGPoint(x: l, y: bottom), tangent2End: CGPoint(x: l, y: top), radius: 44)
    shoulders.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: r, y: top), radius: 130)
    shoulders.closeSubpath()
    g.addPath(shoulders); g.strokePath()

    // Clear around the arrow, then draw it.
    let arrowY: CGFloat = 300, left: CGFloat = 540, right: CGFloat = 830, head: CGFloat = 70
    g.saveGState()
    g.setBlendMode(.clear)
    g.setShadow(offset: .zero, blur: 0, color: nil)
    g.fill(CGRect(x: left - 50, y: arrowY - head - 50, width: right - left + 100, height: (head + 50) * 2))
    g.restoreGState()
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: left, y: arrowY)); arrow.addLine(to: CGPoint(x: right, y: arrowY))
    arrow.move(to: CGPoint(x: left + head, y: arrowY + head)); arrow.addLine(to: CGPoint(x: left, y: arrowY))
    arrow.addLine(to: CGPoint(x: left + head, y: arrowY - head))
    arrow.move(to: CGPoint(x: right - head, y: arrowY + head)); arrow.addLine(to: CGPoint(x: right, y: arrowY))
    arrow.addLine(to: CGPoint(x: right - head, y: arrowY - head))
    g.addPath(arrow); g.strokePath()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.draw(glyph, at: .zero)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run(); task.waitUntilExit()
try! render(256).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/images/logo.png"))
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/images/logo.png" : "iconutil failed")

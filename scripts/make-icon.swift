// Renders the app icon iconset: `swift scripts/make-icon.swift build/AppIcon.iconset`
// Motif: a page whose top paragraph carries the app's own interlinear gloss
// (light-blue box, left accent rule, 译), over the original lines below.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let accent = NSColor(srgbRed: 0.25, green: 0.45, blue: 0.97, alpha: 1)

func rounded(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS grid: 824pt rounded tile centered on a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = rounded(tile, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(accent.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 0.33, green: 0.56, blue: 1.0, alpha: 1).cgColor,
            NSColor(srgbRed: 0.36, green: 0.28, blue: 0.88, alpha: 1).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [])
    ctx.restoreGState()

    // Page.
    let page = CGRect(x: 257, y: 182, width: 510, height: 660)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(rounded(page, 34))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gloss box with its accent rule.
    let gloss = CGRect(x: 305, y: 560, width: 414, height: 222)
    ctx.saveGState()
    ctx.addPath(rounded(gloss, 16))
    ctx.clip()
    ctx.setFillColor(NSColor(srgbRed: 0.90, green: 0.93, blue: 1.0, alpha: 1).cgColor)
    ctx.fill(gloss)
    ctx.setFillColor(accent.cgColor)
    ctx.fill(CGRect(x: gloss.minX, y: gloss.minY, width: 16, height: gloss.height))
    ctx.restoreGState()

    let font = NSFont(name: "PingFangSC-Semibold", size: 150) ?? NSFont.systemFont(ofSize: 150, weight: .semibold)
    let glyph = NSAttributedString(string: "译", attributes: [.font: font, .foregroundColor: accent])
    let glyphSize = glyph.size()
    glyph.draw(at: CGPoint(x: gloss.minX + 46, y: gloss.midY - glyphSize.height / 2 + 4))

    // Translated lines beside the glyph.
    ctx.setFillColor(accent.withAlphaComponent(0.55).cgColor)
    for (i, width) in [CGFloat(170), 130].enumerated() {
        let y = gloss.midY + 18 - CGFloat(i) * 62
        ctx.addPath(rounded(CGRect(x: gloss.minX + 226, y: y, width: width, height: 26), 13))
        ctx.fillPath()
    }

    // Original lines below.
    ctx.setFillColor(NSColor(white: 0.80, alpha: 1).cgColor)
    for (i, width) in [CGFloat(414), 414, 414, 260].enumerated() {
        let y = 480 - CGFloat(i) * 68
        ctx.addPath(rounded(CGRect(x: 305, y: y, width: width, height: 28), 14))
        ctx.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, pixels) in entries {
    try! render(pixels: pixels).write(to: outDir.appendingPathComponent("\(name).png"))
}
print("wrote \(entries.count) icons to \(outDir.path)")

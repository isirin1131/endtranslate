// Checks CoreText orientation in a flipped NSView — the overlay's drawing context.
// Top half: TranslationAnnotation.drawText as-is. Bottom half: same text drawn with the
// CTM flipped back to y-up inside the rect. Writes /tmp/et-flipped-text.png.
import AppKit
import CoreText

func drawText(_ text: String, in rect: CGRect, context: CGContext) {
    let attrString = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.black
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attrString)
    context.saveGState()
    context.textMatrix = .identity
    let path = CGPath(rect: rect, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)
    context.restoreGState()
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let top = CGRect(x: 10, y: 10, width: 280, height: 60)
        let bottom = CGRect(x: 10, y: 90, width: 280, height: 60)
        NSColor.systemRed.setStroke()
        NSBezierPath(rect: top).stroke()
        NSBezierPath(rect: bottom).stroke()
        drawText("A 第一行 first line\nB 第二行 second line", in: top, context: ctx)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bottom.minY + bottom.maxY)
        ctx.scaleBy(x: 1, y: -1)
        drawText("A 第一行 first line\nB 第二行 second line", in: bottom, context: ctx)
        ctx.restoreGState()
    }
}

let view = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/et-flipped-text.png"))
print("wrote /tmp/et-flipped-text.png")

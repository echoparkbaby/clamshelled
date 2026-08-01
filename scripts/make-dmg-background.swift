import AppKit

// Renders the DMG window background: an instruction to drag the app into
// /Applications, plus an arrow between the two icon slots. Icon positions here
// must match the ones release.sh gives Finder:
//   app icon slot ≈ x 160, Applications slot ≈ x 480, both at y 180 (from TOP).
//
// Drawn in AppKit's default bottom-left origin — flipping the CTM would mirror
// the glyphs. Uses an explicit NSBitmapImageRep so the PNG is exactly 640x400
// pixels; NSImage.lockFocus() would silently render at the screen's 2x scale.

let W = 640, H = 400
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
/// Converts a "from the top" y (what Finder uses) to AppKit's bottom-left origin.
func fromTop(_ y: CGFloat) -> CGFloat { CGFloat(H) - y }

guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let full = NSRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))
NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.19, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.11, alpha: 1)])?
    .draw(in: full, angle: -90)

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight,
          color: NSColor, topY: CGFloat) {
    let s = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
    let sz = s.size()
    s.draw(at: NSPoint(x: (CGFloat(W) - sz.width) / 2, y: fromTop(topY) - sz.height / 2))
}

draw("Drag Clamshelled into Applications",
     size: 22, weight: .semibold, color: .white, topY: 62)
draw("It won’t work from this window — macOS blocks its helper here.",
     size: 13, weight: .regular,
     color: NSColor(calibratedWhite: 1, alpha: 0.62), topY: 92)

// Arrow between the two icon slots.
let arrowY = fromTop(180)
let shaft = NSBezierPath()
shaft.lineWidth = 5
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 258, y: arrowY))
shaft.line(to: NSPoint(x: 366, y: arrowY))
NSColor(calibratedWhite: 1, alpha: 0.5).setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 390, y: arrowY))
head.line(to: NSPoint(x: 364, y: arrowY - 13))
head.line(to: NSPoint(x: 364, y: arrowY + 13))
head.close()
NSColor(calibratedWhite: 1, alpha: 0.5).setFill()
head.fill()

draw("Then open it from your Applications folder.",
     size: 12, weight: .regular,
     color: NSColor(calibratedWhite: 1, alpha: 0.45), topY: 330)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(W)x\(H))")

#!/usr/bin/env swift
// Generates an .iconset folder for Clamshelled: a rounded squircle with a
// blue→indigo gradient and a white bolt (matching the menu-bar glyph).
// Usage: swift make-icon.swift <output.iconset-dir>

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
}

func renderPNG(pixels: Int) -> Data {
    let px = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded squircle background with a diagonal gradient.
    let inset = px * 0.06
    let rect = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let path = NSBezierPath(roundedRect: rect,
                            xRadius: px * 0.2237, yRadius: px * 0.2237)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.44, blue: 0.99, alpha: 1),
                              ending:   NSColor(srgbRed: 0.40, green: 0.20, blue: 0.88, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    // Hero bolt, centred.
    let bolt = symbolImage("bolt.fill", pointSize: px * 0.5, color: .white)
    let s = bolt.size
    let scale = (px * 0.5) / max(s.width, s.height)
    let w = s.width * scale, h = s.height * scale
    bolt.draw(in: NSRect(x: (px - w) / 2, y: (px - h) / 2, width: w, height: h))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// (filename, pixel size) pairs required by iconutil.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    let data = renderPNG(pixels: size)
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("Wrote \(variants.count) images to \(outDir)")

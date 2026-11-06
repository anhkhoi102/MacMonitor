// Draws MacMonitor's app icon at every size macOS needs, into an .iconset
// folder. `iconutil` (built into macOS) then turns that into AppIcon.icns.
// Called by build.sh – no Xcode or asset catalog needed.
//
// Usage: swift Scripts/make-icon.swift <output.iconset>

import AppKit

guard CommandLine.arguments.count == 2 else {
    print("usage: swift make-icon.swift <output.iconset>")
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels)

    // Apple's icon grid: the rounded square fills ~80% of the canvas.
    let inset = s * 0.098
    let tile = CGRect(x: inset, y: inset * 1.15, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1E3A8A))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: blue → indigo → purple.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x38BDF8), color(0x4F46E5), color(0x7C3AED)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Gauge ring (track + 72% arc).
    let center = CGPoint(x: tile.midX, y: tile.midY)
    let radius = tile.width * 0.30
    let lineWidth = tile.width * 0.075
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(color(0xFFFFFF))
    let start = CGFloat.pi / 2
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - .pi * 2 * 0.72, clockwise: true)
    ctx.strokePath()

    // Pulse line through the middle (live activity).
    let w = radius * 1.25
    let points: [(CGFloat, CGFloat)] = [(-1, 0), (-0.45, 0), (-0.25, 0.42), (-0.02, -0.55), (0.2, 0.25), (0.36, 0), (1, 0)]
    ctx.setLineWidth(lineWidth * 0.55)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.move(to: CGPoint(x: center.x + points[0].0 * w, y: center.y + points[0].1 * w))
    for (x, y) in points.dropFirst() {
        ctx.addLine(to: CGPoint(x: center.x + x * w, y: center.y + y * w))
    }
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Every size/name pair an .iconset must contain.
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (pixels, name) in sizes {
    try drawIcon(pixels: pixels).write(to: output.appending(path: name + ".png"))
}
print("Wrote \(sizes.count) icon images to \(output.path)")

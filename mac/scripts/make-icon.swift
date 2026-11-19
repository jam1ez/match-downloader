import AppKit

// App icon layers for Icon Composer: a play triangle over a red/blue scrubber (the two alliances),
// on the graphite fill set in AppIcon.icon/icon.json. Each layer is flat artwork on a 1024x1024
// canvas; macOS adds the glass, shadows, highlights, masking and the dark, clear and tinted looks.
// Run once to redraw the artwork: swift mac/scripts/make-icon.swift mac/Resources/AppIcon.icon/Assets
// (then fine-tune in Icon Composer if wanted; the build compiles AppIcon.icon as it is).
let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func layer(_ name: String, draw: () -> Void) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

// Play triangle: rounded corners, nudged right so it looks centred.
try layer("play.png") {
    let play = NSBezierPath()
    let cx: CGFloat = 547, cy: CGFloat = 611, h: CGFloat = 360, w: CGFloat = 311
    play.move(to: NSPoint(x: cx - w / 2, y: cy + h / 2)); play.line(to: NSPoint(x: cx + w / 2, y: cy)); play.line(to: NSPoint(x: cx - w / 2, y: cy - h / 2)); play.close()
    play.lineJoinStyle = .round; play.lineWidth = 87
    NSColor.white.setFill(); NSColor.white.setStroke(); play.fill(); play.stroke()
}

// Scrubber: red alliance, blue alliance.
let barY: CGFloat = 231, barH: CGFloat = 65, left: CGFloat = 164, total: CGFloat = 696, gap: CGFloat = 18
let half = (total - gap) / 2
try layer("red.png") {
    color(0xf0443d).setFill()
    NSBezierPath(roundedRect: NSRect(x: left, y: barY, width: half, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
}
try layer("blue.png") {
    color(0x2b86f2).setFill()
    NSBezierPath(roundedRect: NSRect(x: left + half + gap, y: barY, width: half, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
}

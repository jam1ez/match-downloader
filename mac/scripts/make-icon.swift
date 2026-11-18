import AppKit

// App icon: a graphite tile with a play triangle over a red/blue scrubber (the two alliances).
// Drawn with native paths at exactly 1024x1024. The tile follows the macOS grid: 824 pt square, 100 pt margin.
let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// Tile, with a soft shadow beneath it.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.38); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
color(0x232428).setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x45474e), ending: color(0x16171a))!.draw(in: shape, angle: -90)

// A faint light from above, and a hairline edge so the tile holds its shape on dark wallpapers.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.10).setStroke(); shape.lineWidth = 3; shape.stroke()

// Play triangle: filled, rounded corners, nudged right so it looks centred.
let play = NSBezierPath()
let cx: CGFloat = 540, cy: CGFloat = 592, h: CGFloat = 290, w: CGFloat = 250
let top = NSPoint(x: cx - w / 2, y: cy + h / 2), bottom = NSPoint(x: cx - w / 2, y: cy - h / 2), tip = NSPoint(x: cx + w / 2, y: cy)
play.move(to: top); play.line(to: tip); play.line(to: bottom); play.close()
play.lineJoinStyle = .round; play.lineWidth = 70
// Shadow first, on its own, so the white shape on top stays solid.
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow(); glow.shadowColor = NSColor.black.withAlphaComponent(0.32); glow.shadowBlurRadius = 20; glow.shadowOffset = NSSize(width: 0, height: -9)
glow.set()
NSColor.white.setFill(); play.fill()
NSColor.white.setStroke(); play.stroke()
NSGraphicsContext.restoreGraphicsState()
NSColor.white.setFill(); NSColor.white.setStroke(); play.fill(); play.stroke()

// Scrubber: red alliance, blue alliance.
let barY: CGFloat = 286, barH: CGFloat = 52, left: CGFloat = 232, total: CGFloat = 560, gap: CGFloat = 14
let half = (total - gap) / 2
let redBar = NSBezierPath(roundedRect: NSRect(x: left, y: barY, width: half, height: barH), xRadius: barH / 2, yRadius: barH / 2)
let blueBar = NSBezierPath(roundedRect: NSRect(x: left + half + gap, y: barY, width: half, height: barH), xRadius: barH / 2, yRadius: barH / 2)
NSGradient(starting: color(0xff7068), ending: color(0xf0443d))!.draw(in: redBar, angle: -90)
NSGradient(starting: color(0x58acff), ending: color(0x2b86f2))!.draw(in: blueBar, angle: -90)

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

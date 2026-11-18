import AppKit

// Development placeholder: a filmstrip and download arrow, drawn with native paths.
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor.systemBlue.setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 190, yRadius: 190).fill()
NSColor.white.setStroke()
let frame = NSBezierPath(roundedRect: NSRect(x: 240, y: 260, width: 544, height: 510), xRadius: 40, yRadius: 40)
frame.lineWidth = 38; frame.stroke()
for x in [280, 690] { for y in stride(from: 300, through: 700, by: 100) { NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 54, height: 50), xRadius: 8, yRadius: 8).fill() } }
let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 512, y: 690)); arrow.line(to: NSPoint(x: 512, y: 390)); arrow.move(to: NSPoint(x: 405, y: 490)); arrow.line(to: NSPoint(x: 512, y: 380)); arrow.line(to: NSPoint(x: 619, y: 490)); arrow.lineWidth = 40; arrow.lineJoinStyle = .round; arrow.lineCapStyle = .round; arrow.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

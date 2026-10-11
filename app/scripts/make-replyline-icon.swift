import AppKit

// Original Replyline artwork: two conversation bubbles and a hanging line.
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 204, yRadius: 204)
NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.46, alpha: 1),
           ending: NSColor(calibratedRed: 0.06, green: 0.25, blue: 0.31, alpha: 1))!.draw(in: background, angle: -90)
NSColor.white.withAlphaComponent(0.45).setStroke()
let line = NSBezierPath()
line.move(to: NSPoint(x: 175, y: 760))
line.curve(to: NSPoint(x: 850, y: 760), controlPoint1: NSPoint(x: 370, y: 665), controlPoint2: NSPoint(x: 655, y: 665))
line.lineWidth = 6
line.stroke()
NSColor.white.withAlphaComponent(0.25).setFill()
NSBezierPath(roundedRect: NSRect(x: 410, y: 220, width: 390, height: 300), xRadius: 62, yRadius: 62).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 218, y: 355, width: 440, height: 325), xRadius: 62, yRadius: 62).fill()
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 295, y: 375)); tail.line(to: NSPoint(x: 275, y: 300)); tail.line(to: NSPoint(x: 375, y: 375)); tail.close(); tail.fill()
NSColor(calibratedRed: 0.09, green: 0.35, blue: 0.37, alpha: 1).setFill()
for x in [340, 438, 536] {
    NSBezierPath(ovalIn: NSRect(x: x - 19, y: 504, width: 38, height: 38)).fill()
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

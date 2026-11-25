import AppKit

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let shape = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.25, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.08, blue: 0.12, alpha: 1))!.draw(in: shape, angle: -65)
let wave = NSBezierPath()
wave.lineWidth = 46
wave.lineCapStyle = .round
wave.lineJoinStyle = .round
wave.move(to: NSPoint(x: 177, y: 512))
for (x, y) in [(295.0, 512.0), (355, 655), (427, 330), (502, 741), (577, 283), (644, 578), (701, 512), (847, 512)] { wave.line(to: NSPoint(x: x, y: y)) }
NSColor(calibratedRed: 0.18, green: 0.88, blue: 0.83, alpha: 1).setStroke()
wave.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

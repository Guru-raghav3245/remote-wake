import AppKit
// usage: swift make_bg.swift out.png  -> 600x400 background with an arrow between the two icon slots
let w = 600, h = 400
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()
NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
// light on purpose: Finder draws the icon names in black, which a dark background would hide
let c = NSColor(red: 0.18, green: 0.62, blue: 0.45, alpha: 1); c.setStroke(); c.setFill()
let y: CGFloat = 215   // icon centres sit at y=190 from the top = 210 from the bottom
let p = NSBezierPath(); p.lineWidth = 6; p.lineCapStyle = .round
p.move(to: NSPoint(x: 230, y: y)); p.line(to: NSPoint(x: 355, y: y)); p.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 375, y: y)); head.line(to: NSPoint(x: 345, y: y + 18)); head.line(to: NSPoint(x: 345, y: y - 18)); head.close(); head.fill()
let t = "$ drag Remote Wake to Applications" as NSString
let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: c]
t.draw(at: NSPoint(x: (CGFloat(w) - t.size(withAttributes: a).width) / 2, y: 60), withAttributes: a)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

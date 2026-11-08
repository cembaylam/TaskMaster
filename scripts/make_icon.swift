import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
let bg = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(colors: [NSColor(red: 0.10, green: 0.45, blue: 0.80, alpha: 1), NSColor(red: 0.04, green: 0.20, blue: 0.45, alpha: 1)])!.draw(in: bg, angle: -90)
NSColor.white.withAlphaComponent(0.18).setStroke()
for i in 1..<8 {
    let y = rect.minY + rect.height * CGFloat(i) / 8
    let p = NSBezierPath(); p.move(to: NSPoint(x: rect.minX + 40, y: y)); p.line(to: NSPoint(x: rect.maxX - 40, y: y)); p.lineWidth = 3; p.stroke()
}
let pts: [CGFloat] = [0.25, 0.35, 0.30, 0.55, 0.45, 0.75, 0.50, 0.62, 0.82, 0.58]
let line = NSBezierPath()
let area = NSBezierPath()
let x0 = rect.minX + 80, w = rect.width - 160
for (i, v) in pts.enumerated() {
    let pt = NSPoint(x: x0 + w * CGFloat(i) / CGFloat(pts.count - 1), y: rect.minY + 120 + (rect.height - 260) * v)
    if i == 0 { line.move(to: pt); area.move(to: NSPoint(x: pt.x, y: rect.minY + 100)); area.line(to: pt) } else { line.line(to: pt); area.line(to: pt) }
}
area.line(to: NSPoint(x: x0 + w, y: rect.minY + 100)); area.close()
NSColor.white.withAlphaComponent(0.22).setFill(); area.fill()
NSColor.white.setStroke(); line.lineWidth = 26; line.lineJoinStyle = .round; line.lineCapStyle = .round; line.stroke()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

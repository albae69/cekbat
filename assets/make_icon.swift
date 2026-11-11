#!/usr/bin/env swift
// Renders assets/icon.png (1024x1024) — CekBat branding.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let s = CGFloat(size)
let mint = NSColor(srgbRed: 0.24, green: 0.86, blue: 0.59, alpha: 1)

// Tile
let inset: CGFloat = 72
let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 224, yRadius: 224)
NSGradient(colors: [
    NSColor(srgbRed: 0.20, green: 0.22, blue: 0.25, alpha: 1),
    NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
])!.draw(in: tilePath, angle: -90)
NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06).setStroke()
tilePath.lineWidth = 3
tilePath.stroke()

// Battery
let body = NSRect(x: 282, y: 408, width: 460, height: 208)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 54, yRadius: 54)
mint.setStroke()
bodyPath.lineWidth = 26
bodyPath.stroke()

let nub = NSBezierPath(roundedRect: NSRect(x: 756, y: 478, width: 46, height: 68),
                       xRadius: 20, yRadius: 20)
mint.setFill()
nub.fill()

let inner = body.insetBy(dx: 30, dy: 30)
let fill = NSRect(x: inner.minX, y: inner.minY,
                  width: inner.width * 0.62, height: inner.height)
NSBezierPath(roundedRect: fill, xRadius: 30, yRadius: 30).fill()

// Cycle arrow around the battery
let center = NSPoint(x: s / 2, y: s / 2)
let radius: CGFloat = 306
let arc = NSBezierPath()
arc.appendArc(withCenter: center, radius: radius,
              startAngle: 34, endAngle: 326, clockwise: false)
arc.lineWidth = 26
arc.lineCapStyle = .round
mint.setStroke()
arc.stroke()

// Arrowhead at the arc end
let a = 326.0 * .pi / 180
let p = NSPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
let tangent = NSPoint(x: -sin(a), y: cos(a))
let normal = NSPoint(x: cos(a), y: sin(a))
let head = NSBezierPath()
head.move(to: NSPoint(x: p.x + tangent.x * 54, y: p.y + tangent.y * 54))
head.line(to: NSPoint(x: p.x - normal.x * 44, y: p.y - normal.y * 44))
head.line(to: NSPoint(x: p.x + normal.x * 44, y: p.y + normal.y * 44))
head.close()
mint.setFill()
head.fill()

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: "assets/icon.png")
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")

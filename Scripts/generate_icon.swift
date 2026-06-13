#!/usr/bin/env swift

import Cocoa

let s: CGFloat = 1024
let corner: CGFloat = 225

let image = NSImage(size: NSSize(width: s, height: s))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    print("Failed to get CGContext")
    exit(1)
}

let bg = CGRect(x: 0, y: 0, width: s, height: s)

// Background rounded rect
let bgPath = CGPath(roundedRect: bg, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

// Gradient: top → bottom
let colors = [
    CGColor(red: 0.05, green: 0.52, blue: 1, alpha: 1),
    CGColor(red: 0, green: 0.33, blue: 0.78, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
    start: CGPoint(x: 0, y: s),
    end: CGPoint(x: 0, y: 0),
    options: [])

// Subtle top highlight
ctx.addPath(bgPath)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
ctx.fillPath()

// Pin shadow
let shadow = CGMutablePath()
shadow.addEllipse(in: CGRect(x: s * 0.38, y: s * 0.26, width: s * 0.24, height: s * 0.04))
ctx.addPath(shadow)
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.12))
ctx.fillPath()

// Location pin — centered, pointing down
let pin = CGMutablePath()
let cx = s * 0.5
let pinTop = s * 0.78
let pinTip = s * 0.35
let pinW = s * 0.18

// Pin is a teardrop shape: wide at top, tapering to a point at bottom
pin.move(to: CGPoint(x: cx, y: pinTop))
pin.addCurve(to: CGPoint(x: cx - pinW * 0.9, y: s * 0.55),
             control1: CGPoint(x: cx - pinW * 0.3, y: pinTop),
             control2: CGPoint(x: cx - pinW * 0.9, y: s * 0.67))
pin.addCurve(to: CGPoint(x: cx - pinW * 0.25, y: pinTip),
             control1: CGPoint(x: cx - pinW * 0.9, y: s * 0.45),
             control2: CGPoint(x: cx - pinW * 0.4, y: s * 0.38))
pin.addCurve(to: CGPoint(x: cx, y: pinTip - s * 0.02),
             control1: CGPoint(x: cx - pinW * 0.15, y: pinTip),
             control2: CGPoint(x: cx - pinW * 0.05, y: pinTip - s * 0.01))
pin.addCurve(to: CGPoint(x: cx + pinW * 0.25, y: pinTip),
             control1: CGPoint(x: cx + pinW * 0.05, y: pinTip - s * 0.01),
             control2: CGPoint(x: cx + pinW * 0.15, y: pinTip))
pin.addCurve(to: CGPoint(x: cx + pinW * 0.9, y: s * 0.55),
             control1: CGPoint(x: cx + pinW * 0.4, y: s * 0.38),
             control2: CGPoint(x: cx + pinW * 0.9, y: s * 0.45))
pin.addCurve(to: CGPoint(x: cx, y: pinTop),
             control1: CGPoint(x: cx + pinW * 0.9, y: s * 0.67),
             control2: CGPoint(x: cx + pinW * 0.3, y: pinTop))
pin.closeSubpath()

ctx.addPath(pin)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()

// Subtle highlight on pin left side
let pinHighlight = CGMutablePath()
pinHighlight.addPath(pin)
ctx.addPath(pinHighlight)
ctx.clip()
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
ctx.fill(CGRect(x: 0, y: 0, width: cx, height: s))

// Reset clip
ctx.resetClip()
ctx.addPath(bgPath)
ctx.clip()

// Inner hole
let holeR = s * 0.065
ctx.addEllipse(in: CGRect(x: cx - holeR, y: s * 0.47 - holeR, width: holeR * 2, height: holeR * 2))
ctx.setBlendMode(.clear)
ctx.fillPath()

image.unlockFocus()

// Write PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("Failed to generate PNG")
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/appicon_1024.png"

try png.write(to: URL(fileURLWithPath: outputPath))
print("✅ Icon generated: \(outputPath)")

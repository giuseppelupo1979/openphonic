// Renders the OpenPhonic app icon (1024 px) - run: swift tools/make-icon.swift out.png
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// macOS grid: 824 px squircle centred, soft drop shadow
let box = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: box, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: c(0, 0, 0, 0.45))
ctx.addPath(shape); ctx.setFillColor(c(0.04, 0.03, 0.07)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// base: deep night gradient
let base = CGGradient(colorsSpace: cs, colors: [c(0.10, 0.04, 0.15), c(0.02, 0.02, 0.05)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
// aurora glows
func glow(_ p: CGPoint, _ r: CGFloat, _ col: CGColor) {
    let g = CGGradient(colorsSpace: cs, colors: [col, col.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}
glow(CGPoint(x: 230, y: 860), 520, c(1.0, 0.42, 0.24, 0.34))
glow(CGPoint(x: 860, y: 200), 560, c(0.55, 0.36, 0.97, 0.42))
glow(CGPoint(x: 520, y: 300), 420, c(1.0, 0.24, 0.55, 0.26))

// waveform bars with glow
let heights: [CGFloat] = [0.22, 0.42, 0.66, 0.88, 1.0, 0.80, 0.58, 0.38, 0.20]
let barW: CGFloat = 46, gap: CGFloat = 30
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let x0 = (S - total) / 2, maxH: CGFloat = 520, cy = S / 2
let bars = CGMutablePath()
for (i, h) in heights.enumerated() {
    let bh = maxH * h
    bars.addPath(CGPath(roundedRect: CGRect(x: x0 + CGFloat(i) * (barW + gap), y: cy - bh / 2, width: barW, height: bh),
                        cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
}
let barGrad = CGGradient(colorsSpace: cs, colors: [c(1.0, 0.55, 0.30), c(1.0, 0.27, 0.58), c(0.62, 0.42, 1.0)] as CFArray,
                         locations: [0, 0.5, 1])!
for (blur, alpha) in [(90.0, 0.55), (36.0, 0.7)] {   // two-pass neon glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: c(1.0, 0.3, 0.6, alpha))
    ctx.addPath(bars); ctx.setFillColor(c(1, 0.4, 0.6, 0.9)); ctx.fillPath()
    ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(bars); ctx.clip()
ctx.drawLinearGradient(barGrad, start: CGPoint(x: x0, y: cy), end: CGPoint(x: x0 + total, y: cy), options: [])
// inner highlight on the bars
let shine = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.22), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: cy + maxH / 2), end: CGPoint(x: 0, y: cy), options: [])
ctx.restoreGState()

// glass gloss on the top half
let gloss = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.10), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.midY + 40), options: [])
ctx.restoreGState()

// hairline rim
ctx.addPath(shape); ctx.setStrokeColor(c(1, 1, 1, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

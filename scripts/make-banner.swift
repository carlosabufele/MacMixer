// Draws the README banner (docs/banner.png): app icon, name, tagline, "by Clutch Apps".
// Usage (from the repo root): swift scripts/make-banner.swift
import AppKit

let W = 1600, H = 520
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let w = CGFloat(W), h = CGFloat(H)
let space = CGColorSpaceCreateDeviceRGB()
let blue = NSColor(red: 0.20, green: 0.52, blue: 1.00, alpha: 1)
let purple = NSColor(red: 0.56, green: 0.30, blue: 0.98, alpha: 1)
let orange = NSColor(red: 1.00, green: 0.42, blue: 0.13, alpha: 1)

// Rounded dark card (transparent corners look good on GitHub's light and dark themes).
let card = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 36, cornerHeight: 36, transform: nil)
ctx.addPath(card); ctx.clip()
ctx.setFillColor(NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
// Brand-colour glows.
for (color, x, y, r) in [(purple, w * 0.18, h * 0.55, w * 0.42), (blue, w * 0.92, h * 0.1, w * 0.35)] {
    let g = CGGradient(colorsSpace: space, colors: [color.withAlphaComponent(0.40).cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}

// App icon on the left.
let icon = NSImage(contentsOfFile: "MacMixer/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")!
icon.draw(in: NSRect(x: 90, y: (h - 340) / 2, width: 340, height: 340))

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: size) ?? base
}
NSAttributedString(string: "MacMixer", attributes: [.font: rounded(128, .heavy), .foregroundColor: NSColor.white, .kern: -2])
    .draw(at: CGPoint(x: 480, y: 250))
NSAttributedString(string: "Per-app volume control for your Mac's menu bar.",
                   attributes: [.font: rounded(38, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.72)])
    .draw(at: CGPoint(x: 486, y: 190))
let by = NSMutableAttributedString(string: "by ", attributes: [.font: rounded(32, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.5)])
by.append(NSAttributedString(string: "Clutch Apps", attributes: [.font: rounded(32, .heavy), .foregroundColor: orange]))
by.draw(at: CGPoint(x: 487, y: 118))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/banner.png"))
print("wrote docs/banner.png")

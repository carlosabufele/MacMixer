// Draws MacMixer's app icon and writes every size the asset catalog needs.
//
// Usage (from the repo root):
//   swift scripts/make-icon.swift MacMixer/Assets.xcassets/AppIcon.appiconset
//
// The icon: a macOS-style rounded square with a blue-to-purple gradient and
// three vertical mixer sliders with white knobs at different heights.
import AppKit

let outputFolder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024   // everything below is designed on a 1024 x 1024 canvas

    // Body: Apple's icon grid puts the rounded square at 824 x 824, inset 100.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill, blue at the top left to purple at the bottom right.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let colors = [NSColor(red: 0.20, green: 0.52, blue: 1.00, alpha: 1).cgColor,
                  NSColor(red: 0.56, green: 0.30, blue: 0.98, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // Three slider tracks with knobs (y measured from the bottom).
    let trackXs: [CGFloat] = [342, 512, 682]
    let knobYs: [CGFloat] = [610, 400, 540]
    let trackBottom: CGFloat = 270, trackTop: CGFloat = 754
    for (x, knobY) in zip(trackXs, knobYs) {
        // Track: a thin rounded line.
        let track = CGRect(x: (x - 14) * s, y: trackBottom * s, width: 28 * s, height: (trackTop - trackBottom) * s)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 14 * s, cornerHeight: 14 * s, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.fillPath()

        // Knob: a white pill with a soft shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
        let knob = CGRect(x: (x - 62) * s, y: (knobY - 34) * s, width: 124 * s, height: 68 * s)
        ctx.addPath(CGPath(roundedRect: knob, cornerWidth: 34 * s, cornerHeight: 34 * s, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Every size macOS asks for: 16, 32, 128, 256, 512 points at 1x and 2x.
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!
        try! data.write(to: outputFolder.appendingPathComponent(filename))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": filename])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outputFolder.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outputFolder.path)")

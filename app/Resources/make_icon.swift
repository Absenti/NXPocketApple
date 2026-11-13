// The app icon (Assets.xcassets/AppIcon.appiconset), the library's logo (Logo.imageset) and the Mac launcher's icon
// come from this drawing: an amber pocket with a card (and its play mark) standing in it. Not part of any target. To change it, edit and
// run it on the Mac, then copy the PNGs:
//   swift app/Resources/make_icon.swift /tmp/AppIcon-1024.png
//   cp /tmp/AppIcon-1024.png app/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   sips -Z 256 /tmp/AppIcon-1024.png --out app/Resources/Assets.xcassets/Logo.imageset/Logo.png
//   swift app/Resources/make_icon.swift /tmp/MacIcon-1024.png mac      # a squircle with margin, for macOS
//   cp /tmp/MacIcon-1024.png mac/Resources/AppIcon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let forMac = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "mac"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// iOS wants a full-bleed square without alpha (the system rounds it); macOS wants its own rounded shape with margin.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: (forMac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func hex(_ v: Int, _ a: Double = 1) -> CGColor { rgb(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, a) }
// y up in CoreGraphics: flip so the numbers below read top-down.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

// On macOS the artwork sits in an 824 pt squircle centred in the 1024 canvas, with a soft shadow below it.
var unit = Double(size) / 200.0
if forMac {
    let inset = 100.0, side = 824.0
    let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: hex(0x000000, 0.4))
    ctx.addPath(shape); ctx.setFillColor(hex(0x17171C)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
    ctx.translateBy(x: CGFloat(inset), y: CGFloat(inset))
    unit = side / 200.0
}

// Everything below is drawn on a 200 x 200 grid.
ctx.scaleBy(x: CGFloat(unit), y: CGFloat(unit))

// Background: charcoal, a touch lighter at the top, with a very faint amber glow behind the pocket.
let bg = CGGradient(colorsSpace: space, colors: [hex(0x1E1E25), hex(0x121216)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 200), options: [])
let glow = CGGradient(colorsSpace: space, colors: [hex(0xEFB15A, 0.12), hex(0xEFB15A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 100, y: 120), startRadius: 0, endCenter: CGPoint(x: 100, y: 120), endRadius: 100, options: [])

// The card: cream, with a play mark, standing in the pocket.
let card = CGPath(roundedRect: CGRect(x: 62, y: 36, width: 76, height: 92), cornerWidth: 12, cornerHeight: 12, transform: nil)
ctx.addPath(card); ctx.setFillColor(hex(0xF1ECE3)); ctx.fillPath()
let play = CGMutablePath()
play.move(to: CGPoint(x: 92, y: 68)); play.addLine(to: CGPoint(x: 92, y: 98)); play.addLine(to: CGPoint(x: 118, y: 83)); play.closeSubpath()
ctx.setLineJoin(.round)
ctx.addPath(play)
ctx.setFillColor(hex(0x17171C)); ctx.setStrokeColor(hex(0x17171C)); ctx.setLineWidth(8)
ctx.drawPath(using: .fillStroke)

// The pocket: flat amber, rounded at the bottom, with a single stitch along the opening.
let pocket = CGMutablePath()
pocket.move(to: CGPoint(x: 38, y: 112))
pocket.addQuadCurve(to: CGPoint(x: 48, y: 102), control: CGPoint(x: 38, y: 102))
pocket.addLine(to: CGPoint(x: 152, y: 102))
pocket.addQuadCurve(to: CGPoint(x: 162, y: 112), control: CGPoint(x: 162, y: 102))
pocket.addLine(to: CGPoint(x: 162, y: 152))
pocket.addQuadCurve(to: CGPoint(x: 148, y: 166), control: CGPoint(x: 162, y: 166))
pocket.addLine(to: CGPoint(x: 52, y: 166))
pocket.addQuadCurve(to: CGPoint(x: 38, y: 152), control: CGPoint(x: 38, y: 166))
pocket.closeSubpath()
ctx.addPath(pocket); ctx.setFillColor(hex(0xEFB15A)); ctx.fillPath()
ctx.move(to: CGPoint(x: 54, y: 120)); ctx.addLine(to: CGPoint(x: 146, y: 120))
ctx.setStrokeColor(hex(0x17171C, 0.5)); ctx.setLineWidth(3.5); ctx.setLineCap(.round); ctx.setLineDash(phase: 0, lengths: [7, 7])
ctx.strokePath()

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")

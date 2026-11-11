// The app icon (Assets.xcassets/AppIcon.appiconset) and the library's logo (Logo.imageset) come from this drawing.
// Not part of any target. To change the icon, edit and run it on the Mac, then copy the PNG into both sets:
//   swift app/Resources/make_icon.swift /tmp/AppIcon-1024.png
//   cp /tmp/AppIcon-1024.png app/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   sips -Z 256 /tmp/AppIcon-1024.png --out app/Resources/Assets.xcassets/Logo.imageset/Logo.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func hex(_ v: Int, _ a: Double = 1) -> CGColor { rgb(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255, a) }
// y up in CoreGraphics: flip so the numbers below read top-down.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

// Background: warm charcoal, lighter at the top left, and a soft amber glow where the pocket is.
let bg = CGGradient(colorsSpace: space, colors: [hex(0x2B2630), hex(0x121216)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
let glow = CGGradient(colorsSpace: space, colors: [hex(0xEFB15A, 0.28), hex(0xEFB15A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 640), startRadius: 0, endCenter: CGPoint(x: 512, y: 640), endRadius: 520, options: [])

// The cartridge: cream, a label window, grip ridges at the top. Slightly tilted, half in the pocket.
ctx.saveGState()
ctx.translateBy(x: 512, y: 470); ctx.rotate(by: -0.12)
let cart = CGRect(x: -190, y: -300, width: 380, height: 470)
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: hex(0x000000, 0.45))
ctx.addPath(CGPath(roundedRect: cart, cornerWidth: 46, cornerHeight: 46, transform: nil))
ctx.setFillColor(hex(0xF1ECE3)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// a notch at the top right corner, as cartridges have
ctx.addPath(CGPath(roundedRect: CGRect(x: 120, y: -300, width: 70, height: 70), cornerWidth: 20, cornerHeight: 20, transform: nil))
ctx.setFillColor(hex(0xD9D2C6)); ctx.fillPath()
// label
let label = CGRect(x: -140, y: -200, width: 280, height: 250)
ctx.addPath(CGPath(roundedRect: label, cornerWidth: 26, cornerHeight: 26, transform: nil))
let labelGradient = CGGradient(colorsSpace: space, colors: [hex(0x34303A), hex(0x1C1B21)] as CFArray, locations: [0, 1])!
ctx.saveGState(); ctx.clip(); ctx.drawLinearGradient(labelGradient, start: CGPoint(x: 0, y: -200), end: CGPoint(x: 0, y: 50), options: []); ctx.restoreGState()
// a play mark on the label
let play = CGMutablePath()
play.move(to: CGPoint(x: -38, y: -130)); play.addLine(to: CGPoint(x: 58, y: -75)); play.addLine(to: CGPoint(x: -38, y: -20)); play.closeSubpath()
ctx.addPath(play); ctx.setFillColor(hex(0xEFB15A)); ctx.fillPath()
// grip ridges
ctx.setFillColor(hex(0xCFC7BA))
for i in 0..<3 { ctx.fill(CGRect(x: -110, y: -270 + Double(i) * 20, width: 190, height: 8)) }
ctx.restoreGState()

// The pocket: amber, rounded at the bottom, its opening a gentle curve, stitched along the edge.
let pocket = CGMutablePath()
let left = 196.0, right = 828.0, top = 560.0, bottom = 892.0, r = 150.0
pocket.move(to: CGPoint(x: left, y: top))
pocket.addQuadCurve(to: CGPoint(x: right, y: top), control: CGPoint(x: 512, y: top + 70))
pocket.addLine(to: CGPoint(x: right, y: bottom - r))
pocket.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
pocket.addLine(to: CGPoint(x: left + r, y: bottom))
pocket.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
pocket.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: hex(0x000000, 0.35))
ctx.addPath(pocket); ctx.setFillColor(hex(0xEFB15A)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(pocket); ctx.clip()
let pocketGradient = CGGradient(colorsSpace: space, colors: [hex(0xF4BE6E), hex(0xD98F3A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(pocketGradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
ctx.restoreGState()
// stitches: the same outline inset
let stitch = CGMutablePath()
let i = 34.0
stitch.move(to: CGPoint(x: left + i, y: top + i + 4))
stitch.addQuadCurve(to: CGPoint(x: right - i, y: top + i + 4), control: CGPoint(x: 512, y: top + 70 + i))
stitch.addLine(to: CGPoint(x: right - i, y: bottom - r))
stitch.addQuadCurve(to: CGPoint(x: right - r, y: bottom - i), control: CGPoint(x: right - i, y: bottom - i))
stitch.addLine(to: CGPoint(x: left + r, y: bottom - i))
stitch.addQuadCurve(to: CGPoint(x: left + i, y: bottom - r), control: CGPoint(x: left + i, y: bottom - i))
stitch.closeSubpath()
ctx.addPath(stitch)
ctx.setStrokeColor(hex(0x7A4A16, 0.55)); ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.setLineDash(phase: 0, lengths: [26, 22])
ctx.strokePath()

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")

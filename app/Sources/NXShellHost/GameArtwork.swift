import ImageIO
import NXPocketKit
import NXShellUI
import SwiftUI
import UIKit

/// A game's icon, wherever the game appears. The engine's build puts `icon.png` in the framework whether or not the manifest
/// names it, and the games built so far have no `icon` in their manifest: the manifest's file comes first, then the
/// framework's `icon.png`. Each file is decoded once per version, at a bounded size, and kept in memory, since the library
/// redraws often.
enum GameArtwork {
    static func iconURL(for game: InstalledGame, fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        if let named = game.iconURL { candidates.append(named) }
        if let framework = game.frameworkURL {
            candidates += ["icon.png", "icon.jpg"].map { framework.appendingPathComponent($0) }
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static let cache = NSCache<NSString, UIImage>()

    /// The icons are drawn at most this many pixels on a side (a cover at three times its largest size on screen).
    static let maxPixels = 768
    /// A larger file is no icon: it is not decoded at all.
    static let maxFileBytes: Int64 = 16 << 20

    static func icon(for game: InstalledGame) -> UIImage? {
        guard let url = iconURL(for: game) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)#\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let thumbnail = thumbnail(at: url, maxPixels: maxPixels) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key)
        return image
    }

    /// The image decoded straight at a bounded size by ImageIO: a package's icon is a file anyone can replace through
    /// Files, and decoding a huge one at full resolution for every cover would exhaust the app's memory.
    static func thumbnail(at url: URL, maxPixels: Int, fileManager: FileManager = .default) -> CGImage? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.int64Value ?? .max) <= maxFileBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The icon in a square, or a placeholder that says why there is none.
struct GameIcon: View {
    let game: InstalledGame
    var cornerRadius: CGFloat = 10

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(ShellInk.raised)
            .overlay {
                if let icon = GameArtwork.icon(for: game) {
                    Image(uiImage: icon).resizable().scaledToFill()
                } else {
                    Image(systemName: game.isBroken ? "exclamationmark.triangle" : "gamecontroller")
                        .font(.system(size: 26)).foregroundStyle(game.isBroken ? ShellInk.bad : ShellInk.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}


/// The colours a game lends its screen, taken from its picture: a glow for the background and a fill for the main
/// button. Soft on purpose: the picture's own colour, never a flat neon. The Mac launcher does the same for the
/// game it has selected.
struct GameTheme {
    var glow: Color
    var fill: Color
    /// The light pastel of the main pill under the covers.
    var bright: Color

    static let standard = GameTheme(glow: ShellInk.accent, fill: ShellInk.deep, bright: Color(red: 0.96, green: 0.76, blue: 0.47))

    init(glow: Color, fill: Color, bright: Color) {
        self.glow = glow
        self.fill = fill
        self.bright = bright
    }

    init(hue: Double, saturation: Double) {
        let s = min(max(saturation, 0.35), 0.75)
        glow = Color(hue: hue, saturation: s, brightness: 0.85)
        fill = Color(hue: hue, saturation: min(s, 0.6) * 0.9, brightness: 0.80)
        bright = Color(hue: hue, saturation: min(s, 0.55) * 0.85, brightness: 0.98)
    }
}

enum ArtTheme {
    private static var cache: [String: GameTheme] = [:]

    /// The theme of a game's picture: the hue most of its colour sits in, weighted by how vivid it is. A picture with no
    /// colour of its own (grey, black and white) or none at all keeps the standard amber. Read once per picture.
    @MainActor
    static func theme(for game: InstalledGame) -> GameTheme {
        // The key reads nothing from disk: this runs on every render of the game's screen. A game that is updated
        // changes its version or size, which is when its picture may have changed too.
        let key = "\(game.id)#\(game.version)#\(game.byteCount)"
        if let known = cache[key] { return known }
        let result = GameArtwork.icon(for: game)?.cgImage.flatMap(compute) ?? .standard
        cache[key] = result
        return result
    }

    private static func compute(_ cg: CGImage) -> GameTheme? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var x = 0.0, y = 0.0, weight = 0.0, saturationSum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let color = UIColor(red: Double(pixels[index]) / 255 / alpha, green: Double(pixels[index + 1]) / 255 / alpha,
                                blue: Double(pixels[index + 2]) / 255 / alpha, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a), b > 0.18, s > 0.2 else { continue }
            let w = Double(s * b)
            x += cos(Double(h) * 2 * .pi) * w
            y += sin(Double(h) * 2 * .pi) * w
            saturationSum += Double(s) * w
            weight += w
        }
        guard weight > 3 else { return nil }
        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return GameTheme(hue: hue, saturation: saturationSum / weight)
    }
}

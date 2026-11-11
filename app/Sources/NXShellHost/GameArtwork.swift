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

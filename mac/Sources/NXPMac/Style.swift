import AppKit
import SwiftUI

enum Ink {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.070)
    static let surface = Color(red: 0.090, green: 0.090, blue: 0.110)
    static let raised = Color(red: 0.125, green: 0.125, blue: 0.150)
    static let line = Color.white.opacity(0.08)
    static let primary = Color(red: 0.945, green: 0.925, blue: 0.890)
    static let secondary = Color.white.opacity(0.55)
    static let accent = Color(red: 0.937, green: 0.694, blue: 0.353)
    static let good = Color(red: 0.435, green: 0.780, blue: 0.510)
    static let bad = Color(red: 0.925, green: 0.420, blue: 0.400)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Ink.line))
    }
}

struct SectionHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Ink.secondary)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Ink.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Bar: View {
    let fraction: Double
    var tint: Color = Ink.accent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint).frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.primary)
            content
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        }
    }
}

/// A tick box drawn in the app's colours: SwiftUI's checkbox toggle ignores the accent on a dark custom background.
struct TickBox: View {
    let checked: Bool
    var disabled = false

    var body: some View {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
            .font(.system(size: 14))
            .foregroundStyle(disabled ? Ink.secondary.opacity(0.6) : (checked ? Ink.accent : Ink.secondary))
    }
}

/// A game's picture: its icon when there is one (a built game's icon.png, an unbuilt one's control data), else a
/// placeholder.
struct Thumbnail: View {
    let image: NSImage?
    var size: CGFloat = 44
    var symbol = "gamecontroller"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Ink.raised)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.4)).foregroundStyle(Ink.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

/// Decoded icons, so a list redraw does not decode a JPEG or read an icon.png again for every row.
@MainActor
enum IconCache {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(key: String, data: Data?) -> NSImage? {
        if let image = images[key] { return image }
        guard let data, !missing.contains(key) else { return nil }
        guard let image = NSImage(data: data) else {
            missing.insert(key)
            return nil
        }
        images[key] = image
        return image
    }

    static func image(contentsOf url: URL) -> NSImage? {
        let key = url.path
        if let image = images[key] { return image }
        guard !missing.contains(key) else { return nil }
        guard let image = NSImage(contentsOf: url) else {
            missing.insert(key)
            return nil
        }
        images[key] = image
        return image
    }

    /// A rebuilt package has a new icon file at the same path.
    static func forget(_ url: URL) {
        images[url.path] = nil
        missing.remove(url.path)
    }
}

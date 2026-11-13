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
    /// The amber for fills and buttons: deeper than `accent`, which stays for icons, numbers and hairlines, so a
    /// large amber surface never glares on the dark ground.
    static let deep = Color(red: 0.788, green: 0.561, blue: 0.290)
    static let onDeep = Color(red: 0.078, green: 0.063, blue: 0.039)
    /// A faint amber wash for the selected row and the notices.
    static let tint = Color(red: 0.937, green: 0.694, blue: 0.353).opacity(0.12)
    static let good = Color(red: 0.435, green: 0.780, blue: 0.510)
    static let bad = Color(red: 0.925, green: 0.420, blue: 0.400)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.line))
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
    var tint: Color = Ink.deep

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(tint).frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
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
            .foregroundStyle(disabled ? Ink.secondary.opacity(0.6) : (checked ? Ink.deep : Ink.secondary))
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


// MARK: - Brand and controls

/// The app's mark: an amber pocket with a card and its play mark, on a charcoal squircle. Drawn, not loaded, so it
/// needs no resource bundle. The same drawing makes the icons (app/Resources/make_icon.swift).
struct PocketMark: View {
    var size: CGFloat = 40

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 200
            let shape = Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: canvas.width * 0.23, style: .continuous)
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [Color(red: 0.118, green: 0.118, blue: 0.145), Color(red: 0.071, green: 0.071, blue: 0.086)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: canvas.height)))
            var inner = context
            inner.scaleBy(x: unit, y: unit)
            let ground = Color(red: 0.09, green: 0.09, blue: 0.11)
            inner.fill(Path(roundedRect: CGRect(x: 62, y: 36, width: 76, height: 92), cornerRadius: 12),
                       with: .color(Color(red: 0.945, green: 0.925, blue: 0.890)))
            var play = Path()
            play.move(to: CGPoint(x: 92, y: 68)); play.addLine(to: CGPoint(x: 92, y: 98)); play.addLine(to: CGPoint(x: 118, y: 83))
            play.closeSubpath()
            inner.fill(play, with: .color(ground))
            inner.stroke(play, with: .color(ground), style: StrokeStyle(lineWidth: 8, lineJoin: .round))
            var pocket = Path()
            pocket.move(to: CGPoint(x: 38, y: 112))
            pocket.addQuadCurve(to: CGPoint(x: 48, y: 102), control: CGPoint(x: 38, y: 102))
            pocket.addLine(to: CGPoint(x: 152, y: 102))
            pocket.addQuadCurve(to: CGPoint(x: 162, y: 112), control: CGPoint(x: 162, y: 102))
            pocket.addLine(to: CGPoint(x: 162, y: 152))
            pocket.addQuadCurve(to: CGPoint(x: 148, y: 166), control: CGPoint(x: 162, y: 166))
            pocket.addLine(to: CGPoint(x: 52, y: 166))
            pocket.addQuadCurve(to: CGPoint(x: 38, y: 152), control: CGPoint(x: 38, y: 166))
            pocket.closeSubpath()
            inner.fill(pocket, with: .color(Ink.accent))
            var stitch = Path()
            stitch.move(to: CGPoint(x: 54, y: 120)); stitch.addLine(to: CGPoint(x: 146, y: 120))
            inner.stroke(stitch, with: .color(ground.opacity(0.5)),
                         style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [7, 7]))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The main button: deep amber, dark label. One per area.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    var fill: Color = Ink.deep
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .bold))
            .foregroundStyle(Ink.onDeep)
            .padding(.horizontal, large ? 18 : 12)
            .frame(height: large ? 40 : 30)
            .background(fill, in: RoundedRectangle(cornerRadius: large ? 12 : 10, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The quiet button: a raised chip with a hairline.
struct QuietButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13.5 : 13, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, large ? 16 : 12)
            .frame(height: large ? 36 : 30)
            .background(Ink.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ink.line))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A keyboard shortcut shown next to what it does.
struct Kbd: View {
    let text: String
    var onFill = false

    init(_ text: String, onFill: Bool = false) {
        self.text = text
        self.onFill = onFill
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(onFill ? Ink.onDeep.opacity(0.8) : Ink.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((onFill ? Color.black.opacity(0.18) : Color.white.opacity(0.10)), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A page title in the app's large, tight style, with a line under it.
struct PageTitle: View {
    let title: String
    var size: CGFloat = 40
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: size, weight: .heavy)).tracking(-size * 0.035).foregroundStyle(Ink.primary)
            if let subtitle {
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// The dashed amber line the logo's pocket is stitched with: marks a drop target or a thing in progress.
struct StitchedBorder: ViewModifier {
    var radius: CGFloat = 18
    var color: Color = Ink.accent.opacity(0.55)

    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

extension View {
    func stitched(radius: CGFloat = 18, color: Color = Ink.accent.opacity(0.55)) -> some View {
        modifier(StitchedBorder(radius: radius, color: color))
    }
}

/// A horizontal line to be stroked dashed: the cable between the Mac and the iPhone.
struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}


// MARK: - Screens made of rows

/// A titled group of rows in one card, as the Settings screen has them. Every screen is built from these.
struct SettingsGroup<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionHeading(text: title)
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .background(Ink.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.line))
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// The square tile a row starts with: an amber symbol.
struct SymbolTile: View {
    let symbol: String
    var color: Color = Ink.accent

    var body: some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(color)
            .frame(width: 38, height: 38).background(Ink.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// One line of a group: an icon (or a game's picture), what it is, its value on one line, and its control on the right.
/// Large enough to hit, and nothing more than that on it: the long explanations go behind `HelpText`.
struct SettingRow<Trailing: View>: View {
    let icon: AnyView
    let title: String
    let detail: String
    var mono = false
    var detailColor: Color = Ink.secondary
    var detailLines = 1
    let trailing: Trailing

    init(symbol: String, tint: Color = Ink.accent, title: String, detail: String, mono: Bool = false,
         detailColor: Color = Ink.secondary, detailLines: Int = 1, @ViewBuilder trailing: () -> Trailing) {
        self.icon = AnyView(SymbolTile(symbol: symbol, color: tint))
        self.title = title
        self.detail = detail
        self.mono = mono
        self.detailColor = detailColor
        self.detailLines = detailLines
        self.trailing = trailing()
    }

    init(image: NSImage?, title: String, detail: String, mono: Bool = false, detailColor: Color = Ink.secondary,
         detailLines: Int = 1, @ViewBuilder trailing: () -> Trailing) {
        self.icon = AnyView(Thumbnail(image: image, size: 38))
        self.title = title
        self.detail = detail
        self.mono = mono
        self.detailColor = detailColor
        self.detailLines = detailLines
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5, weight: .bold)).foregroundStyle(Ink.primary).lineLimit(1)
                if !detail.isEmpty {
                    Text(Friendly.text(detail)).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                        .foregroundStyle(detailColor).lineLimit(detailLines).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: detailLines > 1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 64)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
    }
}

/// A short line under a group, or a plain note: muted, wrapped, never more than a sentence or two.
struct Note: View {
    let text: String
    var color: Color = Ink.secondary

    init(_ text: String, color: Color = Ink.secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(Friendly.text(text)).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled).padding(.horizontal, 4)
    }
}

/// An explanation kept out of the way: a quiet line that opens to the full text.
struct HelpText: View {
    let title: String
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Ink.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(text).font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// The scroll view every screen of rows sits in: a header (title, and whatever spans the page), then the groups. On a
/// wide window the groups flow into two columns, each filled in turn; on a narrow one they stack. The page never
/// stretches past a readable width: beyond it, it is centred.
struct RowsPage<Header: View, Content: View>: View {
    var maxColumns = 2
    /// The width of the column when there is only one.
    var singleWidth: CGFloat = 900
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ColumnFlow(maxColumns: maxColumns) { content }
            }
            .padding(28)
            .frame(maxWidth: maxColumns > 1 ? 1320 : singleWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// Lays its children out in up to `maxColumns` columns, each child going under the shortest column so far.
struct ColumnFlow: Layout {
    var maxColumns = 2
    var spacing: CGFloat = 24
    var minColumnWidth: CGFloat = 470

    private func count(for width: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        let n = count(for: width)
        let columnWidth = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var heights = Array(repeating: CGFloat(0), count: n)
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            heights[column] += (heights[column] > 0 ? spacing : 0) + height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = count(for: bounds.width)
        let columnWidth = (bounds.width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var heights = Array(repeating: CGFloat(0), count: n)
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let y = heights[column] + (heights[column] > 0 ? spacing : 0)
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(column) * (columnWidth + spacing), y: bounds.minY + y),
                          anchor: .topLeading, proposal: ProposedViewSize(width: columnWidth, height: size.height))
            heights[column] = y + size.height
        }
    }
}


// MARK: - A theme from a game's picture

/// The colours a game lends the screen while it is selected, taken from its picture: a glow for the background, a ring
/// for the selection and a fill for the main button. Kept soft on purpose: the picture's own colour, never a flat neon.
struct GameTheme {
    var glow: Color
    var ring: Color
    var fill: Color

    static let standard = GameTheme(glow: Ink.accent, ring: Ink.accent, fill: Ink.deep)

    init(glow: Color, ring: Color, fill: Color) {
        self.glow = glow
        self.ring = ring
        self.fill = fill
    }

    init(hue: Double, saturation: Double) {
        let s = min(max(saturation, 0.35), 0.75)
        glow = Color(hue: hue, saturation: s, brightness: 0.85)
        ring = Color(hue: hue, saturation: min(s, 0.6), brightness: 0.97)
        fill = Color(hue: hue, saturation: min(s, 0.6) * 0.9, brightness: 0.80)
    }
}

enum ArtTheme {
    private static var cache: [String: GameTheme] = [:]

    /// The theme of a picture: the hue most of its colour sits in, weighted by how vivid it is. A picture with no colour
    /// of its own (grey, black and white) keeps the standard amber. `key` names the picture, so it is read once.
    @MainActor
    static func theme(for image: NSImage?, key: String) -> GameTheme {
        if let known = cache[key] { return known }
        let result = image.flatMap(compute) ?? .standard
        cache[key] = result
        return result
    }

    private static func compute(_ image: NSImage) -> GameTheme? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
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
            let color = NSColor(srgbRed: Double(pixels[index]) / 255 / alpha, green: Double(pixels[index + 1]) / 255 / alpha,
                                blue: Double(pixels[index + 2]) / 255 / alpha, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            guard b > 0.18, s > 0.2 else { continue }
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


/// Technical values, said the way a person would read them: the home folder as "~", a place by where it is rather than
/// the whole path. The full value stays available as a tooltip where it matters.
enum Friendly {
    static func path(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// A sentence that may hold absolute paths: the home folder becomes "~", and a path of more than three parts is cut
    /// to its last two ("…/Contents/Developer"). Nothing else in the sentence changes.
    static func text(_ text: String) -> String {
        let home = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard let pattern = try? NSRegularExpression(pattern: #"(?<![\w:/.])~?/[^\s"'`),:;]+"#) else { return home }
        let range = NSRange(home.startIndex..., in: home)
        var result = ""
        var last = home.startIndex
        for match in pattern.matches(in: home, range: range) {
            guard let swiftRange = Range(match.range, in: home) else { continue }
            result += home[last..<swiftRange.lowerBound]
            let parts = home[swiftRange].split(separator: "/", omittingEmptySubsequences: true)
            result += parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : String(home[swiftRange])
            last = swiftRange.upperBound
        }
        return result + home[last...]
    }
}

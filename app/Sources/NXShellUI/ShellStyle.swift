import SwiftUI

/// The shell's palette and the small pieces every screen shares. Dark, low contrast, nothing that competes with a
/// game's own artwork.
public enum ShellInk {
    public static let background = Color(red: 0.055, green: 0.055, blue: 0.070)
    public static let surface = Color(red: 0.098, green: 0.098, blue: 0.120)
    public static let raised = Color(red: 0.145, green: 0.145, blue: 0.170)
    public static let line = Color.white.opacity(0.08)
    public static let primary = Color(red: 0.945, green: 0.925, blue: 0.890)
    public static let secondary = Color.white.opacity(0.55)
    public static let accent = Color(red: 0.937, green: 0.694, blue: 0.353)
    /// The amber for fills and buttons: deeper than `accent`, which stays for icons, numbers and hairlines, so a
    /// large amber surface never glares on the dark ground. The Mac launcher uses the same two.
    public static let deep = Color(red: 0.788, green: 0.561, blue: 0.290)
    public static let onDeep = Color(red: 0.078, green: 0.063, blue: 0.039)
    public static let tint = Color(red: 0.937, green: 0.694, blue: 0.353).opacity(0.12)
    public static let good = Color(red: 0.435, green: 0.780, blue: 0.510)
    public static let bad = Color(red: 0.925, green: 0.420, blue: 0.400)
}

/// The two faces of the design: Outfit for titles and numbers, DM Sans for buttons. Both are bundled and registered through
/// UIAppFonts; if one were missing, SwiftUI falls back to the system face.
public enum ShellFont {
    public static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom("Outfit", size: size).weight(weight)
    }

    public static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("DM Sans", size: size).weight(weight)
    }
}

public struct ShellCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ShellInk.line))
    }
}

public struct ShellSectionLabel: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text.uppercased())
            .font(ShellFont.display(11, .semibold))
            .tracking(1.1)
            .foregroundStyle(ShellInk.secondary)
    }
}

public struct ShellPill: View {
    let text: String
    var color: Color = ShellInk.secondary

    public init(_ text: String, color: Color = ShellInk.secondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

public struct ShellBar: View {
    let fraction: Double
    var tint: Color = ShellInk.deep

    public init(fraction: Double, tint: Color = ShellInk.deep) {
        self.fraction = fraction
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(tint).frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
    }
}

public struct ShellButtonStyle: ButtonStyle {
    var prominent = false
    /// The fill of a prominent button; nil is the app's deep amber. A game screen passes its own colour.
    var fill: Color?
    var radius: CGFloat
    var textColor: Color?

    public init(prominent: Bool = false, fill: Color? = nil, radius: CGFloat = 12, textColor: Color? = nil) {
        self.prominent = prominent
        self.fill = fill
        self.radius = radius
        self.textColor = textColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ShellFont.body(15, prominent ? .bold : .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: prominent ? .infinity : nil)
            .background(prominent ? (fill ?? ShellInk.deep) : ShellInk.raised,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .foregroundStyle(textColor ?? (prominent ? ShellInk.onDeep : ShellInk.primary))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

public struct ShellRow: View {
    let icon: String
    let title: String
    var detail: String?
    var accessory: String?

    public init(icon: String, title: String, detail: String? = nil, accessory: String? = nil) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.accessory = accessory
    }

    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(ShellInk.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundStyle(ShellInk.primary)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(ShellInk.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let accessory {
                Text(accessory).font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(ShellInk.secondary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// The dashed amber line the logo's pocket is stitched with: marks an empty place or a thing in progress.
public extension View {
    func shellStitched(radius: CGFloat = 20) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(ShellInk.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

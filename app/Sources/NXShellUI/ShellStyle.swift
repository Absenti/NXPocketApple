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
    public static let good = Color(red: 0.435, green: 0.780, blue: 0.510)
    public static let bad = Color(red: 0.925, green: 0.420, blue: 0.400)
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
            .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ShellInk.line))
    }
}

public struct ShellSectionLabel: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
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
    var tint: Color = ShellInk.accent

    public init(fraction: Double, tint: Color = ShellInk.accent) {
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
        .frame(height: 6)
    }
}

public struct ShellButtonStyle: ButtonStyle {
    var prominent = false

    public init(prominent: Bool = false) { self.prominent = prominent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: prominent ? .infinity : nil)
            .background(prominent ? ShellInk.accent : ShellInk.raised,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(prominent ? Color.black : ShellInk.primary)
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

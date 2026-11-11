import SwiftUI

/// A small capsule with a symbol and a word, for states such as "Draft" or
/// "Approved".
public struct Badge: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color

    public init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(Theme.Fonts.badge)
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.badgePaddingHorizontal)
        .padding(.vertical, Theme.badgePaddingVertical)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A GitHub label in its own color.
///
/// The fill is a tint of the label color and the text is the same color moved
/// toward black or white until it reads on the window background, so a navy
/// label stays legible in dark mode and a yellow one in light mode.
public struct LabelChip: View {
    private let name: String
    private let hexColor: String
    @Environment(\.colorScheme) private var colorScheme

    public init(name: String, hexColor: String) {
        self.name = name
        self.hexColor = hexColor
    }

    public var body: some View {
        let rgb = RGB(hex: hexColor) ?? RGB(red: 0.5, green: 0.5, blue: 0.5)
        let text = rgb.legible(onDark: colorScheme == .dark)
        Text(name)
            .font(Theme.Fonts.badge)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(text.color)
            .padding(.horizontal, Theme.badgePaddingHorizontal)
            .padding(.vertical, Theme.badgePaddingVertical)
            .background(rgb.color.opacity(colorScheme == .dark ? 0.22 : 0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(text.color.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel("Label \(name)")
    }
}

/// An sRGB color with components from 0 to 1.
public struct RGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses six hex digits, with or without a leading `#`.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Perceived brightness from 0 (black) to 1 (white).
    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// This color mixed toward white (on a dark background) or black (on a
    /// light one) until its brightness is far enough from the background's.
    public func legible(onDark: Bool) -> RGB {
        let target = onDark ? 0.72 : 0.38
        let needsChange = onDark ? luminance < target : luminance > target
        guard needsChange else { return self }

        let end: Double = onDark ? 1 : 0
        // Brightness is linear in the mix amount, so solve for it directly.
        let amount = (target - luminance) / (end - luminance)
        return RGB(
            red: red + (end - red) * amount,
            green: green + (end - green) * amount,
            blue: blue + (end - blue) * amount
        )
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}

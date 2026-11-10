import FrameloCore
import SwiftUI

/// Framelo's design tokens: one place for colour, type, spacing and radii.
enum Theme {
    // Colour
    static let background = Color(hex: 0x0D0D0F)
    static let panel = Color(hex: 0x151517)
    static let raised = Color(hex: 0x1D1D21)
    static let control = Color(hex: 0x26262B)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.16)
    static let text = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.56)
    static let textTertiary = Color.white.opacity(0.34)
    static let accent = Color(hex: 0x7C5CFF)
    static let danger = Color(hex: 0xFF453A)
    static let success = Color(hex: 0x30D158)
    static let zoomTint = Color(hex: 0x5E9BFF)
    static let autoZoomTint = Color(hex: 0x39C6B0)
    static let textTint = Color(hex: 0xF2A33C)

    // Spacing
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24

    // Radii
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 14

    // Type
    static let title = Font.system(size: 22, weight: .semibold)
    static let heading = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12.5)
    static let caption = Font.system(size: 11)
    static let mono = Font.system(size: 11.5, design: .monospaced)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    init(_ color: RGBAColor) {
        self.init(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a)
    }
}

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

extension Binding where Value == RGBAColor {
    /// Bridges a model colour to SwiftUI's `ColorPicker`.
    var color: Binding<Color> {
        Binding<Color>(get: { Color(wrappedValue) }, set: { wrappedValue = RGBAColor($0) })
    }
}

func formatTime(_ seconds: Double, showFraction: Bool = false) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let secs = Int(total) % 60
    if showFraction {
        return String(format: "%02d:%02d.%02d", minutes, secs, Int((total - floor(total)) * 100))
    }
    return String(format: "%02d:%02d", minutes, secs)
}

// MARK: Buttons

struct FrameloButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .primary: Theme.accent
        case .secondary: Theme.control
        case .ghost: .clear
        case .danger: Theme.danger
        }
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(kind == .ghost ? Theme.textSecondary : Theme.text)
            .padding(.horizontal, compact ? 9 : 13)
            .padding(.vertical, compact ? 5 : 7)
            .background(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous)
                .fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous)
                .strokeBorder(kind == .secondary ? Theme.border : .clear))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == FrameloButtonStyle {
    static var primary: FrameloButtonStyle { FrameloButtonStyle(kind: .primary) }
    static var secondary: FrameloButtonStyle { FrameloButtonStyle(kind: .secondary) }
    static var ghost: FrameloButtonStyle { FrameloButtonStyle(kind: .ghost) }
    static var danger: FrameloButtonStyle { FrameloButtonStyle(kind: .danger) }
    static var compact: FrameloButtonStyle { FrameloButtonStyle(kind: .secondary, compact: true) }
}

/// Square icon button with a tooltip.
struct IconButton: View {
    var symbol: String
    var help: String
    var isActive = false
    var size: CGFloat = 26
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.text.opacity(hovering ? 1 : 0.75))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous)
                    .fill(Color.white.opacity(hovering || isActive ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Panels and inputs

struct Panel<Content: View>: View {
    var padding: CGFloat = Theme.m
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Titled group inside the inspector.
struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.textTertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.s)
    }
}

/// Label, slider and value on one row.
struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var onEditingEnded: () -> Void = {}

    var body: some View {
        HStack(spacing: Theme.s) {
            Text(title).font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
            Slider(value: $value, in: range) { editing in if !editing { onEditingEnded() } }
                .controlSize(.small)
                .tint(Theme.accent)
            Text(format(value)).font(Theme.mono).foregroundStyle(Theme.text).frame(width: 44, alignment: .trailing)
        }
    }
}

struct ToggleRow: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(Theme.body).foregroundStyle(Theme.textSecondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Labelled menu picker.
struct PickerRow<Value: Hashable, Content: View>: View {
    var title: String
    @Binding var selection: Value
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Theme.s) {
            Text(title).font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
            Picker("", selection: $selection) { content }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ColorRow: View {
    var title: String
    @Binding var color: RGBAColor

    var body: some View {
        HStack(spacing: Theme.s) {
            Text(title).font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
            ColorPicker("", selection: $color.color, supportsOpacity: true).labelsHidden()
            Spacer()
        }
    }
}

/// The Framelo mark: a rounded frame with a play-shaped lens.
struct LogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8B6CFF), Color(hex: 0x5B3DF5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.95), lineWidth: size * 0.075)
                .padding(size * 0.2)
            Circle().fill(Color.white).frame(width: size * 0.17, height: size * 0.17)
        }
        .frame(width: size, height: size)
    }
}

/// Placeholder shown when a list or panel has nothing in it yet.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: Theme.s) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(title).font(Theme.heading).foregroundStyle(Theme.text)
            Text(message).font(Theme.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.xl)
    }
}

import SwiftUI

// Ahmed Marwan identity (ahmedqa.com): navy + sky blue.
enum Brand {
    static let primary = Color(hex: 0x0EA5E9)
    static let onPrimary = Color(hex: 0x06131F)
    static let ink = Color(hex: 0x0F172A)
    static func background(_ dark: Bool) -> Color { Color(hex: dark ? 0x0F172A : 0xF1F5F9) }
    static func surface(_ dark: Bool) -> Color { Color(hex: dark ? 0x162036 : 0xFFFFFF) }
    static func raised(_ dark: Bool) -> Color { Color(hex: dark ? 0x1C2A46 : 0xE2E8F0) }
    static func line(_ dark: Bool) -> Color { Color(hex: dark ? 0x2C3E5E : 0xCBD5E1) }
    static func muted(_ dark: Bool) -> Color { Color(hex: dark ? 0x94A6C1 : 0x475569) }
    static func accent(_ dark: Bool) -> Color { Color(hex: dark ? 0x38BDF8 : 0x0369A1) }
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

/// App mark: an angle (زاوية) with its arc and vertex, drawn on a 34-unit grid.
struct ZawiyaMark: View {
    var color = Brand.primary
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 34
            context.scaleBy(x: scale, y: scale)
            let style = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
            var arms = Path(); arms.move(to: CGPoint(x: 29, y: 27)); arms.addLine(to: CGPoint(x: 7, y: 27)); arms.addLine(to: CGPoint(x: 22, y: 7))
            context.stroke(arms, with: .color(color), style: style)
            var arc = Path(); arc.addArc(center: CGPoint(x: 7, y: 27), radius: 10, startAngle: .degrees(0), endAngle: .degrees(-53.13), clockwise: true)
            context.stroke(arc, with: .color(color), style: style)
            context.fill(Path(ellipseIn: CGRect(x: 4.2, y: 24.2, width: 5.6, height: 5.6)), with: .color(color))
        }
        .accessibilityLabel("أداة زاوية / Zawiya Tools")
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonSurface(configuration: configuration)
    }
}

private struct MotionEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var zawiyaMotion: Bool { get { self[MotionEnabledKey.self] } set { self[MotionEnabledKey.self] = newValue } }
}
enum BrandMotion {
    static func animation(_ enabled: Bool) -> Animation? { enabled ? .spring(response: 0.26, dampingFraction: 0.9) : nil }
    static func transition(_ enabled: Bool) -> AnyTransition { enabled ? .opacity.combined(with: .offset(y: 6)) : .identity }
}
private struct PrimaryButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.zawiyaMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var animated: Bool { motion && !reduceMotion }
    var body: some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.onPrimary.opacity(enabled ? 1 : 0.55))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Brand.primary.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.onPrimary.opacity(hovering && enabled ? 0.18 : 0), lineWidth: 1))
            .scaleEffect(animated && configuration.isPressed && enabled ? 0.98 : 1)
            .onHover { hovering = $0 }
            .animation(BrandMotion.animation(animated), value: configuration.isPressed)
            .animation(.easeOut(duration: animated ? 0.12 : 0), value: hovering)
    }
}

struct SelectionMenu<Content: View>: View {
    let label: String
    let value: String
    let symbol: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Brand.muted(scheme == .dark))
            Menu { content } label: { Label(value, systemImage: symbol).lineLimit(2) }
                .menuStyle(.button).buttonStyle(SelectionButtonStyle()).menuIndicator(.hidden)
                .accessibilityLabel(label).accessibilityValue(value)
        }
    }
}

private struct SelectionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label.font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.muted(scheme == .dark))
        }.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(12).contentShape(RoundedRectangle(cornerRadius: 10))
            .background(Brand.raised(scheme == .dark).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line(scheme == .dark), lineWidth: 1))
    }
}

struct Panel<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Brand.surface(scheme == .dark), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Brand.line(scheme == .dark), lineWidth: 1))
    }
}

import SwiftUI

// MARK: - Design Tokens
enum DS {
    enum Corner {
        static let button: CGFloat = 10
        static let small: CGFloat = 8
        static let pill: CGFloat = 14
        static let panel: CGFloat = 14
    }

    enum Spacing {
        static let panelPadding: CGFloat = 16
        static let panelMargin: CGFloat = 12
        static let toolbar: CGFloat = 14
        static let sectionGap: CGFloat = 8
    }

    enum Panel {
        static let width: CGFloat = 270
        static let mapControlSize: CGFloat = 38
    }

    enum FontSize {
        static let micro: CGFloat = 10
        static let small: CGFloat = 11
        static let body: CGFloat = 12
        static let bodyMedium: CGFloat = 13
        static let heading: CGFloat = 16
        static let title: CGFloat = 18
    }

    enum Shadow {
        static let panel: CGFloat = 10
        static let float: CGFloat = 14
        static let prominent: CGFloat = 20
    }
}

// MARK: - Glass Button Style
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = .blue
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isProminent ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Group {
                    if isProminent {
                        tint
                    } else {
                        tint.opacity(0.15)
                    }
                }
                .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.button, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static func glass(tint: Color = .blue, prominent: Bool = false) -> GlassButtonStyle {
        GlassButtonStyle(tint: tint, isProminent: prominent)
    }
}

// MARK: - Icon Button Style
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(width: size, height: size)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.small, style: .continuous))
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static func iconButton(size: CGFloat = 36) -> IconButtonStyle {
        IconButtonStyle(size: size)
    }
}

// MARK: - Coordinate Formatter
extension Double {
    var coordinateString: String {
        String(format: "%.6f", self)
    }
}

// MARK: - Status Indicator
struct StatusDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.5), radius: 3)
    }
}

// MARK: - Shadow Modifier
struct PanelShadow: ViewModifier {
    var radius: CGFloat = DS.Shadow.panel
    var opacity: Double = 0.15

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(opacity), radius: radius, x: 0, y: radius * 0.4)
    }
}

extension View {
    func panelShadow(radius: CGFloat = DS.Shadow.panel, opacity: Double = 0.15) -> some View {
        modifier(PanelShadow(radius: radius, opacity: opacity))
    }
}

// MARK: - Convenience Colors
extension Color {
    static let dsAccent = Color(red: 0, green: 0.478, blue: 1)
    static let dsSuccess = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let dsError = Color(red: 1, green: 0.231, blue: 0.227)
    static let dsWarning = Color(red: 1, green: 0.624, blue: 0.039)
}

import SwiftUI

// MARK: - Dockwright Color Palette

enum DockwrightTheme {

    // MARK: - Semantic Color Tokens

    static let primary = Color(hex: 0x0891B2)      // teal-600 — matches app icon
    static let secondary = Color(hex: 0x0E7490)     // teal-700
    static let accent = Color(hex: 0x10B981)         // emerald

    // State Colors
    static let success = Color(hex: 0x10B981)
    static let error = Color(hex: 0xEF4444)
    static let caution = Color(hex: 0xF59E0B)
    static let info = Color(hex: 0x0891B2)
    static let warmth = Color(hex: 0xEC4899)
    static let communication = Color(hex: 0x06B6D4)

    // MARK: - Gradients

    static let brandGradient = LinearGradient(
        colors: [Color(nsColor: .dynamic(light: 0xF0F0F0, dark: 0x2A2A2A)), Color(nsColor: .dynamic(light: 0xE8E8E8, dark: 0x1E1E1E))],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accentGradient = LinearGradient(
        colors: [accent, Color(hex: 0x059669)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let orbGradient = LinearGradient(
        colors: [Color(hex: 0x0694A2), Color(hex: 0x0C4A6E)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Chat Bubble

    static let userBubbleGradient = LinearGradient(
        colors: [Color(nsColor: .dynamic(light: 0xE8E8E8, dark: 0x303030)), Color(nsColor: .dynamic(light: 0xE0E0E0, dark: 0x2A2A2A))],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let assistantAvatarGradient = LinearGradient(
        colors: [Color(hex: 0x0891B2), Color(hex: 0x0E7490)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Surface Colors

    static let glassBackground = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x212121))
    static let inputBackground = Color(nsColor: .dynamic(light: 0xF8F8F8, dark: 0x1E1E1E))

    static let sendButtonActive = LinearGradient(
        colors: [Color.white, Color(hex: 0xE5E5E5)],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Design System Scales

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let section: CGFloat = 14
    }

    enum Typography {
        static let displayLarge = Font.system(size: 24, weight: .semibold)
        static let displayMedium = Font.system(size: 20, weight: .semibold)
        static let headingLarge = Font.system(size: 18, weight: .semibold)
        static let heading = Font.system(size: 15, weight: .semibold)
        static let headingSmall = Font.system(size: 13, weight: .semibold)
        static let title = Font.system(size: 16)
        static let titleMedium = Font.system(size: 16, weight: .medium)
        static let bodyLarge = Font.system(size: 14)
        static let bodyLargeMedium = Font.system(size: 14, weight: .medium)
        static let bodyLargeSemibold = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let bodySemibold = Font.system(size: 13, weight: .semibold)
        static let label = Font.system(size: 12, weight: .medium)
        static let labelSemibold = Font.system(size: 12, weight: .semibold)
        static let caption = Font.system(size: 11)
        static let captionMedium = Font.system(size: 11, weight: .medium)
        static let captionMono = Font.system(size: 11, design: .monospaced)
        static let micro = Font.system(size: 10)
        static let microMedium = Font.system(size: 10, weight: .medium)
        static let microMono = Font.system(size: 10, design: .monospaced)
        static let code = Font.system(size: 12, design: .monospaced)
        static let codeSmall = Font.system(size: 11, design: .monospaced)
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let card: CGFloat = 14
        static let bubble: CGFloat = 16
    }

    enum Surface {
        static let canvas = Color(nsColor: .dynamic(light: 0xF5F5F5, dark: 0x171717))
        static let card = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x212121))
        static let elevated = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x262626))
        static let sidebar = Color(nsColor: .dynamic(light: 0xF0F0F0, dark: 0x1C1C1C))
        static let hover = Color(nsColor: .dynamic(lightAlpha: (0x000000, 0.04), darkAlpha: (0xFFFFFF, 0.06)))
        static let active = Color(nsColor: .dynamic(lightAlpha: (0x000000, 0.08), darkAlpha: (0xFFFFFF, 0.10)))
    }

    enum Opacity {
        static let borderSubtle: Double = 0.08
        static let borderMedium: Double = 0.12
        static let borderFocused: Double = 0.28
        static let tintSubtle: Double = 0.06
        static let tintMedium: Double = 0.10
        static let tintStrong: Double = 0.15
        static let divider: Double = 0.15
        static let shadow: Double = 0.08
        static let badge: Double = 0.12
    }

    enum Layout {
        static let sidebarWidth: CGFloat = 220
        static let maxBubbleWidth: CGFloat = 640
        static let avatarSize: CGFloat = 28
        static let inputButtonSize: CGFloat = 30
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Adaptive NSColor (Light/Dark)

extension NSColor {
    /// Create an adaptive color from light and dark hex values.
    static func dynamic(light: UInt, dark: UInt) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
    }

    /// Create an adaptive color from light and dark hex+alpha pairs.
    static func dynamic(lightAlpha: (UInt, Double), darkAlpha: (UInt, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? darkAlpha.0 : lightAlpha.0
            let alpha = isDark ? darkAlpha.1 : lightAlpha.1
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: CGFloat(alpha)
            )
        }
    }
}

// MARK: - Glass Card Modifier

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(DockwrightTheme.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(DockwrightTheme.Opacity.borderSubtle), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(DockwrightTheme.Opacity.shadow), radius: 16, y: 6)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Hover Card Modifier

struct HoverCardModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DockwrightTheme.Radius.md)
                    .fill(isHovered ? DockwrightTheme.Surface.hover : Color.clear)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in isHovered = hovering }
    }
}

extension View {
    func hoverCard() -> some View {
        modifier(HoverCardModifier())
    }
}

// MARK: - Glow Effect

struct GlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.3), radius: radius / 2, x: 0, y: 0)
            .shadow(color: color.opacity(0.15), radius: radius, x: 0, y: 0)
    }
}

extension View {
    func glow(_ color: Color, radius: CGFloat = 8) -> some View {
        modifier(GlowModifier(color: color, radius: radius))
    }

    func shimmer(isActive: Bool, color: Color = .white) -> some View {
        modifier(ShimmerModifier(isActive: isActive, color: color))
    }
}

// MARK: - Shimmer Effect

struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    let color: Color
    @State private var offset: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay(Group {
                if isActive {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [.clear, color.opacity(0.1), color.opacity(0.15), color.opacity(0.1), .clear],
                                startPoint: UnitPoint(x: offset - 0.3, y: 0.5),
                                endPoint: UnitPoint(x: offset + 0.3, y: 0.5)
                            )
                        )
                        .clipped()
                        .onAppear {
                            offset = -1.0
                            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                                offset = 2.0
                            }
                        }
                }
            }.allowsHitTesting(false))
    }
}

// MARK: - Press Button Style

struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailRadius: CGFloat = 4
        var path = Path()

        if isUser {
            path.addRoundedRect(in: rect, cornerRadii: .init(
                topLeading: radius,
                bottomLeading: radius,
                bottomTrailing: tailRadius,
                topTrailing: radius
            ))
        } else {
            path.addRoundedRect(in: rect, cornerRadii: .init(
                topLeading: tailRadius,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: radius
            ))
        }

        return path
    }
}

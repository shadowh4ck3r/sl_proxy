import SwiftUI

/// SL_Proxy brand palette: glassy gold and orange.
enum Brand {
    static let gold = Color("BrandGold")
    static let orange = Color("BrandOrange")

    static let gradient = LinearGradient(
        colors: [gold, orange],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Ambient gold/orange glow used behind every screen.
    static var background: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [gold.opacity(0.35), .clear],
                center: .topLeading, startRadius: 0, endRadius: 420
            )
            RadialGradient(
                colors: [orange.opacity(0.30), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

/// Frosted glass card with a subtle gold-to-orange edge highlight.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 22
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Brand.gradient, lineWidth: 1)
                    .opacity(0.6)
            )
            .shadow(color: Brand.orange.opacity(0.15), radius: 18, y: 8)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 22, padding: CGFloat = 20) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding))
    }
}

/// Applies the App Font chosen in Appearance Settings (System / Mono / Sketch) to a view tree.
/// Attached once at the app root so every screen follows the selected typography.
struct AppFontModifier: ViewModifier {
    let style: AppFontStyle

    func body(content: Content) -> some View {
        // `.fontDesign` needs iOS 16.1; `.font(.system(.body, design:))` is available on the
        // iOS 16.0 deployment target and propagates the design to the whole view tree.
        content.font(.system(.body, design: style.design))
    }
}

extension View {
    /// Apply the app-wide font design (Appearance Settings > App Font).
    func appFont(_ style: AppFontStyle) -> some View {
        modifier(AppFontModifier(style: style))
    }
}

/// Card wrapper that follows the Navigation Style chosen in Appearance Settings: `Katzy` renders the
/// frosted `GlassCard` (glassmorphism), `Erosion` a flat tinted surface with a solid brand edge.
struct NavigationStyleCard: ViewModifier {
    let style: NavigationStyle
    var cornerRadius: CGFloat = 22
    var padding: CGFloat = 20

    @ViewBuilder
    func body(content: Content) -> some View {
        if style.usesGlassmorphism {
            content.glassCard(cornerRadius: cornerRadius, padding: padding)
        } else {
            content
                .padding(padding)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Brand.orange.opacity(0.35), lineWidth: 1)
                )
        }
    }
}

extension View {
    func navigationStyleCard(_ style: NavigationStyle, cornerRadius: CGFloat = 22, padding: CGFloat = 20) -> some View {
        modifier(NavigationStyleCard(style: style, cornerRadius: cornerRadius, padding: padding))
    }
}

/// Primary call-to-action style (e.g. the Connect button).
struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Brand.gradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .shadow(
                color: Brand.orange.opacity(configuration.isPressed ? 0.15 : 0.45),
                radius: 16, y: 8
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

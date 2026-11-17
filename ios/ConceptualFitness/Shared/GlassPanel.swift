import SwiftUI

struct AppBackground: View {
    var body: some View {
        HealthTheme.page.ignoresSafeArea()
    }
}

struct ScenePanelSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.panelSurface(cornerRadius: cornerRadius)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.strokeBorder(edge, lineWidth: 1) }
                .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var edge: Color {
        if contrast == .increased { return HealthTheme.ink.opacity(0.5) }
        return .white.opacity(colorScheme == .dark ? 0.14 : 0.55)
    }
}

extension View {
    func panelSurface(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(HealthTheme.card, in: shape)
            .overlay { shape.strokeBorder(HealthTheme.hairline, lineWidth: 1) }
    }

    func scenePanelSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(ScenePanelSurface(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func glassControlSurface(cornerRadius: CGFloat = 22) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.scenePanelSurface(cornerRadius: cornerRadius)
        }
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressScaleButtonStyle {
    static var pressScale: PressScaleButtonStyle { PressScaleButtonStyle() }
}

struct PrimaryActionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.body, design: .rounded, weight: .bold))
            .foregroundStyle(HealthTheme.inverseInk)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(HealthTheme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

import SwiftUI

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.98, blue: 1.0),
                Color(red: 0.98, green: 0.98, blue: 0.95),
                Color.white
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

extension View {
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
        }
    }
}

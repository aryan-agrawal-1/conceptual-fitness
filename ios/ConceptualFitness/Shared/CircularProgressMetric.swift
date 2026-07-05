import SwiftUI

struct CircularProgressMetric<Center: View>: View {
    let progress: Double
    let tint: Color
    var trackColor: Color = .white.opacity(0.55)
    var overflowTint: Color?
    var lineWidth: CGFloat = 11
    var overflowLineWidth: CGFloat = 6
    let accessibilityLabel: String
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let overflowTint, progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 0.35))
                    .stroke(overflowTint, style: StrokeStyle(lineWidth: overflowLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

import SwiftUI

struct CircularProgressMetric<Center: View>: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 11
    let accessibilityLabel: String
    @ViewBuilder let center: Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            ProgressRing(progress: shown, tint: tint, lineWidth: lineWidth)
            center
        }
        .accessibilityLabel(accessibilityLabel)
        .onAppear { sweep(to: progress) }
        .onChange(of: progress) { _, value in sweep(to: value) }
    }

    private func sweep(to value: Double) {
        guard shown != value else { return }
        if reduceMotion {
            shown = value
        } else {
            withAnimation(.smooth(duration: 0.6)) { shown = value }
        }
    }
}

private struct ProgressRing: View, Animatable {
    var progress: Double
    let tint: Color
    let lineWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var firstLap: Double { min(max(progress, 0), 1) }
    private var secondLap: Double { min(max(progress - 1, 0), 0.97) }
    private var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round) }

    private func shadowLead(radius: CGFloat) -> Double {
        Double(lineWidth * 0.35 / max(radius, 1)) * 180 / .pi
    }

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: firstLap)
                    .stroke(tint, style: stroke)
                    .rotationEffect(.degrees(-90))
                if secondLap > 0 {
                    Circle()
                        .fill(.black.opacity(0.32))
                        .frame(width: lineWidth, height: lineWidth)
                        .offset(y: -radius)
                        .frame(width: radius * 2, height: radius * 2)
                        .rotationEffect(.degrees(secondLap * 360 + shadowLead(radius: radius)))
                        .blur(radius: lineWidth * 0.3)
                        .mask(Circle().stroke(lineWidth: lineWidth))
                    Circle()
                        .trim(from: 0, to: secondLap)
                        .stroke(tint, style: stroke)
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

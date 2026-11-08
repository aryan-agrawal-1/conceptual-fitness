import SwiftUI

extension PatternGroup {
    var skyColors: [Color] {
        switch self {
        case .sleep:
            [Color(red: 0.04, green: 0.06, blue: 0.18), Color(red: 0.10, green: 0.14, blue: 0.36),
             Color(red: 0.30, green: 0.36, blue: 0.66)]
        case .recovery:
            [Color(red: 0.02, green: 0.13, blue: 0.15), Color(red: 0.04, green: 0.29, blue: 0.31),
             Color(red: 0.18, green: 0.54, blue: 0.53)]
        case .feel:
            [Color(red: 0.22, green: 0.10, blue: 0.29), Color(red: 0.60, green: 0.26, blue: 0.33),
             Color(red: 0.96, green: 0.62, blue: 0.40)]
        }
    }

    var ink: Color { skyColors[1] }
}

struct PatternsHero: View {
    let run: PatternRun?
    let board: PatternBoard?
    @Binding var group: PatternGroup
    let unseenGroups: Set<PatternGroup>
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let run {
                Text("\(PatternDates.updated(run.completedAt)) · confidence reviewed on day \(run.nextCheckpointDay)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .fadesNearTop(from: 122, to: 96)
            }
            Text(board == nil ? "Patterns" : group.title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .fadesNearTop(from: 122, to: 96)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .fadesNearTop(from: 122, to: 96)
            }
            if board != nil {
                PatternGroupPicker(selection: $group, unseen: unseenGroups)
                    .padding(.top, 10)
                    .fadesNearTop(from: 122, to: 96)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .padding(.bottom, PatternsSky.bottomFade - 16)
        .background { PatternsSky(group: group).padding(.horizontal, -16) }
        .accessibilityIdentifier("patterns.hero")
    }

}

struct PatternsSky: View {
    let group: PatternGroup
    static let overscroll: CGFloat = 600
    static let bottomFade: CGFloat = 72

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let total = height + Self.overscroll
            ZStack {
                LinearGradient(stops: [
                    .init(color: group.skyColors[0], location: 0),
                    .init(color: group.skyColors[0], location: Self.overscroll / total),
                    .init(color: group.skyColors[1], location: (Self.overscroll + height * 0.55) / total),
                    .init(color: group.skyColors[2], location: 1)
                ], startPoint: .top, endPoint: .bottom)
                PatternsSkyArt(group: group)
                    .frame(height: height + PatternsSkyArt.headroom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: total)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1 - Self.bottomFade / total),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .offset(y: -Self.overscroll)
            .animation(.easeInOut(duration: 0.45), value: group)
        }
        .accessibilityHidden(true)
    }
}

struct PatternGroupPicker: View {
    @Binding var selection: PatternGroup
    let unseen: Set<PatternGroup>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PatternGroup.allCases) { group in
                let selected = group == selection
                Button {
                    selection = group
                } label: {
                    HStack(spacing: 5) {
                        Text(group.title).lineLimit(1).minimumScaleFactor(0.8)
                        if unseen.contains(group) {
                            Circle().fill(selected ? group.ink : .white).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? group.ink : .white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(unseen.contains(group) ? "New pattern" : "")
                .accessibilityIdentifier("patterns.group.\(group.rawValue)")
            }
        }
        .animation(.snappy, value: selection)
    }
}

struct PatternsSkyArt: View {
    let group: PatternGroup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let headroom: CGFloat = 120

    private func anchor(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width - 64, y: Self.headroom - 34)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 12.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                switch group {
                case .sleep: drawNight(time: time, in: &context, size: size)
                case .recovery: drawSea(time: time, in: &context, size: size)
                case .feel: drawSunrise(time: time, in: &context, size: size)
                }
            }
        }
        .id(group)
        .transition(.opacity)
    }

    private func noise(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }

    private func dot(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func glow(_ center: CGPoint, radius: CGFloat, color: Color, strength: Double,
                      in context: inout GraphicsContext) {
        context.fill(dot(center, radius), with: .radialGradient(
            Gradient(colors: [color.opacity(strength), color.opacity(0)]),
            center: center, startRadius: 0, endRadius: radius))
    }

    private func drawNight(time: Double, in context: inout GraphicsContext, size: CGSize) {
        for index in 0..<80 {
            let center = CGPoint(x: noise(index, 1) * size.width, y: noise(index, 2) * size.height * 0.9)
            let twinkle = 0.5 + 0.5 * sin(time * (0.6 + noise(index, 4) * 1.6) + noise(index, 5) * 6.28)
            let radius = 0.5 + noise(index, 3) * 1.3
            context.fill(dot(center, radius), with: .color(.white.opacity(0.2 + 0.7 * twinkle * noise(index, 6))))
        }
        let moon = anchor(size)
        glow(moon, radius: 90, color: Color(red: 0.75, green: 0.8, blue: 1), strength: 0.28, in: &context)
        context.drawLayer { layer in
            layer.fill(dot(moon, 20), with: .color(Color(red: 0.98, green: 0.97, blue: 0.9)))
            layer.blendMode = .destinationOut
            layer.fill(dot(CGPoint(x: moon.x + 9, y: moon.y - 7), 18), with: .color(.black))
        }
    }

    private func drawSea(time: Double, in context: inout GraphicsContext, size: CGSize) {
        let foam = Color(red: 0.62, green: 0.96, blue: 0.88)
        let glow = CGPoint(x: size.width * 0.5, y: size.height - 110)
        context.fill(dot(glow, size.width * 0.7), with: .radialGradient(
            Gradient(colors: [foam.opacity(0.16), foam.opacity(0)]),
            center: glow, startRadius: 0, endRadius: size.width * 0.7))
        let layers: [(base: CGFloat, height: CGFloat, length: Double, speed: Double, opacity: Double)] = [
            (132, 6, 240, 0.25, 0.10), (104, 8, 200, -0.33, 0.14), (78, 9, 170, 0.42, 0.18), (52, 10, 140, -0.5, 0.24)
        ]
        for (index, layer) in layers.enumerated() {
            let base = size.height - layer.base
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for step in stride(from: 0.0, through: Double(size.width), by: 4) {
                let phase = step / layer.length * .pi * 2 + time * layer.speed + Double(index)
                let swell = sin(phase) + 0.35 * sin(phase * 2.3 + time * 0.2)
                path.addLine(to: CGPoint(x: step, y: base - swell * layer.height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(foam.opacity(layer.opacity)))
        }
        for index in 0..<14 {
            let x = noise(index, 11) * Double(size.width)
            let shimmer = 0.5 + 0.5 * sin(time * (0.8 + noise(index, 12)) + noise(index, 13) * 6.28)
            let center = CGPoint(x: x, y: size.height - 80 - noise(index, 14) * 50)
            context.fill(dot(center, 1.2), with: .color(.white.opacity(0.35 * shimmer)))
        }
    }

    private func drawSunrise(time: Double, in context: inout GraphicsContext, size: CGSize) {
        let gold = Color(red: 1, green: 0.85, blue: 0.55)
        for index in 0..<18 {
            let drift = (time * (4 + noise(index, 7) * 6) + noise(index, 8) * Double(size.height))
                .truncatingRemainder(dividingBy: Double(size.height))
            let center = CGPoint(x: noise(index, 9) * size.width, y: size.height - drift)
            context.fill(dot(center, 1 + noise(index, 10) * 1.5), with: .color(gold.opacity(0.35)))
        }
    }
}


import SwiftUI

enum JournalFirePalette {
    static let ember = Color(red: 0.56, green: 0.08, blue: 0.02)
    static let glow = Color(red: 0.93, green: 0.29, blue: 0.04)
    static let top = Color(red: 0.79, green: 0.16, blue: 0.03)
    static let bottom = Color(red: 0.87, green: 0.23, blue: 0.03)
    static let deep = Color(red: 0.74, green: 0.15, blue: 0.03)
    static let flame = Color(red: 0.96, green: 0.34, blue: 0.04)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.0)
    static let amber = Color(red: 1.0, green: 0.73, blue: 0.0)
    static let gold = Color(red: 1.0, green: 0.89, blue: 0.36)
}

struct JournalFireBackground: View {
    var lean: Double = 0.25
    var reach: Double = 1
    var rises = false
    var base = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    private struct Layer {
        let height: Double
        let spacing: Double
        let color: Color
        let speed: Double
        let seed: Double
    }

    private static let restingTime = 41.7
    private static let layers = [
        Layer(height: 1.0, spacing: 34, color: JournalFirePalette.flame, speed: 3.1, seed: 0.4),
        Layer(height: 0.72, spacing: 29, color: JournalFirePalette.orange, speed: 3.9, seed: 2.3),
        Layer(height: 0.46, spacing: 25, color: JournalFirePalette.amber, speed: 4.7, seed: 4.1),
        Layer(height: 0.24, spacing: 21, color: JournalFirePalette.gold, speed: 5.5, seed: 5.9)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? Self.restingTime
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                for layer in Self.layers { draw(layer, time: time, in: &context, size: size) }
                drawEmbers(time: time, in: &context, size: size)
            }
            .scaleEffect(x: 1, y: rises && !risen ? 0.05 : 1, anchor: .bottom)
        }
        .background {
            if base {
                LinearGradient(colors: [JournalFirePalette.top, JournalFirePalette.bottom],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard rises, !reduceMotion else {
                risen = true
                return
            }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.75)) { risen = true }
        }
    }

    private func draw(_ layer: Layer, time: Double, in context: inout GraphicsContext, size: CGSize) {
        let spacing = layer.spacing * max(1, size.height * reach / 225)
        let count = Int(size.width / spacing) + 2
        for index in 0..<count {
            let phase = Double(index) * 2.399 + layer.seed
            let center = Double(index) * spacing + sin(phase * 3.1) * spacing * 0.2
            let position = center / max(size.width, 1)
            let flicker = 0.78 + 0.16 * sin(time * layer.speed + phase) + 0.06 * sin(time * layer.speed * 2.3 + phase * 1.7)
            let variety = 0.75 + 0.25 * abs(sin(phase * 1.3))
            let height = size.height * reach * layer.height * envelope(position) * flicker * variety
            let width = spacing * 1.7
            let sway = sin(time * layer.speed * 0.8 + phase) * width * 0.22
            context.fill(tongue(center: center, width: width, height: height, sway: sway, floor: size.height),
                         with: .color(layer.color))
        }
    }

    private func tongue(center: Double, width: Double, height: Double, sway: Double, floor: Double) -> Path {
        let tip = CGPoint(x: center + sway, y: floor - height)
        var path = Path()
        path.move(to: CGPoint(x: center - width / 2, y: floor))
        path.addCurve(to: tip,
                      control1: CGPoint(x: center - width * 0.62, y: floor - height * 0.42),
                      control2: CGPoint(x: center - width * 0.06 + sway * 0.4, y: floor - height * 0.62))
        path.addCurve(to: CGPoint(x: center + width / 2, y: floor),
                      control1: CGPoint(x: center + width * 0.14 + sway * 0.4, y: floor - height * 0.6),
                      control2: CGPoint(x: center + width * 0.62, y: floor - height * 0.38))
        path.closeSubpath()
        return path
    }

    private func envelope(_ position: Double) -> Double {
        lean + (1 - lean) * pow(min(max(position, 0), 1), 1.5)
    }

    private func drawEmbers(time: Double, in context: inout GraphicsContext, size: CGSize) {
        for ember in 0..<10 {
            let seed = Double(ember) * 0.618
            let climb = (time * (0.2 + 0.06 * sin(seed * 9)) + seed).truncatingRemainder(dividingBy: 1)
            let across = (seed * 3.7).truncatingRemainder(dividingBy: 1)
            let radius = 1 + (seed * 5).truncatingRemainder(dividingBy: 1.2)
            let start = 1 - lean * 0.5 - 0.3 * (1 - lean)
            let center = CGPoint(x: size.width * (start * (1 - lean) + (1 - start * (1 - lean)) * across) + sin(time * 1.6 + seed * 6) * 6,
                                 y: size.height * (1 - climb * reach))
            let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(JournalFirePalette.gold.opacity((1 - climb) * 0.95)))
        }
    }
}

struct JournalStreakHero<Calendar: View>: View {
    let summary: JournalStreakSummary
    let settled: Bool
    let open: (String) -> Void
    @ViewBuilder let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var countSize: CGFloat = 42

    private static var overscroll: CGFloat { 600 }
    private static var calendarFade: CGFloat { 84 }
    private var lit: Bool { summary.count > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Insights")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, -44)
                details
                if let action = summary.action { actionButton(action) }
            }
            .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            calendar.padding(.top, 2)
        }
        .padding(.bottom, lit ? 38 : 10)
        .environment(\.colorScheme, .light)
        .background {
            if lit { fire.padding(.horizontal, -16) }
        }
        .accessibilityIdentifier("journal.streak.hero")
    }

    private var fire: some View {
        GeometryReader { proxy in
            let total = proxy.size.height + Self.overscroll
            JournalFireBackground(lean: 0.4, reach: 1, base: false)
                .frame(height: proxy.size.height)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .frame(height: total)
                .background(LinearGradient(stops: [
                    .init(color: JournalFirePalette.ember, location: Self.overscroll / total),
                    .init(color: JournalFirePalette.top, location: (Self.overscroll + proxy.size.height * 0.5) / total),
                    .init(color: JournalFirePalette.glow, location: 1)
                ], startPoint: .top, endPoint: .bottom))
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 1 - Self.calendarFade / total),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .offset(y: -Self.overscroll)
        }
        .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: countSize * 0.62))
                    .foregroundStyle(lit ? AnyShapeStyle(JournalFirePalette.gold) : AnyShapeStyle(.tertiary))
                Text("\(summary.count)")
                    .font(.system(size: countSize, weight: .heavy, design: .rounded))
                Text("day streak").font(.title3.weight(.bold))
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                    progress
                }
            }
            Text(summary.message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .opacity(settled ? 1 : 0)
                .accessibilityHidden(!settled)
            if typeSize.isAccessibilitySize { progress }
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(0..<JournalDailyList.dailyTarget, id: \.self) { dot in
                    Circle()
                        .fill(dot < summary.answeredToday ? AnyShapeStyle(dotColor) : AnyShapeStyle(dotColor.opacity(0.3)))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
            Text("\(summary.answeredToday) of \(JournalDailyList.dailyTarget) today")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }

    private var dotColor: Color { lit ? .white : HealthTheme.color(for: .activity) }

    private func actionButton(_ action: JournalStreakSummary.Action) -> some View {
        Button { open(action.day) } label: {
            HStack(spacing: 8) {
                Text(action.title).font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let progress = action.progress {
                    Text(progress).font(.footnote.weight(.semibold)).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).accessibilityHidden(true)
            }
            .foregroundStyle(lit ? JournalFirePalette.deep : .white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(lit ? .white : HealthTheme.color(for: .activity),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("journal.streak.action")
    }
}

struct JournalStreakMark: View {
    let celebration: JournalStreakCelebration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var flameSize: CGFloat = 104
    @ScaledMetric(relativeTo: .largeTitle) private var countSize: CGFloat = 76
    @State private var shown = false
    @State private var value: Int?

    private var displayed: Int { value ?? celebration.from }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: flameSize))
                .foregroundStyle(LinearGradient(colors: [JournalFirePalette.gold, .white],
                                                startPoint: .bottom, endPoint: .top))
                .symbolEffect(.bounce, value: displayed)
                .scaleEffect(shown ? 1 : 0.3)
                .opacity(shown ? 1 : 0)
            Text("\(displayed)")
                .font(.system(size: countSize, weight: .heavy, design: .rounded))
                .contentTransition(.numericText(value: Double(displayed)))
            Text("day streak").font(.title2.weight(.bold))
            Text("Check-in complete").font(.subheadline.weight(.semibold)).padding(.top, 4)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(celebration.to) day streak. Check-in complete.")
        .accessibilityAddTraits(.isHeader)
        .task {
            guard !reduceMotion else {
                shown = true
                value = celebration.to
                return
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.58)) { shown = true }
            do { try await Task.sleep(for: .seconds(0.55)) } catch { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { value = celebration.to }
        }
    }
}

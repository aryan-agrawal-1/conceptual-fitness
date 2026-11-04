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
    static let ash = Color(red: 0.25, green: 0.07, blue: 0.04)
    static let coal = Color(red: 0.36, green: 0.09, blue: 0.04)
    static let smoulder = Color(red: 0.62, green: 0.14, blue: 0.03)
    static let char = Color(red: 0.08, green: 0.05, blue: 0.04)
    static let wood = Color(red: 0.71, green: 0.51, blue: 0.32)
    static let woodSide = Color(red: 0.40, green: 0.25, blue: 0.14)
    static let endGrain = Color(red: 0.56, green: 0.38, blue: 0.22)
    static let cinder = Color(red: 0.63, green: 0.60, blue: 0.57)
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
            context.fill(Self.tongue(center: center, width: width, height: height, sway: sway, floor: size.height),
                         with: .color(layer.color))
        }
    }

    static func tongue(center: Double, width: Double, height: Double, sway: Double, floor: Double) -> Path {
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

struct JournalKindling: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Plank {
        let outer: CGPoint
        let inner: CGPoint
        let width: Double
        let depth: Double
        let char: Double

        init(_ outerX: Double, _ outerY: Double, _ innerX: Double, _ innerY: Double,
             width: Double, depth: Double, char: Double) {
            outer = CGPoint(x: outerX, y: outerY)
            inner = CGPoint(x: innerX, y: innerY)
            self.width = width
            self.depth = depth
            self.char = char
        }
    }

    static let spill: CGFloat = 60
    private static let restingTime = 41.7
    private static let backPlanks = [
        Plank(-66, -46, 26, -56, width: 9, depth: 5, char: 0.3),
        Plank(78, -30, -14, -48, width: 10, depth: 6, char: 0.35),
        Plank(-80, -22, 6, -34, width: 9, depth: 6, char: 0.4)
    ]
    private static let frontPlanks = [
        Plank(98, 2, 20, -42, width: 13, depth: 8, char: 0.2),
        Plank(-60, 12, 6, -28, width: 11, depth: 7, char: 0.55),
        Plank(-98, -4, 44, -64, width: 14, depth: 8, char: 0.12),
        Plank(18, 16, 2, -52, width: 13, depth: 8, char: 0.25),
        Plank(-30, 16, 10, 2, width: 10, depth: 7, char: 0.6)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? Self.restingTime
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { context, size in
                let heat = 0.82 + 0.12 * sin(time * 1.7) + 0.06 * sin(time * 4.3)
                let hearth = CGPoint(x: size.width / 2, y: size.height - Self.spill - 8)
                drawGlow(heat: heat, hearth: hearth, in: &context)
                drawAsh(heat: heat, hearth: hearth, in: &context)
                for plank in Self.backPlanks { draw(plank, heat: heat, hearth: hearth, in: context) }
                drawHeart(time: time, heat: heat, hearth: hearth, in: &context)
                for plank in Self.frontPlanks { draw(plank, heat: heat, hearth: hearth, in: context) }
                drawSparks(time: time, hearth: hearth, in: &context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawGlow(heat: Double, hearth: CGPoint, in context: inout GraphicsContext) {
        var glow = context
        glow.translateBy(x: hearth.x, y: hearth.y - 14)
        glow.scaleBy(x: 1, y: 0.42)
        let radius = 200.0
        glow.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                  with: .radialGradient(
                    Gradient(colors: [JournalFirePalette.orange.opacity(0.5 * heat), JournalFirePalette.flame.opacity(0)]),
                    center: .zero, startRadius: 0, endRadius: radius))
    }

    private func drawAsh(heat: Double, hearth: CGPoint, in context: inout GraphicsContext) {
        for piece in 0..<18 {
            let seed = Double(piece) * 0.618
            let across = (seed * 3.7).truncatingRemainder(dividingBy: 1) - 0.5
            let row = (seed * 7.3).truncatingRemainder(dividingBy: 1)
            let size = 2.5 + (seed * 5.1).truncatingRemainder(dividingBy: 3)
            let center = CGPoint(x: hearth.x + across * 120, y: hearth.y + 2 + row * 12)
            var chip = Path()
            chip.move(to: CGPoint(x: center.x - size, y: center.y))
            chip.addLine(to: CGPoint(x: center.x - size * 0.2, y: center.y - size * 0.7))
            chip.addLine(to: CGPoint(x: center.x + size, y: center.y - size * 0.2))
            chip.addLine(to: CGPoint(x: center.x + size * 0.4, y: center.y + size * 0.6))
            chip.closeSubpath()
            let lit = abs(across) < 0.3 && piece % 2 == 0
            context.fill(chip, with: .color(lit ? JournalFirePalette.orange.opacity(heat)
                                            : piece % 3 == 0 ? JournalFirePalette.char : JournalFirePalette.cinder))
        }
    }

    private func drawHeart(time: Double, heat: Double, hearth: CGPoint, in context: inout GraphicsContext) {
        let core = CGPoint(x: hearth.x - 2, y: hearth.y - 16)
        let radius = 46.0
        context.fill(Path(ellipseIn: CGRect(x: core.x - radius, y: core.y - radius, width: radius * 2, height: radius * 2)),
                     with: .radialGradient(
                        Gradient(colors: [JournalFirePalette.gold.opacity(heat), JournalFirePalette.orange.opacity(0.8 * heat),
                                          JournalFirePalette.flame.opacity(0)]),
                        center: core, startRadius: 0, endRadius: radius))
        for lick in 0..<5 {
            let phase = Double(lick) * 2.399
            let x = core.x + (Double(lick) - 2) * 15
            let height = (20 + 12 * abs(sin(phase * 1.3))) * (0.8 + 0.2 * sin(time * 3.4 + phase))
            let flame = JournalFireBackground.tongue(center: x, width: 9, height: height,
                                                     sway: sin(time * 2.4 + phase) * 2.5, floor: core.y + 8)
            context.fill(flame, with: .color(lick % 2 == 0 ? JournalFirePalette.orange : JournalFirePalette.amber))
        }
    }

    private func draw(_ plank: Plank, heat: Double, hearth: CGPoint, in context: GraphicsContext) {
        let outer = CGPoint(x: hearth.x + plank.outer.x, y: hearth.y + plank.outer.y)
        let inner = CGPoint(x: hearth.x + plank.inner.x, y: hearth.y + plank.inner.y)
        let run = CGPoint(x: inner.x - outer.x, y: inner.y - outer.y)
        let length = max(hypot(run.x, run.y), 1)
        let flip = run.x >= 0 ? 1.0 : -1.0
        let across = CGPoint(x: run.y / length * flip * plank.width / 2, y: -run.x / length * flip * plank.width / 2)
        func shifted(_ point: CGPoint, by side: Double, drop: Double = 0) -> CGPoint {
            CGPoint(x: point.x + across.x * side, y: point.y + across.y * side + drop)
        }
        let along = { (share: Double) -> Gradient.Stop in
            Gradient.Stop(color: JournalFirePalette.char, location: share)
        }

        canvasFill(context, [shifted(outer, by: 1), shifted(outer, by: -1), shifted(outer, by: -1, drop: plank.depth), shifted(outer, by: 1, drop: plank.depth)],
                   .color(JournalFirePalette.endGrain))
        canvasFill(context, [shifted(outer, by: -1), shifted(inner, by: -1), shifted(inner, by: -1, drop: plank.depth), shifted(outer, by: -1, drop: plank.depth)],
                   .linearGradient(Gradient(stops: [.init(color: JournalFirePalette.woodSide, location: 0),
                                                    .init(color: JournalFirePalette.woodSide, location: 1 - plank.char - 0.15),
                                                    along(1 - plank.char), along(1)]),
                                   startPoint: outer, endPoint: inner))
        canvasFill(context, [shifted(outer, by: 1), shifted(inner, by: 1), shifted(inner, by: -1), shifted(outer, by: -1)],
                   .linearGradient(Gradient(stops: [.init(color: JournalFirePalette.wood, location: 0),
                                                    .init(color: JournalFirePalette.wood, location: 1 - plank.char - 0.18),
                                                    along(1 - plank.char), along(1)]),
                                   startPoint: outer, endPoint: inner))
        let seed = abs(plank.outer.x + plank.inner.y)
        canvasFill(context, [shifted(outer, by: 1), shifted(inner, by: 1), shifted(inner, by: -1), shifted(outer, by: -1)],
                   .color(JournalFirePalette.char.opacity(abs(sin(seed)) * 0.25)))
        for streak in 0..<2 {
            let phase = seed + Double(streak) * 2.399
            let side = sin(phase * 1.7) * 0.7
            let from = 0.04 + abs(sin(phase)) * 0.3
            let to = from + 0.2 + abs(cos(phase * 1.3)) * (0.56 - plank.char)
            var grain = Path()
            grain.move(to: shifted(CGPoint(x: outer.x + run.x * from, y: outer.y + run.y * from), by: side))
            grain.addLine(to: shifted(CGPoint(x: outer.x + run.x * to, y: outer.y + run.y * to), by: side))
            context.stroke(grain, with: .color(JournalFirePalette.woodSide.opacity(0.55)), lineWidth: 0.8)
        }
        var ember = context
        ember.addFilter(.blur(radius: 1.5))
        var edge = Path()
        edge.move(to: shifted(inner, by: 1))
        edge.addLine(to: shifted(inner, by: -1, drop: plank.depth))
        ember.stroke(edge, with: .color(JournalFirePalette.orange.opacity(heat)), lineWidth: 2.5)
    }

    private func canvasFill(_ context: GraphicsContext, _ points: [CGPoint], _ shading: GraphicsContext.Shading) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        context.fill(path, with: shading)
    }

    private func drawSparks(time: Double, hearth: CGPoint, in context: inout GraphicsContext, size: CGSize) {
        for spark in 0..<20 {
            let seed = Double(spark) * 0.618
            let climb = (time * (0.11 + 0.04 * sin(seed * 9)) + seed).truncatingRemainder(dividingBy: 1)
            let across = (seed * 3.7).truncatingRemainder(dividingBy: 1) - 0.5
            let radius = 1.2 + (seed * 5).truncatingRemainder(dividingBy: 1.4)
            let center = CGPoint(x: hearth.x + across * 80 * (1 + climb * 2.2) + sin(time * 1.3 + seed * 6) * (3 + climb * 12),
                                 y: hearth.y - 30 - climb * (size.height - Self.spill) * 0.8)
            let color = climb < 0.45 ? JournalFirePalette.gold : JournalFirePalette.amber
            let fade = 1 - climb * climb
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius * 3, y: center.y - radius * 3, width: radius * 6, height: radius * 6)),
                         with: .radialGradient(Gradient(colors: [JournalFirePalette.orange.opacity(fade * 0.5), JournalFirePalette.orange.opacity(0)]),
                                               center: center, startRadius: 0, endRadius: radius * 3))
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(color.opacity(fade)))
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
                    .fadesNearTop(from: 52, to: 26)
                    .padding(.top, -44)
                details.fadesNearTop(from: 105, to: 65)
                if let action = summary.action {
                    actionButton(action).fadesNearTop(from: 105, to: 65)
                }
            }
            .foregroundStyle(.white)
            calendar
                .fadesNearTop(from: 105, to: 65)
                .padding(.top, 2)
        }
        .padding(.bottom, lit ? 38 : 54)
        .environment(\.colorScheme, .light)
        .background {
            Group { if lit { fire } else { kindling } }.padding(.horizontal, -16)
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
                .background(gradient([JournalFirePalette.ember, JournalFirePalette.top, JournalFirePalette.glow],
                                     height: proxy.size.height))
                .mask { fade(height: proxy.size.height) }
                .offset(y: -Self.overscroll)
        }
        .accessibilityHidden(true)
    }

    private var kindling: some View {
        GeometryReader { proxy in
            gradient([JournalFirePalette.ash, JournalFirePalette.coal, JournalFirePalette.smoulder],
                     height: proxy.size.height)
                .frame(height: proxy.size.height + Self.overscroll)
                .mask { fade(height: proxy.size.height) }
                .offset(y: -Self.overscroll)
            JournalKindling().frame(height: proxy.size.height + JournalKindling.spill)
        }
        .accessibilityHidden(true)
    }

    private func gradient(_ colors: [Color], height: CGFloat) -> LinearGradient {
        let total = height + Self.overscroll
        return LinearGradient(stops: [
            .init(color: colors[0], location: Self.overscroll / total),
            .init(color: colors[1], location: (Self.overscroll + height * 0.5) / total),
            .init(color: colors[2], location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private func fade(height: CGFloat) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 1 - Self.calendarFade / (height + Self.overscroll)),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let headline = summary.headline {
                Text(headline)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(settled ? 1 : 0)
                    .accessibilityHidden(!settled)
                HStack(spacing: 8) {
                    message
                    if !typeSize.isAccessibilitySize {
                        Spacer(minLength: 8)
                        progress
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: countSize * 0.62))
                        .foregroundStyle(JournalFirePalette.gold)
                    Text("\(summary.count)")
                        .font(.system(size: countSize, weight: .heavy, design: .rounded))
                    Text("day streak").font(.title3.weight(.bold))
                    if !typeSize.isAccessibilitySize {
                        Spacer(minLength: 8)
                        progress
                    }
                }
                message
            }
            if typeSize.isAccessibilitySize { progress }
        }
        .accessibilityElement(children: .combine)
    }

    private var message: some View {
        Text(summary.message)
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .opacity(settled ? 1 : 0)
            .accessibilityHidden(!settled)
    }

    private var progress: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(0..<JournalDailyList.dailyTarget, id: \.self) { dot in
                    Circle()
                        .fill(.white.opacity(dot < summary.answeredToday ? 1 : 0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
            Text("\(summary.answeredToday) of \(JournalDailyList.dailyTarget) today")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }

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
            .foregroundStyle(JournalFirePalette.deep)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

private extension View {
    func fadesNearTop(from start: CGFloat, to end: CGFloat) -> some View {
        visualEffect { content, proxy in
            let progress = (proxy.frame(in: .global).minY - end) / (start - end)
            return content.opacity(min(max(progress, 0), 1))
        }
    }
}

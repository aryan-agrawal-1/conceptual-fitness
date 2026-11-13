import SwiftUI
import simd

enum OnboardingScene: Equatable {
    case welcome
    case name
    case location
    case timezone
    case birthday
    case sex
    case height
    case weight
    case device

    var colors: [Color] {
        switch self {
        case .welcome, .name:
            [Color(red: 0.05, green: 0.06, blue: 0.20), Color(red: 0.24, green: 0.16, blue: 0.42), Color(red: 0.86, green: 0.47, blue: 0.42)]
        case .location, .timezone:
            [Color(red: 0.07, green: 0.12, blue: 0.30), Color(red: 0.55, green: 0.30, blue: 0.48), Color(red: 0.98, green: 0.66, blue: 0.40)]
        case .birthday, .sex, .height, .weight:
            [Color(red: 0.02, green: 0.11, blue: 0.14), Color(red: 0.04, green: 0.27, blue: 0.30), Color(red: 0.12, green: 0.50, blue: 0.50)]
        case .device:
            [Color(red: 0.03, green: 0.035, blue: 0.05), Color(red: 0.06, green: 0.065, blue: 0.09), Color(red: 0.10, green: 0.105, blue: 0.14)]
        }
    }
}

enum OnboardingPalette {
    static let readiness = Color(red: 0.30, green: 0.85, blue: 0.52)
    static let sleep = Color(red: 0.50, green: 0.56, blue: 1.0)
    static let strain = Color(red: 1.0, green: 0.60, blue: 0.24)
}

struct OnboardingSky: View {
    let scene: OnboardingScene
    var level: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: scene.colors, startPoint: .top, endPoint: .bottom)
            OnboardingSkyArt(scene: scene, level: level)
        }
        .id(scene)
        .transition(.opacity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

@MainActor
private final class EasedLevel {
    private var current: Double?

    func advance(toward target: Double, instantly: Bool) -> Double {
        guard let current, !instantly, abs(target - current) > 0.002 else {
            current = target
            return target
        }
        let next = current + (target - current) * 0.2
        self.current = next
        return next
    }
}

private struct OnboardingSkyArt: View {
    let scene: OnboardingScene
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eased = EasedLevel()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 18 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let value = eased.advance(toward: level, instantly: reduceMotion)
            Canvas { context, size in
                switch scene {
                case .welcome: drawWelcome(time, &context, size, CGPoint(x: size.width / 2, y: size.height * 0.30), 1)
                case .name: drawWelcome(time, &context, size, CGPoint(x: size.width / 2, y: 196), 0.62)
                case .location: drawEarth(time, &context, size, CGPoint(x: size.width / 2, y: 262))
                case .timezone: drawEarth(time, &context, size, CGPoint(x: size.width / 2, y: size.height * 0.64))
                case .birthday: drawPulse(time, &context, size)
                case .sex: drawEffort(time, value, &context, size)
                case .height: drawHeight(value, &context, size)
                case .weight: drawScale(value, &context, size)
                case .device: drawStudio(time, &context, size)
                }
            }
        }
    }

    private func noise(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }

    private func dot(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func glow(_ center: CGPoint, _ radius: CGFloat, _ color: Color, _ strength: Double, _ context: inout GraphicsContext) {
        context.fill(dot(center, radius), with: .radialGradient(
            Gradient(colors: [color.opacity(strength), color.opacity(0)]),
            center: center, startRadius: 0, endRadius: radius))
    }

    private func stars(_ time: Double, _ count: Int, _ height: CGFloat, _ context: inout GraphicsContext, _ size: CGSize) {
        for index in 0..<count {
            let center = CGPoint(x: noise(index, 1) * size.width, y: noise(index, 2) * height)
            let twinkle = 0.5 + 0.5 * sin(time * (0.5 + noise(index, 4) * 1.6) + noise(index, 5) * 6.28)
            context.fill(dot(center, 0.5 + noise(index, 3) * 1.3), with: .color(.white.opacity(0.15 + 0.7 * twinkle * noise(index, 6))))
        }
    }

    private func drawWelcome(_ time: Double, _ context: inout GraphicsContext, _ size: CGSize, _ center: CGPoint, _ scale: CGFloat) {
        stars(time, 70, size.height * 0.55, &context, size)
        glow(CGPoint(x: size.width / 2, y: size.height * 1.02), size.width * 0.9, Color(red: 1, green: 0.72, blue: 0.5), 0.55, &context)
        glow(center, 150 * scale, .white, 0.10, &context)
        let rings: [(Color, CGFloat, Double, Double)] = [
            (OnboardingPalette.readiness, 92, 0.78, 0.16), (OnboardingPalette.sleep, 70, 0.64, -0.22), (OnboardingPalette.strain, 48, 0.52, 0.3)
        ]
        for (index, ring) in rings.enumerated() {
            let breathe = 0.06 * sin(time * 0.6 + Double(index))
            let start = Angle(radians: time * ring.3 - .pi / 2)
            var track = Path()
            track.addArc(center: center, radius: ring.1 * scale, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .color(ring.0.opacity(0.18)), style: StrokeStyle(lineWidth: 14 * scale))
            var arc = Path()
            arc.addArc(center: center, radius: ring.1 * scale, startAngle: start, endAngle: start + .radians(2 * .pi * (ring.2 + breathe)), clockwise: false)
            var glowContext = context
            glowContext.addFilter(.blur(radius: 8 * scale))
            glowContext.stroke(arc, with: .color(ring.0.opacity(0.7)), style: StrokeStyle(lineWidth: 16 * scale, lineCap: .round))
            context.stroke(arc, with: .color(ring.0), style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round))
        }
    }

    private func drawEarth(_ time: Double, _ context: inout GraphicsContext, _ size: CGSize, _ center: CGPoint) {
        stars(time, 60, size.height * 0.7, &context, size)
        let radius = min(size.width * 0.35, 140)
        let gold = Color(red: 1, green: 0.84, blue: 0.55)
        let sun = CGPoint(x: center.x + radius * 0.74, y: center.y - radius * 0.70)
        for ray in 0..<14 {
            let angle = Double(ray) / 14 * 2 * .pi + time * 0.04
            var path = Path()
            path.move(to: sun)
            path.addLine(to: CGPoint(x: sun.x + cos(angle - 0.05) * size.width, y: sun.y + sin(angle - 0.05) * size.width))
            path.addLine(to: CGPoint(x: sun.x + cos(angle + 0.05) * size.width, y: sun.y + sin(angle + 0.05) * size.width))
            path.closeSubpath()
            context.fill(path, with: .radialGradient(Gradient(colors: [gold.opacity(0.14), gold.opacity(0)]), center: sun, startRadius: 20, endRadius: size.width * 0.8))
        }
        glow(sun, radius * 1.5, gold, 0.6, &context)
        context.fill(dot(sun, 22), with: .radialGradient(Gradient(colors: [.white, gold]), center: sun, startRadius: 0, endRadius: 22))
        glow(center, radius * 1.2, Color(red: 0.62, green: 0.74, blue: 1), 0.4, &context)
        context.fill(dot(center, radius), with: .radialGradient(
            Gradient(colors: [Color(red: 0.24, green: 0.24, blue: 0.52), Color(red: 0.07, green: 0.08, blue: 0.24), Color(red: 0.03, green: 0.04, blue: 0.13)]),
            center: CGPoint(x: center.x + radius * 0.45, y: center.y - radius * 0.45), startRadius: 0, endRadius: radius * 1.7))

        let home = EarthLand.home
        let turn = home.longitude + (reduceMotion ? 0 : sin(time * 0.1) * 0.6)
        let tilt = home.latitude * 0.75
        let sunward = SIMD3<Double>(0.60, 0.57, 0.56)
        func place(_ point: EarthPoint) -> SIMD3<Double> {
            let around = point.longitude - turn
            let flat = SIMD3(cos(point.latitude) * sin(around), sin(point.latitude), cos(point.latitude) * cos(around))
            return SIMD3(flat.x, flat.y * cos(tilt) - flat.z * sin(tilt), flat.y * sin(tilt) + flat.z * cos(tilt))
        }
        for point in EarthLand.points {
            let position = place(point)
            guard position.z > 0.03 else { continue }
            let light = max(0, simd_dot(position, sunward))
            let spot = CGPoint(x: center.x + position.x * radius, y: center.y - position.y * radius)
            let tone = Color(red: 1, green: 0.90 + 0.10 * (1 - light), blue: 0.72 + 0.28 * (1 - light))
            context.fill(dot(spot, radius / 82 * (0.5 + 0.5 * position.z)), with: .color(tone.opacity((0.26 + 0.74 * light) * min(1, position.z * 5))))
        }
        context.stroke(dot(center, radius), with: .linearGradient(
            Gradient(colors: [gold.opacity(0.9), gold.opacity(0.05)]),
            startPoint: CGPoint(x: center.x + radius * 0.7, y: center.y - radius * 0.7),
            endPoint: CGPoint(x: center.x - radius * 0.5, y: center.y + radius * 0.5)), lineWidth: 1.5)

        let position = place(home)
        guard position.z > 0.1 else { return }
        let pin = CGPoint(x: center.x + position.x * radius, y: center.y - position.y * radius)
        let pulse = reduceMotion ? 0.4 : (time * 0.5).truncatingRemainder(dividingBy: 1)
        context.stroke(dot(pin, 5 + 22 * pulse), with: .color(.white.opacity(0.75 * (1 - pulse))), lineWidth: 2)
        glow(pin, 16, .white, 0.5, &context)
        context.fill(dot(pin, 4.5), with: .color(.white))
    }

    private func drawPulse(_ time: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let teal = Color(red: 0.55, green: 0.98, blue: 0.86)
        glow(CGPoint(x: size.width / 2, y: size.height * 0.28), size.width * 0.75, teal, 0.18, &context)
        let baseline = size.height * 0.26
        let sweep = (time * 0.25).truncatingRemainder(dividingBy: 1)
        var line = Path()
        for step in stride(from: 0.0, through: Double(size.width), by: 2) {
            let x = step / Double(size.width)
            let beat = (x * 2.2).truncatingRemainder(dividingBy: 1)
            var y = 0.0
            if beat > 0.40 && beat < 0.44 { y = -10 * sin((beat - 0.40) / 0.04 * .pi) }
            if beat > 0.46 && beat < 0.52 { y = 58 * sin((beat - 0.46) / 0.06 * 2 * .pi) }
            if beat > 0.60 && beat < 0.70 { y = -14 * sin((beat - 0.60) / 0.10 * .pi) }
            let point = CGPoint(x: step, y: baseline - y)
            step == 0 ? line.move(to: point) : line.addLine(to: point)
        }
        context.stroke(line, with: .color(teal.opacity(0.18)), lineWidth: 2)
        let head = CGFloat(sweep) * size.width
        var lit = context
        lit.clip(to: Path(CGRect(x: head - size.width * 0.45, y: 0, width: size.width * 0.45, height: size.height)))
        var glowing = lit
        glowing.addFilter(.blur(radius: 6))
        glowing.stroke(line, with: .linearGradient(Gradient(colors: [teal.opacity(0), teal]), startPoint: CGPoint(x: head - size.width * 0.45, y: 0), endPoint: CGPoint(x: head, y: 0)), lineWidth: 6)
        lit.stroke(line, with: .linearGradient(Gradient(colors: [teal.opacity(0), .white]), startPoint: CGPoint(x: head - size.width * 0.45, y: 0), endPoint: CGPoint(x: head, y: 0)), lineWidth: 2.5)
        for index in 0..<22 {
            let drift = (time * (6 + noise(index, 7) * 10) + noise(index, 8) * Double(size.height)).truncatingRemainder(dividingBy: Double(size.height))
            context.fill(dot(CGPoint(x: noise(index, 9) * size.width, y: size.height - drift), 1 + noise(index, 10) * 1.6), with: .color(teal.opacity(0.3)))
        }
    }

    private func drawEffort(_ time: Double, _ coefficient: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let orange = OnboardingPalette.strain
        glow(CGPoint(x: size.width * 0.78, y: 150), size.width * 0.7, orange, 0.2, &context)
        let frame = CGRect(x: 24, y: 112, width: size.width - 48, height: 138)
        func point(_ effort: Double, _ k: Double) -> CGPoint {
            CGPoint(x: frame.minX + effort * frame.width, y: frame.maxY - effort * exp(k * effort) / exp(1.92) * frame.height)
        }
        func curve(_ k: Double, to limit: Double = 1) -> Path {
            var path = Path()
            path.move(to: point(0, k))
            for step in stride(from: 0.01, through: limit, by: 0.01) { path.addLine(to: point(step, k)) }
            return path
        }
        for zone in 0...5 {
            let x = frame.minX + frame.width * CGFloat(zone) / 5
            var line = Path()
            line.move(to: CGPoint(x: x, y: frame.minY))
            line.addLine(to: CGPoint(x: x, y: frame.maxY))
            context.stroke(line, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        }
        for reference in [1.67, 1.92] {
            context.stroke(curve(reference), with: .color(.white.opacity(0.16)), lineWidth: 1.5)
        }
        var area = curve(coefficient)
        area.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        area.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [orange.opacity(0.34), orange.opacity(0)]),
                                                 startPoint: CGPoint(x: 0, y: frame.minY), endPoint: CGPoint(x: 0, y: frame.maxY)))
        var halo = context
        halo.addFilter(.blur(radius: 7))
        halo.stroke(curve(coefficient), with: .color(orange.opacity(0.8)), lineWidth: 6)
        context.stroke(curve(coefficient), with: .linearGradient(Gradient(colors: [orange.opacity(0.3), .white]),
                                                                 startPoint: CGPoint(x: frame.minX, y: 0), endPoint: CGPoint(x: frame.maxX, y: 0)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let travel = reduceMotion ? 0.72 : 0.5 - 0.5 * cos(time * 0.5)
        let beat = reduceMotion ? 0.5 : pow(abs(sin(time * 2.6)), 6)
        let head = point(travel, coefficient)
        glow(head, 20 + 10 * beat, orange, 0.8, &context)
        context.fill(dot(head, 5 + 2 * beat), with: .color(.white))
    }

    private func drawHeight(_ centimetres: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let teal = Color(red: 0.55, green: 0.98, blue: 0.86)
        let floor: CGFloat = 252
        let perCentimetre: CGFloat = 0.6
        let middle = size.width / 2
        glow(CGPoint(x: middle, y: 180), size.width * 0.7, teal, 0.16, &context)
        let ruler = middle + 74
        var spine = Path()
        spine.move(to: CGPoint(x: ruler, y: floor))
        spine.addLine(to: CGPoint(x: ruler, y: floor - 235 * perCentimetre))
        context.stroke(spine, with: .color(.white.opacity(0.25)), lineWidth: 1)
        for mark in stride(from: 0, through: 230, by: 10) {
            let y = floor - CGFloat(mark) * perCentimetre
            let major = mark % 50 == 0
            var tick = Path()
            tick.move(to: CGPoint(x: ruler, y: y))
            tick.addLine(to: CGPoint(x: ruler + (major ? 14 : 7), y: y))
            context.stroke(tick, with: .color(.white.opacity(major ? 0.5 : 0.25)), lineWidth: 1)
            if major && mark > 0 {
                context.draw(Text("\(mark)").font(.system(.caption2, design: .rounded, weight: .semibold)).foregroundStyle(.white.opacity(0.5)),
                             at: CGPoint(x: ruler + 30, y: y))
            }
        }
        var ground = Path()
        ground.move(to: CGPoint(x: middle - 110, y: floor))
        ground.addLine(to: CGPoint(x: ruler + 14, y: floor))
        context.stroke(ground, with: .color(.white.opacity(0.25)), lineWidth: 1)

        let tall = CGFloat(centimetres) * perCentimetre
        var figure = context.resolve(Image(systemName: "figure.stand"))
        figure.shading = .linearGradient(Gradient(colors: [.white, teal.opacity(0.75)]),
                                         startPoint: CGPoint(x: 0, y: floor - tall), endPoint: CGPoint(x: 0, y: floor))
        let wide = tall * figure.size.width / max(figure.size.height, 1)
        context.draw(figure, in: CGRect(x: middle - 22 - wide / 2, y: floor - tall, width: wide, height: tall))

        var marker = Path()
        marker.move(to: CGPoint(x: middle - 70, y: floor - tall))
        marker.addLine(to: CGPoint(x: ruler + 14, y: floor - tall))
        var halo = context
        halo.addFilter(.blur(radius: 5))
        halo.stroke(marker, with: .color(teal.opacity(0.9)), lineWidth: 4)
        context.stroke(marker, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        context.fill(dot(CGPoint(x: ruler, y: floor - tall), 4), with: .color(.white))
    }

    private func drawScale(_ reading: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let teal = Color(red: 0.55, green: 0.98, blue: 0.86)
        let middle = size.width / 2
        let base: CGFloat = 222
        let spacing: CGFloat = 9
        glow(CGPoint(x: middle, y: base - 30), size.width * 0.65, teal, 0.18, &context)
        let span = Int(middle / spacing) + 2
        for mark in (Int(reading) - span)...(Int(reading) + span) where mark >= 0 {
            let x = middle + (CGFloat(mark) - CGFloat(reading)) * spacing
            let fade = max(0, 1 - pow(abs(x - middle) / middle, 2))
            let major = mark % 10 == 0
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: base))
            tick.addLine(to: CGPoint(x: x, y: base - (major ? 38 : mark % 5 == 0 ? 26 : 16)))
            context.stroke(tick, with: .color(.white.opacity((major ? 0.75 : 0.35) * fade)), style: StrokeStyle(lineWidth: major ? 2 : 1, lineCap: .round))
            if major {
                context.draw(Text("\(mark)").font(.system(.footnote, design: .rounded, weight: .semibold)).foregroundStyle(.white.opacity(0.6 * fade)),
                             at: CGPoint(x: x, y: base + 18))
            }
        }
        var needle = Path()
        needle.move(to: CGPoint(x: middle, y: base + 4))
        needle.addLine(to: CGPoint(x: middle, y: base - 64))
        var halo = context
        halo.addFilter(.blur(radius: 6))
        halo.stroke(needle, with: .color(teal), lineWidth: 6)
        context.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        var cap = Path()
        cap.move(to: CGPoint(x: middle - 8, y: base - 78))
        cap.addLine(to: CGPoint(x: middle + 8, y: base - 78))
        cap.addLine(to: CGPoint(x: middle, y: base - 66))
        cap.closeSubpath()
        context.fill(cap, with: .color(.white))
    }

    private func drawStudio(_ time: Double, _ context: inout GraphicsContext, _ size: CGSize) {
        let breathe = 0.02 * sin(time * 0.4)
        glow(CGPoint(x: size.width / 2, y: -size.height * 0.05), size.height * 0.75, .white, 0.13 + breathe, &context)
        glow(CGPoint(x: size.width / 2, y: size.height * 0.52), size.width * 0.85, Color(red: 0.75, green: 0.8, blue: 1), 0.07, &context)
    }
}

struct OnboardingProgressBar: View {
    let position: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index < position ? 0.95 : 0.22))
                    .frame(height: 4)
            }
        }
        .animation(.snappy, value: position)
        .accessibilityElement()
        .accessibilityLabel("Step \(position) of \(total)")
    }
}

struct OnboardingHeadline: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    var ink: Color = Color(red: 0.08, green: 0.10, blue: 0.24)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.white.opacity(isEnabled ? 1 : 0.45), in: Capsule())
            .shadow(color: .white.opacity(isEnabled ? 0.25 : 0), radius: 16)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

struct OnboardingQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.5 : 0.85))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
    }
}

extension View {
    func onboardingGlass(cornerRadius: CGFloat = 24) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }
}

struct DeviceShowcaseCard: View {
    let device: DataSourceDevice
    let selected: Bool
    let connected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                DeviceSlot(device: device)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .bottom) {
                        Ellipse()
                            .fill(.white.opacity(0.2))
                            .frame(width: 124, height: 20)
                            .blur(radius: 14)
                            .padding(.bottom, 22)
                    }
                VStack(spacing: 4) {
                    Text(device == .fitbit ? "Fitbit" : device.title)
                        .font(.headline)
                    Text(device == .fitbit ? "and Google devices" : "via Apple Health")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    if connected {
                        Text("Connected").font(.caption.weight(.semibold)).foregroundStyle(OnboardingPalette.readiness)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(selected ? 0.16 : 0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.95 : 0.14), lineWidth: selected ? 2 : 1)
            }
            .shadow(color: .white.opacity(selected ? 0.25 : 0), radius: 18)
            .scaleEffect(selected ? 1.02 : 1)
            .animation(.snappy, value: selected)
            .contentShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(device.title)
        .accessibilityHint(device.detail)
        .accessibilityValue(connected ? "Connected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

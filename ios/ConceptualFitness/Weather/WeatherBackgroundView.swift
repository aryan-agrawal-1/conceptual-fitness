import SwiftUI

struct WeatherBackgroundView: View {
    var weather: WeatherData
    var debugOptions: WeatherDebugOptions = .live

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 / 10 : 1 / 30)) { timeline in
            let state = WeatherRenderState(
                weather: weather,
                date: timeline.date,
                reduceMotion: reduceMotion,
                debugOptions: debugOptions
            )

            ZStack {
                SkyLayer(state: state, date: timeline.date)
                SunMoonGlowLayer(state: state)
                CloudFieldLayer(kind: .distant, state: state, date: timeline.date)
                CloudFieldLayer(kind: .back, state: state, date: timeline.date)
                CloudFieldLayer(kind: .mid, state: state, date: timeline.date)
                CloudFieldLayer(kind: .front, state: state, date: timeline.date)
                FogMistLayer(state: state, date: timeline.date)
                PrecipitationLayer(depth: .back, state: state, date: timeline.date)
                PrecipitationLayer(depth: .front, state: state, date: timeline.date)
                ForegroundAtmosphereLayer(state: state, date: timeline.date)
                LightningLayer(state: state, date: timeline.date)
            }
            .compositingGroup()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        .clear,
                        Color(red: 0.97, green: 0.98, blue: 0.96).opacity(0.50),
                        Color.white.opacity(0.94)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 190)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(edges: .top)
    }
}

struct WeatherDebugOptions: Equatable {
    var animationSpeedMultiplier: Double = 1
    var showLayerDebugOutlines = false
    var forceRainVisible = false
    var forceSunVisible = false
    var forceCloudsVisible = false

    static let live = WeatherDebugOptions()
}

private enum CloudLayerKind {
    case distant
    case back
    case mid
    case front

    var depth: Double {
        switch self {
        case .distant: 0.12
        case .back: 0.34
        case .mid: 0.62
        case .front: 0.90
        }
    }

    var baseSpeed: Double {
        switch self {
        case .distant: 4
        case .back: -7
        case .mid: 11
        case .front: -16
        }
    }

    var yRange: ClosedRange<Double> {
        switch self {
        case .distant: 0.08...0.22
        case .back: 0.12...0.34
        case .mid: 0.20...0.48
        case .front: 0.36...0.63
        }
    }
}

enum CloudVariant: CaseIterable {
    case largeLow
    case mediumCluster
    case wispy
    case distantStrip

    var aspect: CGFloat {
        switch self {
        case .largeLow: 3.7
        case .mediumCluster: 2.65
        case .wispy: 4.8
        case .distantStrip: 6.4
        }
    }

    var lobeCount: Int {
        switch self {
        case .largeLow: 10
        case .mediumCluster: 8
        case .wispy: 7
        case .distantStrip: 6
        }
    }

    var baseBlur: CGFloat {
        switch self {
        case .largeLow: 8
        case .mediumCluster: 7
        case .wispy: 11
        case .distantStrip: 14
        }
    }
}

private enum PrecipitationDepth {
    case back
    case front
}

private struct SkyLayer: View {
    let state: WeatherRenderState
    let date: Date

    var body: some View {
        if #available(iOS 18.0, *) {
            MeshGradient(
                width: 3,
                height: 3,
                points: meshPoints,
                colors: state.skyPalette.map(\.color),
                background: state.skyPalette.last?.color ?? .black,
                smoothsColors: true
            )
            .overlay {
                RadialGradient(
                    colors: [state.horizonPalette.last?.color.opacity(0.40) ?? .clear, .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 520
                )
                .blendMode(.softLight)
            }
        } else {
            LinearGradient(
                colors: state.skyPalette.map(\.color),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                RadialGradient(
                    colors: [state.horizonPalette.last?.color.opacity(0.34) ?? .clear, .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 520
                )
            }
        }
    }

    private var meshPoints: [SIMD2<Float>] {
        let t = state.motionTime(date, scale: 0.010)
        let drift = Float(sin(t) * 0.018)
        let lift = Float(cos(t * 0.72) * 0.016)
        return [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(0.50 + drift, 0.00),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0.00, 0.47 + lift),
            SIMD2<Float>(0.52 - drift, 0.42 + lift),
            SIMD2<Float>(1.00, 0.51 - lift),
            SIMD2<Float>(0, 1),
            SIMD2<Float>(0.49 + drift, 1),
            SIMD2<Float>(1, 1)
        ]
    }
}

private struct SunMoonGlowLayer: View {
    let state: WeatherRenderState

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = state.sunMoonPosition(in: size)
            let base = min(size.width, size.height)
            let force = state.debugOptions.forceSunVisible ? 1.55 : 1
            let radius = base * (state.isNight ? 0.34 : 0.48) * force
            let coreRadius = base * (state.isNight ? 0.16 : 0.22) * force
            let outerOpacity = (state.isNight ? 0.24 : 0.44 + state.goldenHourProgress * 0.22) * force
            let innerOpacity = (state.isNight ? 0.18 : 0.36 + state.goldenHourProgress * 0.28) * force
            let color = state.sunMoonColor.color

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(outerOpacity), color.opacity(outerOpacity * 0.35), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                    .blur(radius: base * 0.045)
                    .blendMode(.screen)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(innerOpacity), color.opacity(innerOpacity * 0.30), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: coreRadius
                        )
                    )
                    .frame(width: coreRadius * 2, height: coreRadius * 2)
                    .position(center)
                    .blur(radius: base * 0.018)
                    .blendMode(.screen)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct CloudFieldLayer: View {
    let kind: CloudLayerKind
    let state: WeatherRenderState
    let date: Date

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let opacity = layerOpacity
            let count = bankCount
            let laneWidth = size.width * 1.95
            let drift = state.motionTime(date, scale: 1) * (kind.baseSpeed + state.windSpeed * 0.65)

            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    let seed = Double(index + layerSeed)
                    let variant = variant(for: index)
                    let bankWidth = size.width * widthScale(for: variant, seed: seed)
                    let bankHeight = bankWidth / variant.aspect
                    let x = wrappedX(seed: seed, width: laneWidth, drift: drift) - bankWidth * 0.30
                    let y = size.height * interpolatedY(seed: seed)
                    let bankOpacity = opacity * (0.62 + seeded(seed, 0.44) * 0.34)

                    CloudBank(
                        variant: variant,
                        seed: seed,
                        opacity: bankOpacity,
                        night: state.isNight,
                        showDebugOutlines: state.debugOptions.showLayerDebugOutlines
                    )
                    .frame(width: bankWidth, height: bankHeight)
                    .position(x: x, y: y)
                    .blur(radius: variant.baseBlur + CGFloat((1 - kind.depth) * 6))
                    .shadow(color: shadowColor.opacity(bankOpacity * 0.55), radius: 12 + kind.depth * 10, x: 0, y: 10 + kind.depth * 8)
                    .opacity(bankOpacity)
                }
            }
            .drawingGroup()
        }
        .opacity(layerOpacity > 0.02 ? 1 : 0)
    }

    private var layerSeed: Int {
        switch kind {
        case .distant: 200
        case .back: 300
        case .mid: 400
        case .front: 500
        }
    }

    private var layerOpacity: Double {
        let boost = state.debugOptions.forceCloudsVisible ? 0.58 : 0
        let base = state.cloudOpacity + boost
        switch kind {
        case .distant: return (base * 0.40 + state.fogAmount * 0.10).clamped(to: 0...0.48)
        case .back: return (base * 0.48).clamped(to: 0...0.56)
        case .mid: return (base * 0.52).clamped(to: 0...0.62)
        case .front: return (base * max(0.12, state.cloudDensity - 0.26)).clamped(to: 0...0.58)
        }
    }

    private var bankCount: Int {
        let forced = state.debugOptions.forceCloudsVisible ? 2 : 0
        switch kind {
        case .distant: return 3 + Int(state.cloudDensity * 3) + forced
        case .back: return 2 + Int(state.cloudDensity * 3) + forced
        case .mid: return 2 + Int(state.cloudDensity * 4) + forced
        case .front: return max(1, Int(state.cloudDensity * 3)) + forced
        }
    }

    private var shadowColor: Color {
        state.isNight ? Color(red: 0.08, green: 0.10, blue: 0.18) : Color(red: 0.35, green: 0.44, blue: 0.54)
    }

    private func variant(for index: Int) -> CloudVariant {
        switch kind {
        case .distant: return index.isMultiple(of: 2) ? .distantStrip : .wispy
        case .back: return index.isMultiple(of: 3) ? .wispy : .mediumCluster
        case .mid: return index.isMultiple(of: 2) ? .largeLow : .mediumCluster
        case .front: return index.isMultiple(of: 2) ? .largeLow : .wispy
        }
    }

    private func widthScale(for variant: CloudVariant, seed: Double) -> Double {
        let jitter = seeded(seed, 0.23)
        switch variant {
        case .largeLow: return 0.72 + jitter * 0.36
        case .mediumCluster: return 0.42 + jitter * 0.30
        case .wispy: return 0.50 + jitter * 0.44
        case .distantStrip: return 0.72 + jitter * 0.58
        }
    }

    private func interpolatedY(seed: Double) -> Double {
        kind.yRange.lowerBound + (kind.yRange.upperBound - kind.yRange.lowerBound) * seeded(seed, 0.82)
    }

    private func wrappedX(seed: Double, width: CGFloat, drift: Double) -> CGFloat {
        let raw = seeded(seed, 0.71) * width + drift
        let wrapped = raw.truncatingRemainder(dividingBy: width)
        return CGFloat(wrapped < 0 ? wrapped + width : wrapped) - width * 0.22
    }

    private func seeded(_ seed: Double, _ salt: Double) -> Double {
        WeatherSeed.value(seed, salt)
    }
}

struct CloudBank: View {
    let variant: CloudVariant
    let seed: Double
    let opacity: Double
    let night: Bool
    let showDebugOutlines: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let specs = lobeSpecs(in: size)

            ZStack {
                ForEach(specs.indices, id: \.self) { index in
                    CloudLobe(spec: specs[index])
                        .fill(shadowFill)
                        .offset(x: 0, y: size.height * (0.06 + Double(index % 3) * 0.006))
                }

                CloudBaseShape(variant: variant)
                    .fill(shadowFill)
                    .offset(y: size.height * 0.08)

                ForEach(specs.indices, id: \.self) { index in
                    CloudLobe(spec: specs[index])
                        .fill(highlightFill(for: index))
                }

                CloudBaseShape(variant: variant)
                    .fill(baseFill)
                    .offset(y: size.height * 0.02)

                if showDebugOutlines {
                    CloudBaseShape(variant: variant)
                        .stroke(.red.opacity(0.6), lineWidth: 1)
                    ForEach(specs.indices, id: \.self) { index in
                        CloudLobe(spec: specs[index])
                            .stroke(.orange.opacity(0.45), lineWidth: 1)
                    }
                }
            }
        }
        .compositingGroup()
    }

    private var baseFill: Color {
        night ? Color(red: 0.70, green: 0.76, blue: 0.90).opacity(0.58) : Color.white.opacity(0.76)
    }

    private var shadowFill: Color {
        night ? Color(red: 0.20, green: 0.25, blue: 0.40).opacity(0.32) : Color(red: 0.48, green: 0.57, blue: 0.65).opacity(0.30)
    }

    private func highlightFill(for index: Int) -> Color {
        let variance = 0.52 + WeatherSeed.value(seed + Double(index), 0.52) * 0.30
        return (night ? Color(red: 0.78, green: 0.83, blue: 0.96) : Color.white).opacity(variance)
    }

    private func lobeSpecs(in size: CGSize) -> [CloudLobeSpec] {
        (0..<variant.lobeCount).map { index in
            let i = Double(index)
            let t = i / Double(max(variant.lobeCount - 1, 1))
            let localSeed = seed + i * 13.37
            let x = size.width * (-0.06 + t * 0.98 + (WeatherSeed.value(localSeed, 0.11) - 0.5) * 0.08)
            let centerBias = 1 - abs(t - 0.48) * 1.5
            let y = size.height * (0.48 - centerBias * (0.12 + WeatherSeed.value(localSeed, 0.22) * 0.18) + WeatherSeed.value(localSeed, 0.31) * 0.08)
            let w: CGFloat
            let h: CGFloat
            switch variant {
            case .largeLow:
                w = size.width * CGFloat(0.20 + WeatherSeed.value(localSeed, 0.41) * 0.16)
                h = size.height * CGFloat(0.60 + WeatherSeed.value(localSeed, 0.51) * 0.58)
            case .mediumCluster:
                w = size.width * CGFloat(0.18 + WeatherSeed.value(localSeed, 0.41) * 0.18)
                h = size.height * CGFloat(0.58 + WeatherSeed.value(localSeed, 0.51) * 0.62)
            case .wispy:
                w = size.width * CGFloat(0.18 + WeatherSeed.value(localSeed, 0.41) * 0.18)
                h = size.height * CGFloat(0.32 + WeatherSeed.value(localSeed, 0.51) * 0.34)
            case .distantStrip:
                w = size.width * CGFloat(0.22 + WeatherSeed.value(localSeed, 0.41) * 0.20)
                h = size.height * CGFloat(0.28 + WeatherSeed.value(localSeed, 0.51) * 0.26)
            }
            return CloudLobeSpec(center: CGPoint(x: x, y: y), size: CGSize(width: w, height: h))
        }
    }
}

struct CloudLobe: Shape {
    let spec: CloudLobeSpec

    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(
            x: spec.center.x - spec.size.width / 2,
            y: spec.center.y - spec.size.height / 2,
            width: spec.size.width,
            height: spec.size.height
        ))
    }
}

struct CloudLobeSpec {
    let center: CGPoint
    let size: CGSize
}

private struct CloudBaseShape: Shape {
    let variant: CloudVariant

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y: CGFloat
        let height: CGFloat
        switch variant {
        case .largeLow:
            y = rect.height * 0.48
            height = rect.height * 0.46
        case .mediumCluster:
            y = rect.height * 0.50
            height = rect.height * 0.40
        case .wispy:
            y = rect.height * 0.55
            height = rect.height * 0.28
        case .distantStrip:
            y = rect.height * 0.58
            height = rect.height * 0.22
        }
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: y, width: rect.width, height: height),
            cornerSize: CGSize(width: height * 0.55, height: height * 0.55)
        )
        return path
    }
}

private struct FogMistLayer: View {
    let state: WeatherRenderState
    let date: Date

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard state.fogAmount > 0.01 else { return }
            var context = context
            let time = state.motionTime(date, scale: 0.055)
            for layer in 0..<5 {
                let depth = Double(layer) / 4
                let speed = (12 + depth * 18 + state.windSpeed * 1.2) * (layer.isMultiple(of: 2) ? 1 : -1)
                let offset = CGFloat(sin(time * (0.25 + depth * 0.08) + depth * 4) * 28 + time * speed.truncatingRemainder(dividingBy: 28))
                let height = CGFloat(44 + depth * 34)
                let y = size.height * (0.34 + depth * 0.12)
                let rect = CGRect(x: -size.width * 0.30 + offset, y: y, width: size.width * 1.62, height: height)
                context.addFilter(.blur(radius: 22 + depth * 18))
                context.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(Color.white.opacity(state.fogAmount * (0.07 + depth * 0.035))))
                context.addFilter(.blur(radius: 0))
            }
        }
        .drawingGroup()
    }
}

private struct PrecipitationLayer: View {
    let depth: PrecipitationDepth
    let state: WeatherRenderState
    let date: Date

    var body: some View {
        Canvas(opaque: false) { context, size in
            var context = context
            drawRain(in: &context, size: size)
            drawSnow(in: &context, size: size)
        }
        .drawingGroup()
    }

    private func drawRain(in context: inout GraphicsContext, size: CGSize) {
        guard state.rainAmount > 0.01 else { return }
        let foreground = depth == .front
        let amount = state.rainAmount
        let count = foreground ? Int(70 + amount * 190) : Int(45 + amount * 130)
        let time = state.motionTime(date, scale: 1)
        let laneHeight = size.height + 120
        let laneWidth = size.width + 180

        for index in 0..<count {
            let seed = Double(index + (foreground ? 900 : 700))
            let layerDepth = foreground ? 0.85 + WeatherSeed.value(seed, 0.28) * 0.55 : 0.35 + WeatherSeed.value(seed, 0.28) * 0.42
            let speed = (360 + WeatherSeed.value(seed, 0.3) * 520) * layerDepth
            let wind = 34 + state.windSpeed * 8
            let rawX = WeatherSeed.value(seed, 0.17) * laneWidth - 90 - time * wind
            let x = wrapped(rawX, laneWidth) - 30
            let y = wrapped(WeatherSeed.value(seed, 0.91) * laneHeight + time * speed, laneHeight) - 70
            let length = (foreground ? 28 : 18) + WeatherSeed.value(seed, 0.57) * (foreground ? 46 : 28)
            let opacity = (foreground ? 0.22 : 0.12) + amount * (foreground ? 0.42 : 0.26)
            let lineWidth = foreground ? 1.15 + layerDepth * 0.7 : 0.65 + layerDepth * 0.38

            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - length * 0.34, y: y + length))
            context.stroke(path, with: .color(Color.white.opacity(opacity * layerDepth)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }

    private func drawSnow(in context: inout GraphicsContext, size: CGSize) {
        guard state.snowAmount > 0.01 else { return }
        let foreground = depth == .front
        let amount = state.snowAmount
        let count = foreground ? Int(34 + amount * 120) : Int(26 + amount * 80)
        let time = state.motionTime(date, scale: 1)

        for index in 0..<count {
            let seed = Double(index + (foreground ? 1200 : 1000))
            let layerDepth = foreground ? 0.7 + WeatherSeed.value(seed, 0.2) * 0.7 : 0.35 + WeatherSeed.value(seed, 0.2) * 0.45
            let speed = (20 + WeatherSeed.value(seed, 0.3) * 48) * layerDepth
            let wobble = sin(time * (0.36 + WeatherSeed.value(seed, 0.41) * 0.44) + seed) * (10 + layerDepth * 18)
            let x = wrapped(WeatherSeed.value(seed, 0.17) * (size.width + 70) + wobble + time * state.windSpeed * 2.0, size.width + 70) - 35
            let y = wrapped(WeatherSeed.value(seed, 0.91) * (size.height + 80) + time * speed, size.height + 80) - 40
            let radius = (foreground ? 1.6 : 0.9) + WeatherSeed.value(seed, 0.5) * (foreground ? 3.4 : 2.0)
            context.addFilter(.blur(radius: 0.35 + layerDepth * 0.55))
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)), with: .color(Color.white.opacity((0.26 + layerDepth * 0.38) * amount)))
            context.addFilter(.blur(radius: 0))
        }
    }

    private func wrapped(_ value: Double, _ length: CGFloat) -> CGFloat {
        let length = Double(length)
        let wrapped = value.truncatingRemainder(dividingBy: length)
        return CGFloat(wrapped < 0 ? wrapped + length : wrapped)
    }
}

private struct ForegroundAtmosphereLayer: View {
    let state: WeatherRenderState
    let date: Date

    var body: some View {
        Canvas(opaque: false) { context, size in
            var context = context
            let time = state.motionTime(date, scale: 0.22)
            let amount = (state.fogAmount * 0.35 + state.rainAmount * 0.18 + state.snowAmount * 0.22).clamped(to: 0...0.55)
            guard amount > 0.01 else { return }

            for index in 0..<28 {
                let seed = Double(index + 1500)
                let x = wrapped(WeatherSeed.value(seed, 0.1) * (size.width + 80) + time * (8 + state.windSpeed), size.width + 80) - 40
                let y = size.height * (0.10 + WeatherSeed.value(seed, 0.8) * 0.62)
                let radius = CGFloat(8 + WeatherSeed.value(seed, 0.4) * 22)
                context.addFilter(.blur(radius: radius * 0.65))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius * 0.55)), with: .color(Color.white.opacity(amount * 0.055)))
                context.addFilter(.blur(radius: 0))
            }
        }
    }

    private func wrapped(_ value: Double, _ length: CGFloat) -> CGFloat {
        let length = Double(length)
        let wrapped = value.truncatingRemainder(dividingBy: length)
        return CGFloat(wrapped < 0 ? wrapped + length : wrapped)
    }
}

private struct LightningLayer: View {
    let state: WeatherRenderState
    let date: Date

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard state.stormIntensity > 0.05, !state.reduceMotion else { return }
            let time = state.motionTime(date, scale: 1)
            let cycle = (time + 1.7).truncatingRemainder(dividingBy: 8.7)
            guard cycle < 0.10 + state.stormIntensity * 0.05 else { return }
            var context = context
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.13 + state.stormIntensity * 0.18)))

            var bolt = Path()
            let origin = CGPoint(x: size.width * (0.56 + WeatherSeed.value(cycle, 0.2) * 0.28), y: -8)
            bolt.move(to: origin)
            bolt.addLine(to: CGPoint(x: origin.x - 18, y: size.height * 0.14))
            bolt.addLine(to: CGPoint(x: origin.x - 4, y: size.height * 0.14))
            bolt.addLine(to: CGPoint(x: origin.x - 38, y: size.height * 0.30))
            bolt.addLine(to: CGPoint(x: origin.x - 24, y: size.height * 0.29))
            bolt.addLine(to: CGPoint(x: origin.x - 66, y: size.height * 0.48))
            context.addFilter(.blur(radius: 0.7))
            context.stroke(bolt, with: .color(.white.opacity(0.58)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            context.addFilter(.blur(radius: 0))
        }
    }
}

struct WeatherRenderState {
    let skyPalette: [RGBColor]
    let horizonPalette: [RGBColor]
    let cloudOpacity: Double
    let cloudDensity: Double
    let rainAmount: Double
    let snowAmount: Double
    let fogAmount: Double
    let starOpacity: Double
    let sunMoonProgress: Double
    let goldenHourProgress: Double
    let stormIntensity: Double
    let isNight: Bool
    let windSpeed: Double
    let reduceMotion: Bool
    let movementScale: Double
    let debugOptions: WeatherDebugOptions
    let sunMoonColor: RGBColor

    init(weather: WeatherData, date: Date, reduceMotion: Bool, debugOptions: WeatherDebugOptions) {
        let code = weather.weatherCode.lowercased()
        let cloud = weather.cloudCover.clamped(to: 0...1)
        let normalizedPrecip = weather.precipitationIntensity.clamped(to: 0...5) / 5
        let thunder = code.contains("thunder") || code.contains("storm") || code.contains("hurricane")
        let snow = code.contains("snow") || code.contains("sleet") || code.contains("flurr") || code.contains("wintry")
        let rain = code.contains("rain") || code.contains("drizzle") || code.contains("shower") || normalizedPrecip > 0.03 || debugOptions.forceRainVisible
        let fog = code.contains("fog") || code.contains("haze") || code.contains("smok") || code.contains("dust")
        let golden = Self.goldenProgress(weather: weather, date: date)
        let nightAmount = 1 - weather.daylightBlend
        let overcast = max(cloud - 0.42, 0) / 0.58
        let storm = thunder ? max(0.48, normalizedPrecip) : 0

        let base = Self.palette(
            isDay: weather.isDay,
            golden: golden,
            overcast: overcast,
            rain: rain && !snow ? max(normalizedPrecip, 0.38) : 0,
            snow: snow ? max(normalizedPrecip, 0.34) : 0,
            fog: fog ? max(0.42, cloud) : 0,
            storm: storm
        )

        skyPalette = base.sky
        horizonPalette = base.horizon
        cloudDensity = max(debugOptions.forceCloudsVisible ? 0.72 : 0, max(cloud, fog ? 0.74 : 0))
        cloudOpacity = (0.10 + cloud * 0.62 + (rain ? 0.12 : 0) + (fog ? 0.16 : 0) + (debugOptions.forceCloudsVisible ? 0.32 : 0)).clamped(to: 0...0.88)
        rainAmount = rain && !snow ? max(normalizedPrecip, debugOptions.forceRainVisible ? 0.72 : 0.24) : 0
        snowAmount = snow ? max(normalizedPrecip, 0.34) : 0
        fogAmount = ((fog ? 0.62 : 0) + overcast * 0.14 + (rain ? 0.14 : 0) + (snow ? 0.08 : 0)).clamped(to: 0...0.78)
        starOpacity = (!weather.isDay ? (1 - cloud * 0.72) : 0) * (1 - golden * 0.82) * (1 - storm * 0.8)
        sunMoonProgress = Self.sunProgress(weather: weather, date: date)
        goldenHourProgress = golden
        stormIntensity = storm
        isNight = nightAmount > 0.55 && golden < 0.35
        windSpeed = (weather.windSpeed ?? 2.5).clamped(to: 0...18)
        self.reduceMotion = reduceMotion
        movementScale = reduceMotion ? 0.08 : debugOptions.animationSpeedMultiplier.clamped(to: 0...12)
        self.debugOptions = debugOptions
        sunMoonColor = isNight
            ? RGBColor(0.74, 0.84, 0.98)
            : RGBColor(1.0, 0.88, 0.54).blended(with: RGBColor(1.0, 0.47, 0.20), amount: golden)
    }

    func motionTime(_ date: Date, scale: Double) -> Double {
        date.timeIntervalSinceReferenceDate * scale * movementScale
    }

    func sunMoonPosition(in size: CGSize) -> CGPoint {
        let p = sunMoonProgress.clamped(to: 0...1)
        if isNight {
            return CGPoint(x: size.width * (0.22 + p * 0.62), y: size.height * (0.20 + sin(p * .pi) * 0.06))
        }
        let goldenY = 0.42 - goldenHourProgress * 0.08
        let dayY = 0.43 - sin(p * .pi) * 0.30
        return CGPoint(x: size.width * (0.10 + p * 0.80), y: size.height * (goldenHourProgress > 0.05 ? goldenY : dayY))
    }

    private static func sunProgress(weather: WeatherData, date: Date) -> Double {
        guard let sunrise = weather.sunrise, let sunset = weather.sunset else {
            let hour = Calendar.current.component(.hour, from: date)
            return (Double(hour) / 24).clamped(to: 0...1)
        }
        if weather.isDay {
            let span = max(1, sunset.timeIntervalSince(sunrise))
            return (date.timeIntervalSince(sunrise) / span).clamped(to: 0...1)
        }
        let start: Date
        let end: Date
        if date < sunrise {
            start = sunset.addingTimeInterval(-24 * 3600)
            end = sunrise
        } else {
            start = sunset
            end = sunrise.addingTimeInterval(24 * 3600)
        }
        let span = max(1, end.timeIntervalSince(start))
        return (date.timeIntervalSince(start) / span).clamped(to: 0...1)
    }

    private static func goldenProgress(weather: WeatherData, date: Date) -> Double {
        let window: TimeInterval = 100 * 60
        let sunrise = weather.sunrise.map { max(0, 1 - abs(date.timeIntervalSince($0)) / window) } ?? 0
        let sunset = weather.sunset.map { max(0, 1 - abs(date.timeIntervalSince($0)) / window) } ?? 0
        return max(sunrise, sunset).clamped(to: 0...1)
    }

    private static func palette(
        isDay: Bool,
        golden: Double,
        overcast: Double,
        rain: Double,
        snow: Double,
        fog: Double,
        storm: Double
    ) -> (sky: [RGBColor], horizon: [RGBColor]) {
        let clearDay = [
            RGBColor(0.08, 0.30, 0.56), RGBColor(0.16, 0.46, 0.73), RGBColor(0.42, 0.68, 0.86),
            RGBColor(0.15, 0.40, 0.66), RGBColor(0.42, 0.66, 0.82), RGBColor(0.71, 0.84, 0.90),
            RGBColor(0.60, 0.76, 0.84), RGBColor(0.77, 0.87, 0.89), RGBColor(0.91, 0.91, 0.84)
        ]
        let night = [
            RGBColor(0.01, 0.03, 0.09), RGBColor(0.03, 0.05, 0.13), RGBColor(0.06, 0.05, 0.14),
            RGBColor(0.03, 0.06, 0.14), RGBColor(0.05, 0.08, 0.18), RGBColor(0.10, 0.10, 0.19),
            RGBColor(0.08, 0.10, 0.18), RGBColor(0.12, 0.13, 0.22), RGBColor(0.18, 0.16, 0.26)
        ]
        let sunset = [
            RGBColor(0.10, 0.13, 0.31), RGBColor(0.24, 0.22, 0.42), RGBColor(0.40, 0.27, 0.42),
            RGBColor(0.64, 0.32, 0.34), RGBColor(0.86, 0.48, 0.30), RGBColor(0.96, 0.65, 0.38),
            RGBColor(0.98, 0.68, 0.44), RGBColor(0.89, 0.73, 0.55), RGBColor(0.54, 0.42, 0.61)
        ]
        let overcastPalette = [
            RGBColor(0.25, 0.34, 0.45), RGBColor(0.32, 0.41, 0.51), RGBColor(0.42, 0.50, 0.58),
            RGBColor(0.38, 0.46, 0.55), RGBColor(0.49, 0.56, 0.62), RGBColor(0.60, 0.65, 0.67),
            RGBColor(0.61, 0.66, 0.68), RGBColor(0.70, 0.72, 0.71), RGBColor(0.75, 0.75, 0.71)
        ]
        let rainPalette = [
            RGBColor(0.07, 0.13, 0.21), RGBColor(0.12, 0.20, 0.30), RGBColor(0.19, 0.28, 0.38),
            RGBColor(0.15, 0.23, 0.32), RGBColor(0.24, 0.33, 0.41), RGBColor(0.35, 0.42, 0.47),
            RGBColor(0.34, 0.40, 0.44), RGBColor(0.44, 0.48, 0.49), RGBColor(0.55, 0.55, 0.52)
        ]
        let snowPalette = [
            RGBColor(0.42, 0.55, 0.66), RGBColor(0.55, 0.67, 0.76), RGBColor(0.72, 0.80, 0.86),
            RGBColor(0.64, 0.73, 0.80), RGBColor(0.79, 0.85, 0.89), RGBColor(0.90, 0.93, 0.95),
            RGBColor(0.86, 0.90, 0.92), RGBColor(0.93, 0.95, 0.95), RGBColor(0.98, 0.97, 0.93)
        ]
        let fogPalette = [
            RGBColor(0.44, 0.50, 0.54), RGBColor(0.54, 0.59, 0.61), RGBColor(0.64, 0.67, 0.67),
            RGBColor(0.61, 0.64, 0.64), RGBColor(0.71, 0.73, 0.71), RGBColor(0.79, 0.79, 0.75),
            RGBColor(0.75, 0.76, 0.73), RGBColor(0.83, 0.83, 0.79), RGBColor(0.87, 0.85, 0.79)
        ]

        var palette = isDay ? clearDay : night
        palette = blend(palette, with: sunset, amount: golden)
        palette = blend(palette, with: overcastPalette, amount: overcast)
        palette = blend(palette, with: rainPalette, amount: rain)
        palette = blend(palette, with: snowPalette, amount: snow)
        palette = blend(palette, with: fogPalette, amount: fog)
        palette = blend(palette, with: rainPalette, amount: storm)
        return (palette, [palette[0], palette[4], palette[8]])
    }

    private static func blend(_ lhs: [RGBColor], with rhs: [RGBColor], amount: Double) -> [RGBColor] {
        zip(lhs, rhs).map { $0.blended(with: $1, amount: amount.clamped(to: 0...1)) }
    }
}

struct RGBColor: Equatable {
    let r: Double
    let g: Double
    let b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    var color: Color {
        Color(red: r, green: g, blue: b)
    }

    func blended(with other: RGBColor, amount: Double) -> RGBColor {
        let t = amount.clamped(to: 0...1)
        return RGBColor(
            r + (other.r - r) * t,
            g + (other.g - g) * t,
            b + (other.b - b) * t
        )
    }
}

enum WeatherDebugCondition: String, CaseIterable, Identifiable {
    case clear
    case partlyCloudy
    case cloudy
    case rain
    case heavyRain
    case snow
    case foggy
    case thunderstorms

    var id: String { rawValue }
    var weatherCode: String {
        switch self {
        case .heavyRain: "heavyRain"
        default: rawValue
        }
    }
}

struct WeatherBackgroundDebugControlsView: View {
    @State private var cloudCover = 0.28
    @State private var precipitation = 0.0
    @State private var isDay = true
    @State private var condition = WeatherDebugCondition.clear
    @State private var timeOfDay = 0.50
    @State private var windSpeed = 4.0
    @State private var animationSpeedMultiplier = 1.0
    @State private var showLayerDebugOutlines = false
    @State private var forceRainVisible = false
    @State private var forceSunVisible = false
    @State private var forceCloudsVisible = false
    @State private var controlsExpanded = true
    @State private var previewFullscreen = false

    private let sunrise = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: Date())!
    private let sunset = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    WeatherBackgroundView(weather: weather, debugOptions: debugOptions)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: previewFullscreen ? 0 : 28, style: .continuous))
                        .overlay {
                            if !previewFullscreen {
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                            }
                        }

                    Button {
                        withAnimation(.snappy) {
                            previewFullscreen.toggle()
                            if previewFullscreen {
                                controlsExpanded = false
                            }
                        }
                    } label: {
                        Image(systemName: previewFullscreen ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                            .font(.callout.weight(.semibold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .accessibilityLabel(previewFullscreen ? "Exit fullscreen preview" : "Fullscreen preview")
                }
                .padding(previewFullscreen ? 0 : 14)
                .frame(height: previewFullscreen ? proxy.size.height : max(330, proxy.size.height * 0.54))

                if !previewFullscreen {
                    controlsDrawer
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color(.systemGroupedBackground))
            .ignoresSafeArea(edges: previewFullscreen ? .all : [])
        }
    }

    private var controlsDrawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    controlsExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Controls")
                            .font(.headline)
                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: controlsExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if controlsExpanded {
                ScrollView {
                    VStack(spacing: 14) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(WeatherDebugCondition.allCases) { item in
                                    Button {
                                        condition = item
                                    } label: {
                                        Text(item.rawValue.displayTitle)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(
                                                condition == item ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.10),
                                                in: Capsule()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Toggle("Daylight", isOn: $isDay)
                                Toggle("Outlines", isOn: $showLayerDebugOutlines)
                            }
                            GridRow {
                                Toggle("Rain", isOn: $forceRainVisible)
                                Toggle("Sun", isOn: $forceSunVisible)
                            }
                            GridRow {
                                Toggle("Clouds", isOn: $forceCloudsVisible)
                                Color.clear
                            }
                        }
                        .font(.caption)

                        slider("Animation speed", value: $animationSpeedMultiplier, range: 0...12)
                        slider("Cloud cover", value: $cloudCover, range: 0...1)
                        slider("Precipitation", value: $precipitation, range: 0...5)
                        slider("Time of day", value: $timeOfDay, range: 0...1)
                        slider("Wind speed", value: $windSpeed, range: 0...18)
                    }
                    .font(.caption)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .frame(maxHeight: 310)
            }
        }
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .shadow(color: .black.opacity(0.14), radius: 18, y: -6)
    }

    private var summaryText: String {
        "\(condition.rawValue.displayTitle), clouds \(cloudCover.formatted(.number.precision(.fractionLength(2)))), precip \(precipitation.formatted(.number.precision(.fractionLength(2))))"
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
            Slider(value: value, in: range)
        }
    }

    private var debugOptions: WeatherDebugOptions {
        WeatherDebugOptions(
            animationSpeedMultiplier: animationSpeedMultiplier,
            showLayerDebugOutlines: showLayerDebugOutlines,
            forceRainVisible: forceRainVisible,
            forceSunVisible: forceSunVisible,
            forceCloudsVisible: forceCloudsVisible
        )
    }

    private var weather: WeatherData {
        let date = sunrise.addingTimeInterval(sunset.timeIntervalSince(sunrise) * timeOfDay)
        return WeatherData(
            weatherCode: condition.weatherCode,
            cloudCover: cloudCover,
            precipitationIntensity: condition == .heavyRain ? max(precipitation, 1.0) : precipitation,
            isDay: isDay,
            sunrise: sunrise,
            sunset: sunset,
            date: date,
            locationName: "Preview",
            windSpeed: windSpeed
        )
    }
}

enum WeatherSeed {
    static func value(_ seed: Double, _ salt: Double) -> Double {
        abs(sin(seed * 12.9898 + salt * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
    }
}

#Preview("Weather Debug Controls") {
    WeatherBackgroundDebugControlsView()
}

#Preview("Clear Day Visible Sun") {
    WeatherBackgroundView(weather: .preview(code: "clear", cloud: 0.08, precip: 0, hour: 13, isDay: true), debugOptions: .sunTest)
}

#Preview("Partly Cloudy Day") {
    WeatherBackgroundView(weather: .preview(code: "partlyCloudy", cloud: 0.42, precip: 0, hour: 14, isDay: true))
}

#Preview("Overcast") {
    WeatherBackgroundView(weather: .preview(code: "cloudy", cloud: 0.92, precip: 0, hour: 14, isDay: true))
}

#Preview("Light Rain") {
    WeatherBackgroundView(weather: .preview(code: "rain", cloud: 0.82, precip: 0.7, hour: 15, isDay: true))
}

#Preview("Heavy Rain") {
    WeatherBackgroundView(weather: .preview(code: "heavyRain", cloud: 0.94, precip: 1.0, hour: 15, isDay: true), debugOptions: .rainTest)
}

#Preview("Sunset With Clouds") {
    WeatherBackgroundView(weather: .preview(code: "partlyCloudy", cloud: 0.52, precip: 0, hour: 19, isDay: true))
}

#Preview("Night Stars Moon") {
    WeatherBackgroundView(weather: .preview(code: "clear", cloud: 0.12, precip: 0, hour: 23, isDay: false), debugOptions: .sunTest)
}

#Preview("Snow") {
    WeatherBackgroundView(weather: .preview(code: "snow", cloud: 0.78, precip: 1.5, hour: 12, isDay: true))
}

#Preview("Fog") {
    WeatherBackgroundView(weather: .preview(code: "foggy", cloud: 0.86, precip: 0, hour: 9, isDay: true))
}

#Preview("Thunderstorm") {
    WeatherBackgroundView(weather: .preview(code: "thunderstorms", cloud: 0.95, precip: 3.7, hour: 18, isDay: true))
}

#Preview("Visible Sun Test") {
    WeatherBackgroundView(weather: .preview(code: "clear", cloud: 0.35, precip: 0, hour: 12, isDay: true), debugOptions: .sunTest)
}

private extension WeatherDebugOptions {
    static let rainTest = WeatherDebugOptions(animationSpeedMultiplier: 2.5, forceRainVisible: true)
    static let sunTest = WeatherDebugOptions(animationSpeedMultiplier: 1, forceSunVisible: true, forceCloudsVisible: false)
}

private extension WeatherData {
    static func preview(code: String, cloud: Double, precip: Double, hour: Int, isDay: Bool) -> WeatherData {
        let calendar = Calendar.current
        let base = Date()
        let sunrise = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: base)
        let sunset = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: base)
        return WeatherData(
            weatherCode: code,
            cloudCover: cloud,
            precipitationIntensity: precip,
            isDay: isDay,
            sunrise: sunrise,
            sunset: sunset,
            date: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base,
            locationName: "Preview",
            windSpeed: 4
        )
    }
}

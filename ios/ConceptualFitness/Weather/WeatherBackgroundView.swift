import SwiftUI

struct WeatherBackgroundView: View {
    var weather: WeatherData
    var debugOptions: WeatherDebugOptions = .live

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = renderState(at: Date())

        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { timeline in
                SkyLayer(state: renderState(at: timeline.date), date: timeline.date)
            }

            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                WeatherSceneView(spec: WeatherSceneSpec(state: renderState(at: timeline.date)))
            }

            if state.stormIntensity > 0.05, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    LightningLayer(state: state, date: timeline.date)
                }
            }
        }
        .compositingGroup()
        .overlay(alignment: .bottom) {
            let rainy = state.rainAmount > 0.05 || state.stormIntensity > 0.05
            LinearGradient(
                colors: [
                    .clear,
                    state.bottomAtmosphereColor.color.opacity(state.isNight ? 0.24 : (rainy ? 0.30 : 0.50)),
                    HealthTheme.page.opacity(state.isNight ? 0.98 : (rainy ? 0.94 : 0.98))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .top)
    }

    private func renderState(at date: Date) -> WeatherRenderState {
        WeatherRenderState(
            weather: weather,
            date: debugOptions.useWeatherDateForTime ? weather.date : date,
            reduceMotion: reduceMotion,
            debugOptions: debugOptions
        )
    }
}

struct WeatherDebugOptions: Equatable {
    var animationSpeedMultiplier: Double = 1.8
    var useWeatherDateForTime = false

    static let live = WeatherDebugOptions()
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

private struct LightningLayer: View {
    let state: WeatherRenderState
    let date: Date

    private static let slotLength = 2.4

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard state.stormIntensity > 0.05, !state.reduceMotion else { return }
            let time = date.timeIntervalSinceReferenceDate
            let currentSlot = (time / Self.slotLength).rounded(.down)
            draw(slot: currentSlot - 1, time: time, in: context, size: size)
            draw(slot: currentSlot, time: time, in: context, size: size)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }

    private func draw(slot: Double, time: Double, in context: GraphicsContext, size: CGSize) {
        let seed = slot.truncatingRemainder(dividingBy: 9973)
        guard WeatherSeed.value(seed, 0.31) < 0.30 + state.stormIntensity * 0.45 else { return }
        let age = time - (slot * Self.slotLength + WeatherSeed.value(seed, 0.47) * 1.5)
        guard age >= 0, age < 0.75 else { return }

        var envelope = exp(-age / 0.05)
        if age >= 0.11 { envelope = max(envelope, 0.75 * exp(-(age - 0.11) / 0.06)) }
        if age >= 0.26 { envelope = max(envelope, 0.5 * exp(-(age - 0.26) / 0.14)) }

        let origin = CGPoint(x: size.width * (0.18 + WeatherSeed.value(seed, 0.59) * 0.64), y: -10)
        let flash = Color(red: 0.82, green: 0.90, blue: 1.0)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [
                    flash.opacity(envelope * (0.34 + 0.22 * state.stormIntensity)),
                    flash.opacity(envelope * 0.08)
                ]),
                center: origin,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.95
            )
        )

        guard WeatherSeed.value(seed, 0.73) < 0.6 else { return }
        let end = CGPoint(
            x: origin.x + size.width * (WeatherSeed.value(seed, 0.83) - 0.5) * 0.4,
            y: size.height * (0.36 + WeatherSeed.value(seed, 0.91) * 0.20)
        )
        let main = jagged(from: origin, to: end, passes: 5, seed: seed)
        var branches = Path()
        let branchCount = 2 + Int(WeatherSeed.value(seed, 0.17) * 2)

        for branch in 0..<branchCount {
            let branchSeed = seed + Double(branch + 1) * 3.7
            let start = main[Int(Double(main.count - 1) * (0.25 + WeatherSeed.value(branchSeed, 0.2) * 0.45))]
            let remaining = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let scale = 0.28 + WeatherSeed.value(branchSeed, 0.4) * 0.14
            let angle = (0.35 + WeatherSeed.value(branchSeed, 0.6) * 0.44) * (branch.isMultiple(of: 2) ? 1 : -1)
            let tip = CGPoint(
                x: start.x + (remaining.x * cos(angle) - remaining.y * sin(angle)) * scale,
                y: start.y + (remaining.x * sin(angle) + remaining.y * cos(angle)) * scale
            )
            branches.addPath(path(through: jagged(from: start, to: tip, passes: 3, seed: branchSeed)))
        }

        stroke(branches, in: context, scale: 0.55, intensity: envelope * 0.55)
        stroke(path(through: main), in: context, scale: 1, intensity: envelope)
    }

    private func stroke(_ path: Path, in context: GraphicsContext, scale: Double, intensity: Double) {
        var glow = context
        glow.addFilter(.blur(radius: 9))
        glow.stroke(
            path,
            with: .color(Color(red: 0.62, green: 0.80, blue: 1.0).opacity(0.40 * intensity)),
            style: StrokeStyle(lineWidth: 7 * scale, lineCap: .round, lineJoin: .round)
        )
        var body = context
        body.addFilter(.blur(radius: 1.5))
        body.stroke(
            path,
            with: .color(Color.white.opacity(0.75 * intensity)),
            style: StrokeStyle(lineWidth: 2.4 * scale, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(Color.white.opacity(intensity)),
            style: StrokeStyle(lineWidth: 1.1 * scale, lineCap: .round, lineJoin: .round)
        )
    }

    private func path(through points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func jagged(from start: CGPoint, to end: CGPoint, passes: Int, seed: Double) -> [CGPoint] {
        var points = [start, end]
        for pass in 0..<passes {
            var next = [points[0]]
            for index in 1..<points.count {
                let a = points[index - 1]
                let b = points[index]
                let offset = (WeatherSeed.value(seed + Double(pass) * 17.3 + Double(index) * 1.31, 0.66) - 0.5) * 0.40
                next.append(CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * offset, y: (a.y + b.y) / 2 + (b.x - a.x) * offset))
                next.append(b)
            }
            points = next
        }
        return points
    }
}

struct WeatherRenderState {
    let skyPalette: [RGBColor]
    let horizonPalette: [RGBColor]
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
    let sunVisibility: Double
    let bottomAtmosphereColor: RGBColor
    let reduceMotion: Bool
    let movementScale: Double
    let sunMoonColor: RGBColor

    init(weather: WeatherData, date: Date, reduceMotion: Bool, debugOptions: WeatherDebugOptions) {
        let code = weather.weatherCode.lowercased()
        let cloud = weather.cloudCover.clamped(to: 0...1)
        let normalizedPrecip = weather.precipitationIntensity.clamped(to: 0...5) / 5
        let thunder = code.contains("thunder") || code.contains("storm") || code.contains("hurricane")
        let snow = code.contains("snow") || code.contains("sleet") || code.contains("flurr") || code.contains("wintry")
        let rain = code.contains("rain") || code.contains("drizzle") || code.contains("shower") || thunder || normalizedPrecip > 0.03
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
        cloudDensity = max(cloud, fog ? 0.74 : 0)
        rainAmount = rain && !snow ? max(normalizedPrecip, 0.24) : 0
        snowAmount = snow ? max(normalizedPrecip, 0.52) : 0
        fogAmount = ((fog ? 0.62 : 0) + overcast * 0.14 + (rain ? 0.14 : 0) + (snow ? 0.08 : 0)).clamped(to: 0...0.78)
        starOpacity = (!weather.isDay ? (1 - cloud * 0.72) : 0) * (1 - golden * 0.82) * (1 - storm * 0.8)
        sunMoonProgress = Self.sunProgress(weather: weather, date: date)
        goldenHourProgress = golden
        stormIntensity = storm
        isNight = nightAmount > 0.55 && golden < 0.35
        windSpeed = (weather.windSpeed ?? 2.5).clamped(to: 0...18)
        sunVisibility = (1 - cloud * 0.78 - normalizedPrecip * 0.42 - storm * 0.72).clamped(to: 0.08...1)
        bottomAtmosphereColor = isNight
            ? RGBColor(0.04, 0.05, 0.10)
            : rain || thunder ? RGBColor(0.58, 0.64, 0.66) : RGBColor(0.97, 0.98, 0.96)
        self.reduceMotion = reduceMotion
        movementScale = reduceMotion ? 0.08 : debugOptions.animationSpeedMultiplier.clamped(to: 0...12)
        sunMoonColor = isNight
            ? RGBColor(0.74, 0.84, 0.98)
            : RGBColor(1.0, 0.88, 0.54).blended(with: RGBColor(1.0, 0.47, 0.20), amount: golden)
    }

    func motionTime(_ date: Date, scale: Double) -> Double {
        date.timeIntervalSinceReferenceDate * scale * movementScale
    }

    func sunMoonPosition(in size: CGSize) -> CGPoint {
        Self.celestialPoint(progress: sunMoonProgress, golden: goldenHourProgress, isNight: isNight, in: size)
    }

    static func celestialPoint(progress: Double, golden: Double, isNight: Bool, in size: CGSize) -> CGPoint {
        let p = progress.clamped(to: 0...1)
        let x = size.width * (isNight ? 0.20 + p * 0.60 : 0.14 + p * 0.72)
        let underIsland = exp(-pow((x / max(size.width, 1) - 0.5) / 0.16, 2))
        let arc = 1 - sin(p * .pi)
        let y: Double
        if isNight {
            y = 92 + arc * 40 + underIsland * 40
        } else if golden > 0.05 {
            y = 150 + golden * 40 + underIsland * 20
        } else {
            y = 80 + arc * 70 + underIsland * 44
        }
        return CGPoint(x: x, y: min(y, size.height * 0.6))
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
            RGBColor(0.06, 0.08, 0.22), RGBColor(0.16, 0.14, 0.32), RGBColor(0.30, 0.19, 0.34),
            RGBColor(0.50, 0.24, 0.29), RGBColor(0.72, 0.36, 0.24), RGBColor(0.84, 0.50, 0.29),
            RGBColor(0.85, 0.53, 0.33), RGBColor(0.74, 0.56, 0.43), RGBColor(0.42, 0.32, 0.49)
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
        let dim = isDay ? 1 : 0.34 + golden * 0.66
        let snowDim = isDay ? 1 : 0.42 + golden * 0.58
        palette = blend(palette, with: overcastPalette.map { $0.scaled(by: dim) }, amount: overcast)
        palette = blend(palette, with: rainPalette.map { $0.scaled(by: dim) }, amount: rain)
        palette = blend(palette, with: snowPalette.map { $0.scaled(by: snowDim) }, amount: snow)
        palette = blend(palette, with: fogPalette.map { $0.scaled(by: dim) }, amount: fog)
        palette = blend(palette, with: rainPalette.map { $0.scaled(by: dim) }, amount: storm)
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

    func scaled(by factor: Double) -> RGBColor {
        RGBColor(r * factor, g * factor, b * factor)
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

enum WeatherSeed {
    static func value(_ seed: Double, _ salt: Double) -> Double {
        abs(sin(seed * 12.9898 + salt * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
    }
}

#Preview("Clear day") {
    WeatherBackgroundView(weather: .preview(code: "clear", cloud: 0.04, precip: 0, hour: 13, isDay: true))
}

#Preview("Rain") {
    WeatherBackgroundView(weather: .preview(code: "rain", cloud: 0.85, precip: 1.2, hour: 15, isDay: true))
}

#Preview("Night") {
    WeatherBackgroundView(weather: .preview(code: "clear", cloud: 0.1, precip: 0, hour: 23, isDay: false))
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

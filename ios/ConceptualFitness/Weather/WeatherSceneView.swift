import SwiftUI
import UIKit

struct WeatherSceneSpec: Equatable {
    var isNight: Bool
    var golden: Double
    var sunVisibility: Double
    var sunProgress: Double
    var cloudCover: Double
    var rain: Double
    var snow: Double
    var fog: Double
    var stars: Double
    var wind: Double
    var storm: Double
    var speed: Double

    init(state: WeatherRenderState) {
        func step(_ value: Double, _ size: Double = 0.05) -> Double {
            (value / size).rounded() * size
        }
        isNight = state.isNight
        golden = step(state.goldenHourProgress, 0.1)
        sunVisibility = step(state.sunVisibility)
        sunProgress = step(state.sunMoonProgress, 0.01)
        cloudCover = step(state.cloudDensity)
        rain = step(state.rainAmount)
        snow = step(state.snowAmount)
        fog = step(state.fogAmount)
        stars = step(state.starOpacity)
        wind = step(state.windSpeed, 0.5)
        storm = step(state.stormIntensity)
        speed = state.reduceMotion ? 0.25 : max(0.05, state.movementScale / 1.8)
    }

    var cloudTone: CloudTone {
        let wet = rain > 0 || snow > 0 || storm > 0 || fog > 0.5
        if isNight { return wet || cloudCover > 0.85 ? .nightGrey : .night }
        if storm > 0 { return .storm }
        if wet { return .grey }
        if cloudCover > 0.75 { return .overcast }
        if golden > 0.35 { return .sunset }
        return .day
    }
}

struct WeatherSceneView: UIViewRepresentable {
    let spec: WeatherSceneSpec

    func makeUIView(context: Context) -> WeatherSceneHostView {
        WeatherSceneHostView()
    }

    func updateUIView(_ view: WeatherSceneHostView, context: Context) {
        view.spec = spec
    }
}

final class WeatherSceneHostView: UIView {
    var spec: WeatherSceneSpec? {
        didSet {
            if spec != oldValue { setNeedsLayout() }
        }
    }

    private let starGroup = CALayer()
    private let sunGroup = CALayer()
    private let cloudGroup = CALayer()
    private let fogGroup = CALayer()
    private let precipitationGroup = CALayer()
    private var builtKeys: [ObjectIdentifier: AnyHashable] = [:]
    private var builtSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        for group in [starGroup, sunGroup, cloudGroup, fogGroup, precipitationGroup] {
            layer.addSublayer(group)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let spec, bounds.width > 1, bounds.height > 1 else { return }
        let size = bounds.size
        let resized = size != builtSize
        builtSize = size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.speed != Float(spec.speed) {
            layer.speed = Float(spec.speed)
        }
        for group in [starGroup, sunGroup, cloudGroup, fogGroup, precipitationGroup] {
            group.frame = bounds
        }
        rebuild(starGroup, key: [spec.isNight ? spec.stars : 0], resized: resized) {
            WeatherSceneBuilder.stars(in: $0, size: size, spec: spec)
        }
        rebuild(sunGroup, key: [spec.isNight ? 0 : spec.sunVisibility, spec.golden, spec.sunProgress], resized: resized) {
            WeatherSceneBuilder.sun(in: $0, size: size, spec: spec)
        }
        rebuild(cloudGroup, key: [spec.cloudCover, spec.wind, Double(spec.cloudTone.rawValue)], resized: resized) {
            WeatherSceneBuilder.clouds(in: $0, size: size, spec: spec)
        }
        rebuild(fogGroup, key: [spec.fog, spec.wind, spec.isNight ? 1 : 0], resized: resized) {
            WeatherSceneBuilder.fog(in: $0, size: size, spec: spec)
        }
        rebuild(precipitationGroup, key: [spec.rain, spec.snow, spec.wind, spec.isNight ? 1 : 0], resized: resized) {
            WeatherSceneBuilder.precipitation(in: $0, size: size, spec: spec)
        }
        CATransaction.commit()
    }

    private func rebuild(_ group: CALayer, key: [Double], resized: Bool, build: (CALayer) -> Void) {
        let id = ObjectIdentifier(group)
        guard resized || builtKeys[id] != AnyHashable(key) else { return }
        builtKeys[id] = AnyHashable(key)
        group.sublayers = nil
        build(group)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.9
        group.add(fade, forKey: "fadeIn")
    }
}

enum WeatherSceneBuilder {
    static func stars(in group: CALayer, size: CGSize, spec: WeatherSceneSpec) {
        guard spec.stars > 0.02 else { return }
        group.opacity = Float(spec.stars)
        let fieldSize = CGSize(width: size.width, height: size.height * 0.78)
        let periods = [5.3, 7.9, 10.6]

        for (index, period) in periods.enumerated() {
            let field = CALayer()
            field.frame = CGRect(origin: .zero, size: fieldSize)
            field.contents = WeatherSprites.starField(size: fieldSize, seed: index)
            field.contentsScale = WeatherSprites.screenScale
            field.add(loop(keyframes("opacity", [0.45, 1, 0.65, 0.95, 0.45]), duration: period, phase: Double(index) * 0.3), forKey: "twinkle")
            group.addSublayer(field)
        }

        for index in 0..<5 {
            let seed = Double(index) + 41
            let star = CALayer()
            let side = 14.0 + WeatherSeed.value(seed, 0.2) * 6
            star.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            star.position = CGPoint(
                x: size.width * (0.08 + WeatherSeed.value(seed, 0.4) * 0.84),
                y: size.height * (0.06 + WeatherSeed.value(seed, 0.6) * 0.42)
            )
            star.contents = WeatherSprites.brightStar
            star.add(loop(keyframes("opacity", [0.35, 1, 0.55, 0.9, 0.35]), duration: 3.2 + WeatherSeed.value(seed, 0.8) * 3, phase: WeatherSeed.value(seed, 0.9)), forKey: "twinkle")
            group.addSublayer(star)
        }

        let span = hypot(size.width, size.height)
        let meteors = CAEmitterLayer()
        meteors.bounds = CGRect(x: 0, y: 0, width: span, height: span)
        meteors.position = CGPoint(x: size.width * 0.5, y: size.height * 0.3)
        meteors.transform = CATransform3DMakeRotation(.pi - WeatherSprites.meteorAngle, 0, 0, 1)
        meteors.emitterShape = .rectangle
        meteors.emitterPosition = CGPoint(x: span / 2, y: span / 2)
        meteors.emitterSize = CGSize(width: span * 0.5, height: size.height * 0.4)
        let meteor = CAEmitterCell()
        meteor.contents = WeatherSprites.meteor
        meteor.contentsScale = WeatherSprites.spriteScale
        meteor.birthRate = 1 / 22
        meteor.lifetime = 0.8
        meteor.velocity = 560
        meteor.alphaSpeed = -1.2
        meteor.scale = 1
        meteors.emitterCells = [meteor]
        group.addSublayer(meteors)
    }

    static func sun(in group: CALayer, size: CGSize, spec: WeatherSceneSpec) {
        guard !spec.isNight, spec.sunVisibility > 0.05 else { return }
        let unit = size.width / 402
        let center = WeatherRenderState.celestialPoint(progress: spec.sunProgress, golden: spec.golden, isNight: false, in: size)
        let warm = RGBColor(1.0, 0.95, 0.80).blended(with: RGBColor(1.0, 0.58, 0.28), amount: spec.golden)
        let visibility = spec.sunVisibility
        group.opacity = Float((visibility * 1.6).clamped(to: 0.35...1))
        group.compositingFilter = "screenBlendMode"

        let haze = radial(colors: [
            (warm, 0.38 + spec.golden * 0.2), (warm, 0.14 + spec.golden * 0.1), (warm, 0)
        ], locations: [0, 0.38, 1])
        let hazeRadius = 420 * unit * (1 + spec.golden * 0.35)
        haze.frame = CGRect(x: center.x - hazeRadius, y: center.y - hazeRadius, width: hazeRadius * 2, height: hazeRadius * 2)
        group.addSublayer(haze)

        let bloom = radial(colors: [
            (RGBColor(1, 1, 1), 0.95), (warm, 0.62), (warm, 0.24), (warm, 0.07), (warm, 0)
        ], locations: [0, 0.12, 0.32, 0.6, 1])
        let bloomRadius = 200 * unit * (1 + spec.golden * 0.25)
        bloom.frame = CGRect(x: center.x - bloomRadius, y: center.y - bloomRadius, width: bloomRadius * 2, height: bloomRadius * 2)
        bloom.add(loop(keyframes("transform.scale", [1, 1.035, 0.99, 1.02, 1]), duration: 9), forKey: "breathe")
        group.addSublayer(bloom)

        let rayColor = RGBColor(1, 0.98, 0.92).blended(with: warm, amount: 0.6)
        for (index, ring) in [(count: 9, length: 165.0, width: 30.0, period: 7.0, turn: 210.0), (count: 7, length: 115.0, width: 24.0, period: 5.4, turn: -160.0)].enumerated() {
            let replicator = CAReplicatorLayer()
            replicator.bounds = .zero
            replicator.position = center
            replicator.instanceCount = ring.count
            replicator.instanceTransform = CATransform3DMakeRotation(.pi * 2 / CGFloat(ring.count), 0, 0, 1)
            replicator.instanceDelay = ring.period / Double(ring.count) * 1.7
            replicator.transform = CATransform3DMakeRotation(CGFloat(index) * 0.31, 0, 0, 1)
            replicator.opacity = Float(0.42 + spec.golden * 0.15)

            let ray = CALayer()
            ray.bounds = CGRect(x: 0, y: 0, width: ring.width * unit, height: ring.length * unit)
            ray.anchorPoint = CGPoint(x: 0.5, y: 1)
            ray.position = .zero
            ray.contents = WeatherSprites.ray(color: rayColor)
            ray.add(loop(keyframes("opacity", [0.1, 0.85, 0.3, 0.7, 0.1]), duration: ring.period), forKey: "shimmer")
            ray.add(loop(keyframes("transform.scale.y", [0.82, 1.12, 0.92, 1.05, 0.82]), duration: ring.period * 1.3), forKey: "reach")
            replicator.addSublayer(ray)
            replicator.add(loop(rotation(from: CGFloat(index) * 0.31, turns: ring.turn > 0 ? 1 : -1), duration: abs(ring.turn)), forKey: "turn")
            group.addSublayer(replicator)
        }

        let core = radial(colors: [
            (RGBColor(1, 1, 0.97), 1), (RGBColor(1, 1, 0.95), 1), (RGBColor(1, 0.97, 0.86), 0.6), (warm, 0)
        ], locations: [0, 0.22, 0.38, 1])
        let coreRadius = 34 * unit
        core.frame = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
        group.addSublayer(core)

        let flare = CALayer()
        flare.frame = CGRect(origin: .zero, size: size)
        flare.opacity = Float((1 - spec.golden * 0.6) * visibility)
        let focus = CGPoint(x: size.width * 0.5, y: size.height * 0.62)
        let apertures: [(t: CGFloat, side: CGFloat, tint: RGBColor, alpha: Double)] = [
            (0.42, 16, RGBColor(0.70, 0.92, 1.0), 0.20),
            (0.68, 34, RGBColor(0.72, 1.0, 0.82), 0.12),
            (0.92, 11, RGBColor(1.0, 0.86, 0.62), 0.26),
            (1.22, 58, RGBColor(0.66, 0.80, 1.0), 0.09),
            (1.55, 24, RGBColor(1.0, 0.74, 0.90), 0.14)
        ]
        for aperture in apertures {
            let piece = CALayer()
            let side = aperture.side * unit
            piece.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            piece.position = CGPoint(x: center.x + (focus.x - center.x) * aperture.t, y: center.y + (focus.y - center.y) * aperture.t)
            piece.contents = WeatherSprites.aperture(tint: aperture.tint)
            piece.opacity = Float(aperture.alpha * 2.2)
            flare.addSublayer(piece)
        }
        flare.add(loop(keyframes("opacity", [flare.opacity * 0.6, flare.opacity, flare.opacity * 0.75, flare.opacity * 0.6]), duration: 6.5), forKey: "breathe")
        group.addSublayer(flare)
    }

    static func clouds(in group: CALayer, size: CGSize, spec: WeatherSceneSpec) {
        let cover = spec.cloudCover
        guard cover > 0.06 else { return }
        let unit = size.width / 402
        let tone = spec.cloudTone

        let heavy = spec.rain > 0 || spec.snow > 0 || spec.storm > 0
        let overcast = !heavy && cover > 0.75
        if cover > 0.6 {
            deck(in: group, size: size, tone: tone, amount: min(1, (cover - 0.6) / 0.3), wind: spec.wind)
        }

        let layers: [(count: Int, width: ClosedRange<Double>, y: ClosedRange<Double>, speed: Double, opacity: Double, salt: Double)] = [
            (Int((1 + cover * (overcast ? 4 : 3)).rounded()), overcast ? 220...300 : 150...210, 0.04...0.24, 3 + spec.wind * 0.45, heavy ? 0.55 : 0.8, 0.1),
            (Int((cover * (heavy ? 1.6 : overcast ? 4.4 : 3.2)).rounded()), overcast ? 300...380 : 220...300, 0.10...0.36, 5 + spec.wind * 0.7, heavy ? 0.7 : 0.92, 0.4),
            (heavy ? 0 : Int((cover * (overcast ? 3 : 2.4)).rounded()), overcast ? 380...460 : 300...400, 0.22...0.46, 8 + spec.wind, 1, 0.7)
        ]

        for (depth, layerSpec) in layers.enumerated() where layerSpec.count > 0 {
            for index in 0..<layerSpec.count {
                let seed = Double(depth * 10 + index) + layerSpec.salt
                let width = (layerSpec.width.lowerBound + WeatherSeed.value(seed, 0.21) * (layerSpec.width.upperBound - layerSpec.width.lowerBound)) * unit
                let height = width * (0.42 + WeatherSeed.value(seed, 0.71) * 0.16)
                let y = size.height * (layerSpec.y.lowerBound + WeatherSeed.value(seed, 0.33) * (layerSpec.y.upperBound - layerSpec.y.lowerBound))
                let cloud = CALayer()
                cloud.bounds = CGRect(x: 0, y: 0, width: width, height: height)
                cloud.contents = WeatherSprites.cloud(shape: (depth * 3 + index * 2 + Int(layerSpec.salt * 10)) % 8, tone: tone)
                if WeatherSeed.value(seed, 0.83) > 0.5 { cloud.transform = CATransform3DMakeScale(-1, 1, 1) }
                cloud.opacity = Float(layerSpec.opacity)
                let travel = size.width + width + 40
                let drift = CABasicAnimation(keyPath: "position")
                drift.fromValue = CGPoint(x: -width / 2 - 20, y: y)
                drift.toValue = CGPoint(x: size.width + width / 2 + 20, y: y)
                let phase = (Double(index) + WeatherSeed.value(seed, 0.47) * 0.7) / Double(layerSpec.count)
                cloud.position = CGPoint(x: -width, y: y)
                cloud.add(loop(drift, duration: travel / layerSpec.speed, phase: phase), forKey: "drift")
                group.addSublayer(cloud)
            }
        }
    }

    private static func deck(in group: CALayer, size: CGSize, tone: CloudTone, amount: Double, wind: Double) {
        let tileHeight = size.height * 0.62
        let tileWidth = tileHeight * WeatherSprites.deckAspect
        let strip = CALayer()
        strip.frame = CGRect(x: 0, y: -size.height * 0.04, width: tileWidth * 2, height: tileHeight)
        strip.opacity = Float(amount)
        for copy in 0..<2 {
            let tile = CALayer()
            tile.frame = CGRect(x: CGFloat(copy) * tileWidth, y: 0, width: tileWidth, height: tileHeight)
            tile.contents = WeatherSprites.deck(tone: tone)
            strip.addSublayer(tile)
        }
        let scroll = CABasicAnimation(keyPath: "transform.translation.x")
        scroll.fromValue = -tileWidth
        scroll.toValue = 0
        strip.add(loop(scroll, duration: tileWidth / (2.5 + wind * 0.4)), forKey: "scroll")
        group.addSublayer(strip)
    }

    static func fog(in group: CALayer, size: CGSize, spec: WeatherSceneSpec) {
        guard spec.fog > 0.08 else { return }
        let tint = spec.isNight ? UIColor(red: 0.55, green: 0.60, blue: 0.72, alpha: 1) : UIColor.white

        let veil = CAGradientLayer()
        veil.frame = CGRect(origin: .zero, size: size)
        veil.colors = [tint.withAlphaComponent(0).cgColor, tint.withAlphaComponent(spec.fog * 0.10).cgColor, tint.withAlphaComponent(spec.fog * (spec.isNight ? 0.26 : 0.16)).cgColor]
        veil.locations = [0.2, 0.55, 1]
        group.addSublayer(veil)

        let emitter = CAEmitterLayer()
        emitter.frame = CGRect(origin: .zero, size: size)
        emitter.emitterShape = .rectangle
        emitter.emitterPosition = CGPoint(x: size.width + 190, y: size.height * 0.58)
        emitter.emitterSize = CGSize(width: 10, height: size.height * 0.8)
        let patch = CAEmitterCell()
        patch.contents = WeatherSprites.fogPatch
        patch.contentsScale = WeatherSprites.spriteScale
        let speed = 14 + spec.wind * 1.6
        patch.velocity = speed
        patch.velocityRange = 5
        patch.emissionLongitude = .pi
        patch.lifetime = Float((size.width + 420) / (speed - 5))
        patch.birthRate = Float(0.05 + spec.fog * 0.11)
        patch.scale = 1.3
        patch.scaleRange = 0.5
        patch.alphaRange = 0.06
        patch.color = tint.withAlphaComponent(spec.isNight ? 0.08 + spec.fog * 0.16 : 0.04 + spec.fog * 0.09).cgColor
        patch.spinRange = 0.05
        emitter.emitterCells = [patch]
        group.addSublayer(emitter)
        fill(emitter, area: CGRect(x: -150, y: size.height * 0.18, width: size.width + 300, height: size.height * 0.8), travel: size.width + 300)
    }

    static func precipitation(in group: CALayer, size: CGSize, spec: WeatherSceneSpec) {
        guard spec.rain > 0.01 || spec.snow > 0.01 else { return }
        let side = hypot(size.width, size.height) * 1.15
        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        container.position = CGPoint(x: size.width / 2, y: size.height / 2)
        let lean = spec.snow > 0.01 ? spec.wind * 0.022 : atan(0.10 + spec.wind * 0.018)
        container.transform = CATransform3DMakeRotation(.pi / 2 + CGFloat(lean), 0, 0, 1)
        group.addSublayer(container)
        let density = side / size.width

        let emitter = CAEmitterLayer()
        emitter.frame = container.bounds
        emitter.emitterShape = .rectangle
        emitter.emitterPosition = CGPoint(x: -12, y: side / 2)
        emitter.emitterSize = CGSize(width: 1, height: side)

        if spec.rain > 0.01 {
            let amount = spec.rain
            let tint = spec.isNight ? UIColor(red: 0.74, green: 0.82, blue: 0.96, alpha: 1) : UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 1)
            let dim = spec.isNight ? 0.7 : 1.0

            let sheet = CALayer()
            let tile: CGFloat = 220
            sheet.frame = CGRect(x: -tile, y: 0, width: side + tile, height: side)
            sheet.backgroundColor = UIColor(patternImage: WeatherSprites.rainSheet).cgColor
            sheet.opacity = Float((0.05 + amount * 0.09) * dim)
            let fall = CABasicAnimation(keyPath: "transform.translation.x")
            fall.fromValue = 0
            fall.toValue = tile
            sheet.add(loop(fall, duration: 0.42), forKey: "fall")
            container.addSublayer(sheet)

            let small = CAEmitterCell()
            small.contents = WeatherSprites.rainStreak
            small.contentsScale = WeatherSprites.spriteScale
            small.birthRate = Float((70 + amount * 230) * density)
            small.velocity = 680
            small.velocityRange = 160
            small.lifetime = Float(side / 520)
            small.scale = 0.6
            small.scaleRange = 0.15
            small.color = tint.withAlphaComponent(0.5 * dim).cgColor
            small.alphaRange = 0.14
            small.alphaSpeed = -0.12

            let large = CAEmitterCell()
            large.contents = WeatherSprites.rainStreak
            large.contentsScale = WeatherSprites.spriteScale
            large.birthRate = Float((18 + amount * 85) * density)
            large.velocity = 1080
            large.velocityRange = 260
            large.lifetime = Float(side / 820)
            large.scale = 1.05
            large.scaleRange = 0.2
            large.color = tint.withAlphaComponent(0.6 * dim).cgColor
            large.alphaRange = 0.16

            emitter.emitterCells = [small, large]
        } else {
            let amount = spec.snow
            let tint = spec.isNight ? UIColor(red: 0.80, green: 0.85, blue: 0.95, alpha: 1) : UIColor.white
            func flake(_ birth: Double, velocity: CGFloat, range: CGFloat, scale: CGFloat, alpha: CGFloat, spin: CGFloat, sprite: CGImage = WeatherSprites.snowflake) -> CAEmitterCell {
                let cell = CAEmitterCell()
                cell.contents = sprite
                cell.contentsScale = WeatherSprites.spriteScale
                cell.birthRate = Float(birth * density)
                cell.velocity = velocity
                cell.velocityRange = range
                cell.lifetime = Float(side / max(12, velocity - range))
                cell.emissionRange = 0.12
                cell.scale = scale
                cell.scaleRange = scale * 0.3
                cell.spinRange = spin
                cell.color = tint.withAlphaComponent(alpha).cgColor
                cell.alphaRange = 0.2
                return cell
            }
            emitter.emitterCells = [
                flake(8 + amount * 18, velocity: 46, range: 14, scale: 0.42, alpha: 0.7, spin: 1.6),
                flake(3 + amount * 7, velocity: 72, range: 18, scale: 0.7, alpha: 0.85, spin: 1.2),
                flake(1 + amount * 2.2, velocity: 105, range: 24, scale: 1.0, alpha: 0.85, spin: 0.9),
                flake(0.3 + amount * 0.7, velocity: 165, range: 40, scale: 1.0, alpha: 0.16, spin: 0.2, sprite: WeatherSprites.bokeh)
            ]
        }
        container.addSublayer(emitter)
        if spec.snow > 0.01 {
            fill(emitter, area: CGRect(x: 0, y: 0, width: side, height: side), travel: side)
        }
    }

    private static func fill(_ source: CAEmitterLayer, area: CGRect, travel: CGFloat) {
        guard let cells = source.emitterCells, let parent = source.superlayer else { return }
        let window = 0.25
        let burst = CAEmitterLayer()
        burst.frame = source.frame
        burst.emitterShape = .rectangle
        burst.emitterPosition = CGPoint(x: area.midX, y: area.midY)
        burst.emitterSize = area.size
        burst.emitterCells = cells.compactMap { cell in
            guard let copy = cell.copy() as? CAEmitterCell else { return nil }
            let crossing = Double(travel / max(cell.velocity, 1))
            copy.birthRate = cell.birthRate * Float(crossing / window)
            return copy
        }
        burst.birthRate = 0
        let rate = CAKeyframeAnimation(keyPath: "birthRate")
        rate.values = [1, 1, 0]
        rate.keyTimes = [0, 0.95, 1]
        rate.duration = window
        rate.isRemovedOnCompletion = false
        rate.fillMode = .forwards
        burst.add(rate, forKey: "burst")
        parent.insertSublayer(burst, below: source)
    }

    private static func radial(colors: [(RGBColor, Double)], locations: [Double]) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.colors = colors.map { UIColor(red: $0.0.r, green: $0.0.g, blue: $0.0.b, alpha: $0.1).cgColor }
        layer.locations = locations.map { NSNumber(value: $0) }
        return layer
    }

    private static func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.calculationMode = .cubic
        return animation
    }

    private static func rotation(from start: CGFloat, turns: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = start
        animation.toValue = start + .pi * 2 * turns
        return animation
    }

    private static func loop(_ animation: CAAnimation, duration: Double, phase: Double = 0) -> CAAnimation {
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.beginTime = 0.000_001
        animation.timeOffset = phase * duration
        animation.isRemovedOnCompletion = false
        return animation
    }
}

enum CloudTone: Int {
    case day
    case grey
    case storm
    case night
    case nightGrey
    case sunset
    case overcast

    var lit: RGBColor {
        switch self {
        case .day: RGBColor(1, 1, 1)
        case .grey: RGBColor(0.82, 0.85, 0.89)
        case .storm: RGBColor(0.50, 0.54, 0.60)
        case .night: RGBColor(0.36, 0.40, 0.52)
        case .nightGrey: RGBColor(0.28, 0.31, 0.38)
        case .sunset: RGBColor(0.95, 0.77, 0.66)
        case .overcast: RGBColor(0.93, 0.94, 0.96)
        }
    }

    var shade: RGBColor {
        switch self {
        case .day: RGBColor(0.79, 0.84, 0.92)
        case .grey: RGBColor(0.63, 0.67, 0.73)
        case .storm: RGBColor(0.33, 0.36, 0.42)
        case .night: RGBColor(0.17, 0.20, 0.29)
        case .nightGrey: RGBColor(0.16, 0.18, 0.23)
        case .sunset: RGBColor(0.45, 0.36, 0.48)
        case .overcast: RGBColor(0.70, 0.74, 0.80)
        }
    }
}

enum WeatherSprites {
    static let spriteScale: CGFloat = 2
    static let screenScale: CGFloat = 3
    static let meteorAngle: CGFloat = 0.62

    private static let cache = NSCache<NSString, CGImage>()

    private static func cached(_ key: String, size: CGSize, scale: CGFloat = spriteScale, draw: (CGContext, CGSize) -> Void) -> CGImage {
        if let image = cache.object(forKey: key as NSString) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(context.cgContext, size)
        }
        let cgImage = image.cgImage!
        cache.setObject(cgImage, forKey: key as NSString)
        return cgImage
    }

    private static func gradient(_ stops: [(UIColor, CGFloat)]) -> CGGradient {
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map(\.0.cgColor) as CFArray,
            locations: stops.map(\.1)
        )!
    }

    private static func color(_ rgb: RGBColor, _ alpha: CGFloat) -> UIColor {
        UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    private static func blob(_ context: CGContext, center: CGPoint, radius: CGFloat, stops: [(UIColor, CGFloat)]) {
        context.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    static func starField(size: CGSize, seed: Int) -> CGImage {
        cached("stars-\(seed)-\(Int(size.width))x\(Int(size.height))", size: size, scale: screenScale) { context, size in
            for index in 0..<46 {
                let s = Double(index * 7 + seed * 131) + 0.5
                let heightFraction = WeatherSeed.value(s, 0.23)
                let point = CGPoint(x: size.width * WeatherSeed.value(s, 0.11), y: size.height * heightFraction)
                let fade = 1 - pow(heightFraction, 2) * 0.85
                let radius = 0.35 + WeatherSeed.value(s, 0.41) * 0.75
                let pick = WeatherSeed.value(s, 0.77)
                let tint = pick < 0.18 ? RGBColor(0.80, 0.88, 1.0) : pick < 0.28 ? RGBColor(1.0, 0.92, 0.80) : RGBColor(1, 1, 1)
                let alpha = (0.45 + WeatherSeed.value(s, 0.63) * 0.55) * fade
                if radius > 0.85 {
                    blob(context, center: point, radius: radius * 4, stops: [(color(tint, alpha * 0.3), 0), (color(tint, 0), 1)])
                }
                context.setFillColor(color(tint, alpha).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }

    static var brightStar: CGImage {
        cached("bright-star", size: CGSize(width: 20, height: 20), scale: screenScale) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            blob(context, center: center, radius: size.width / 2, stops: [
                (UIColor.white.withAlphaComponent(0.55), 0), (UIColor(red: 0.8, green: 0.88, blue: 1, alpha: 0.18), 0.25), (UIColor.white.withAlphaComponent(0), 1)
            ])
            context.setFillColor(UIColor.white.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2))
        }
    }

    static var meteor: CGImage {
        cached("meteor", size: CGSize(width: 120, height: 8)) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let tail = CGPoint(x: center.x - 56, y: center.y)
            for (width, alpha) in [(3.2, 0.18), (1.3, 1.0)] {
                context.saveGState()
                context.clip(to: CGRect(x: tail.x, y: center.y - width / 2, width: 56, height: width))
                context.drawLinearGradient(gradient([(UIColor.white.withAlphaComponent(0), 0), (UIColor.white.withAlphaComponent(alpha), 1)]), start: tail, end: center, options: [])
                context.restoreGState()
            }
        }
    }

    static func ray(color rgb: RGBColor) -> CGImage {
        cached("ray-\(Int(rgb.g * 100))-\(Int(rgb.b * 100))", size: CGSize(width: 36, height: 200)) { context, size in
            for (topWidth, bottomWidth, alpha) in [(7.0, 34.0, 0.16), (3.5, 17.0, 0.26), (1.4, 6.5, 0.38)] {
                context.saveGState()
                let path = CGMutablePath()
                path.move(to: CGPoint(x: size.width / 2 - topWidth / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2 + topWidth / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2 + bottomWidth / 2, y: size.height))
                path.addLine(to: CGPoint(x: size.width / 2 - bottomWidth / 2, y: size.height))
                path.closeSubpath()
                context.addPath(path)
                context.clip()
                context.drawLinearGradient(gradient([
                    (color(rgb, 0), 0), (color(rgb, alpha * 0.5), 0.45), (color(rgb, alpha), 0.78), (color(rgb, 0), 1)
                ]), start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                context.restoreGState()
            }
        }
    }

    static func aperture(tint: RGBColor) -> CGImage {
        cached("aperture-\(Int(tint.r * 100))-\(Int(tint.g * 100))-\(Int(tint.b * 100))", size: CGSize(width: 64, height: 64)) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let path = CGMutablePath()
            for corner in 0..<7 {
                let angle = CGFloat(corner) / 7 * .pi * 2 - .pi / 2
                let point = CGPoint(x: center.x + cos(angle) * 29, y: center.y + sin(angle) * 29)
                corner == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.closeSubpath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            blob(context, center: center, radius: 32, stops: [(color(tint, 0.35), 0), (color(tint, 0.55), 0.8), (color(tint, 0.9), 1)])
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(color(tint, 0.5).cgColor)
            context.setLineWidth(1.2)
            context.strokePath()
        }
    }

    static func cloud(shape: Int, tone: CloudTone) -> CGImage {
        cached("cloud-\(shape)-\(tone.rawValue)", size: CGSize(width: 360, height: 180)) { context, size in
            drawCloud(context, size: size, seed: Double(shape) * 17 + 3, tone: tone)
        }
    }

    static let deckAspect: CGFloat = 2.4

    static func deck(tone: CloudTone) -> CGImage {
        cached("deck-\(tone.rawValue)", size: CGSize(width: 720, height: 300), scale: 1.5) { context, size in
            let lit = tone.lit
            let shade = tone.shade
            context.drawLinearGradient(
                gradient([(color(shade, 0.95), 0), (color(shade.blended(with: lit, amount: 0.3), 0.85), 0.55), (color(shade, 0), 1)]),
                start: .zero,
                end: CGPoint(x: 0, y: size.height * 0.8),
                options: []
            )
            for pass in 0..<2 {
                for index in 0..<140 {
                    let s = Double(index) * 1.37 + 11
                    let fx = WeatherSeed.value(s, 0.13)
                    let edge = 0.62 + 0.12 * sin(fx * .pi * 6 + 1.3) + 0.06 * sin(fx * .pi * 14)
                    let fy = pow(WeatherSeed.value(s, 0.29), 0.7) * edge
                    let radius = size.height * (0.07 + 0.09 * WeatherSeed.value(s, 0.37))
                    for shift in [-size.width, 0, size.width] {
                        let center = CGPoint(x: size.width * fx + shift, y: size.height * fy)
                        if pass == 0 {
                            blob(context, center: CGPoint(x: center.x, y: center.y + radius * 0.25), radius: radius, stops: [(color(shade, 0.8), 0), (color(shade, 0.5), 0.5), (color(shade, 0), 1)])
                        } else {
                            blob(context, center: CGPoint(x: center.x - radius * 0.15, y: center.y - radius * 0.25), radius: radius * 0.75, stops: [(color(lit, 0.55), 0), (color(lit, 0.25), 0.5), (color(lit, 0), 1)])
                        }
                    }
                }
            }
        }
    }

    private static func drawCloud(_ context: CGContext, size: CGSize, seed: Double, tone: CloudTone) {
        let base = size.height * 0.80
        var puffs: [(center: CGPoint, radius: CGFloat)] = []
        var details: [(center: CGPoint, radius: CGFloat)] = []

        let towers = (0..<(1 + Int(seed) % 3)).map { index -> (center: Double, width: Double, height: Double) in
            let s = seed * 3.1 + Double(index) * 7.7
            return (0.28 + WeatherSeed.value(s, 0.11) * 0.44, 0.10 + WeatherSeed.value(s, 0.23) * 0.16, 0.55 + WeatherSeed.value(s, 0.37) * 0.45)
        }
        let plateau = 0.16 + WeatherSeed.value(seed, 0.59) * 0.14

        func profile(_ fx: Double) -> Double {
            let edge = min(1, max(0, (fx - 0.06) / 0.14)) * min(1, max(0, (0.94 - fx) / 0.14))
            let peak = towers.map { $0.height * exp(-pow((fx - $0.center) / $0.width, 2)) }.max() ?? 0
            return max(peak, plateau * edge) * (0.92 + 0.08 * sin(fx * 17 + seed))
        }

        for index in 0..<44 {
            let s = seed * 31 + Double(index)
            let fx = 0.06 + WeatherSeed.value(s, 0.13) * 0.88
            let height = profile(fx)
            guard height > 0.06 else { continue }
            let top = base - size.height * 0.74 * height * (0.82 + 0.18 * WeatherSeed.value(s, 0.29))
            let radius = size.height * (0.10 + 0.15 * height * (0.5 + 0.5 * WeatherSeed.value(s, 0.37)))
            let room = max(0, base - top - radius * 1.6)
            let y = min(top + radius + room * WeatherSeed.value(s, 0.53) * 0.7, base - radius * 0.35)
            puffs.append((CGPoint(x: size.width * fx, y: y), radius))
        }

        for index in 0..<18 {
            let s = seed * 57 + Double(index) + 0.5
            let fx = 0.10 + WeatherSeed.value(s, 0.17) * 0.80
            let height = profile(fx)
            guard height > 0.2 else { continue }
            let top = base - size.height * 0.74 * height * 0.88
            let radius = size.height * (0.03 + 0.04 * WeatherSeed.value(s, 0.41)) * (0.6 + height * 0.6)
            details.append((CGPoint(x: size.width * fx, y: top + radius * (1.0 + WeatherSeed.value(s, 0.61) * 1.2)), radius))
        }

        let lit = tone.lit
        let shade = tone.shade

        for puff in puffs {
            let center = CGPoint(x: puff.center.x + puff.radius * 0.08, y: puff.center.y + puff.radius * 0.16)
            blob(context, center: center, radius: puff.radius, stops: [(color(shade, 0.85), 0), (color(shade, 0.7), 0.55), (color(shade, 0), 1)])
        }
        for puff in puffs {
            let center = CGPoint(x: puff.center.x - puff.radius * 0.16, y: puff.center.y - puff.radius * 0.22)
            blob(context, center: center, radius: puff.radius * 0.9, stops: [(color(lit, 0.95), 0), (color(lit, 0.78), 0.5), (color(lit, 0), 1)])
        }
        for detail in details {
            blob(context, center: detail.center, radius: detail.radius, stops: [(color(lit, 0.85), 0), (color(lit, 0.5), 0.5), (color(lit, 0), 1)])
        }

        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.drawLinearGradient(
            gradient([(UIColor.black.withAlphaComponent(0), 0), (UIColor.black, 1)]),
            start: CGPoint(x: 0, y: base - size.height * 0.14),
            end: CGPoint(x: 0, y: base + size.height * 0.05),
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    static var fogPatch: CGImage {
        cached("fog-patch", size: CGSize(width: 300, height: 160), scale: 1) { context, size in
            for index in 0..<9 {
                let s = Double(index) + 0.3
                let center = CGPoint(x: size.width * (0.22 + WeatherSeed.value(s, 0.2) * 0.56), y: size.height * (0.36 + WeatherSeed.value(s, 0.4) * 0.28))
                let radius = size.height * (0.30 + WeatherSeed.value(s, 0.6) * 0.22)
                blob(context, center: center, radius: radius, stops: [(UIColor.white.withAlphaComponent(0.45), 0), (UIColor.white.withAlphaComponent(0.2), 0.5), (UIColor.white.withAlphaComponent(0), 1)])
            }
        }
    }

    static var rainStreak: CGImage {
        cached("rain-streak", size: CGSize(width: 48, height: 4)) { context, size in
            for (width, alpha) in [(3.4, 0.35), (1.7, 1.0)] {
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: (size.height - width) / 2, width: size.width, height: width))
                context.drawLinearGradient(gradient([(UIColor.white.withAlphaComponent(0), 0), (UIColor.white.withAlphaComponent(alpha), 1)]), start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
                context.restoreGState()
            }
        }
    }

    static var rainSheet: UIImage {
        UIImage(cgImage: cached("rain-sheet", size: CGSize(width: 220, height: 220)) { context, size in
            for index in 0..<34 {
                let s = Double(index) + 0.7
                let y = size.height * WeatherSeed.value(s, 0.1)
                let length = 30 + WeatherSeed.value(s, 0.3) * 50
                let x = size.width * WeatherSeed.value(s, 0.5)
                for offset in [-size.width, 0] {
                    let start = CGPoint(x: x + offset, y: y)
                    let end = CGPoint(x: x + offset + length, y: y)
                    context.saveGState()
                    context.clip(to: CGRect(x: start.x, y: y - 0.5, width: length, height: 1))
                    context.drawLinearGradient(gradient([(UIColor.white.withAlphaComponent(0), 0), (UIColor.white, 1)]), start: start, end: end, options: [])
                    context.restoreGState()
                }
            }
        }, scale: spriteScale, orientation: .up)
    }

    static var snowflake: CGImage {
        cached("snowflake", size: CGSize(width: 28, height: 28)) { context, size in
            blob(context, center: CGPoint(x: size.width / 2 + 8, y: size.height / 2), radius: 3.4, stops: [
                (UIColor.white, 0), (UIColor.white.withAlphaComponent(0.85), 0.45), (UIColor.white.withAlphaComponent(0), 1)
            ])
        }
    }

    static var bokeh: CGImage {
        cached("bokeh", size: CGSize(width: 40, height: 40)) { context, size in
            blob(context, center: CGPoint(x: size.width / 2, y: size.height / 2), radius: size.width / 2, stops: [
                (UIColor.white.withAlphaComponent(0.7), 0), (UIColor.white.withAlphaComponent(0.6), 0.65), (UIColor.white.withAlphaComponent(0), 1)
            ])
        }
    }
}

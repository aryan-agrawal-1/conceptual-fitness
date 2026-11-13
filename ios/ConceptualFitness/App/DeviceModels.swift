import Metal
import RealityKit
import SwiftUI
import UIKit

#if DEBUG
enum MeshSweep {
    static func strip(path: [SIMD3<Float>], closed: Bool, widthAxis: SIMD3<Float>, width: Float, thickness: Float) -> MeshDescriptor {
        let frames = sweepFrames(path: path, closed: closed, widthAxis: widthAxis)
        let lengths = arcLengths(path, closed: closed)
        let halfWidth = width / 2
        let halfThickness = thickness / 2
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let count = closed ? path.count + 1 : path.count
        let faces: [(SIMD3<Float>, Float, Float, Float, Float)] = [
            (SIMD3(0, 1, 0), halfThickness, halfThickness, -halfWidth, halfWidth),
            (SIMD3(0, -1, 0), -halfThickness, -halfThickness, halfWidth, -halfWidth),
            (SIMD3(1, 0, 0), halfThickness, -halfThickness, halfWidth, halfWidth),
            (SIMD3(-1, 0, 0), -halfThickness, halfThickness, -halfWidth, -halfWidth),
        ]
        for face in faces {
            let base = UInt32(positions.count)
            for step in 0..<count {
                let index = step % path.count
                let (normal, binormal) = frames[index]
                let point = path[index]
                let faceNormal = normal * face.0.y + binormal * face.0.x
                let u = lengths[min(step, lengths.count - 1)] / max(width, 0.0001)
                positions.append(point + normal * face.1 + binormal * face.3)
                positions.append(point + normal * face.2 + binormal * face.4)
                normals.append(contentsOf: [faceNormal, faceNormal])
                uvs.append(SIMD2(u, 0))
                uvs.append(SIMD2(u, 1))
            }
            for step in 0..<(count - 1) {
                let a = base + UInt32(step * 2)
                indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }
        }
        if !closed {
            for (index, sign) in [(0, Float(-1)), (path.count - 1, Float(1))] {
                let (normal, binormal) = frames[index]
                let tangent = simd_normalize(simd_cross(normal, binormal)) * sign
                let base = UInt32(positions.count)
                for corner in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                    positions.append(path[index] + normal * corner.1 * halfThickness + binormal * corner.0 * halfWidth)
                    normals.append(tangent)
                    uvs.append(SIMD2(0, 0))
                }
                indices.append(contentsOf: sign > 0 ? [base, base + 2, base + 1, base, base + 3, base + 2] : [base, base + 1, base + 2, base, base + 2, base + 3])
            }
        }
        return descriptor(positions, normals, uvs, indices)
    }

    static func tube(path: [SIMD3<Float>], closed: Bool, widthAxis: SIMD3<Float>, radius: Float, sides: Int = 16) -> MeshDescriptor {
        let frames = sweepFrames(path: path, closed: closed, widthAxis: widthAxis)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let count = closed ? path.count + 1 : path.count
        for step in 0..<count {
            let index = step % path.count
            let (normal, binormal) = frames[index]
            for side in 0...sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let direction = normal * cos(angle) + binormal * sin(angle)
                positions.append(path[index] + direction * radius)
                normals.append(direction)
                uvs.append(SIMD2(Float(step) / Float(count), Float(side) / Float(sides)))
            }
        }
        let ring = UInt32(sides + 1)
        for step in 0..<UInt32(count - 1) {
            for side in 0..<UInt32(sides) {
                let a = step * ring + side
                indices.append(contentsOf: [a, a + 1, a + ring, a + 1, a + ring + 1, a + ring])
            }
        }
        return descriptor(positions, normals, uvs, indices)
    }

    static func roundedSlab(width: Float, height: Float, depth: Float, cornerRadius: Float, edgeRadius: Float? = nil, rings: Int = 10, cornerSteps: Int = 12) -> MeshDescriptor {
        let edge = min(edgeRadius ?? depth / 2, depth / 2)
        let wall = depth / 2 - edge
        let inner = roundedRectOutline(width: width - edge * 2, height: height - edge * 2, radius: max(0.0001, cornerRadius - edge), steps: cornerSteps)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let outlineCount = inner.count
        let half = rings / 2
        let profile = (0...half).map { (-Float.pi / 2 + Float($0) / Float(half) * .pi / 2, -wall) }
            + (0...half).map { (Float($0) / Float(half) * .pi / 2, wall) }
        for (phi, lift) in profile {
            for point in inner {
                let normal = SIMD3(point.normal.x * cos(phi), point.normal.y * cos(phi), sin(phi))
                positions.append(SIMD3(point.position.x, point.position.y, lift) + normal * edge)
                normals.append(normal)
                uvs.append(SIMD2(0.5 + positions.last!.x / width, 0.5 - positions.last!.y / height))
            }
        }
        for ring in 0..<(profile.count - 1) {
            for index in 0..<outlineCount {
                let next = (index + 1) % outlineCount
                let a = UInt32(ring * outlineCount + index)
                let b = UInt32(ring * outlineCount + next)
                let c = UInt32((ring + 1) * outlineCount + index)
                let d = UInt32((ring + 1) * outlineCount + next)
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        for (z, sign) in [(depth / 2, Float(1)), (-depth / 2, Float(-1))] {
            let center = UInt32(positions.count)
            positions.append(SIMD3(0, 0, z))
            normals.append(SIMD3(0, 0, sign))
            uvs.append(SIMD2(0.5, 0.5))
            for point in inner {
                positions.append(SIMD3(point.position.x, point.position.y, z))
                normals.append(SIMD3(0, 0, sign))
                uvs.append(SIMD2(0.5 + point.position.x / width, 0.5 - point.position.y / height))
            }
            for index in 0..<UInt32(outlineCount) {
                let a = center + 1 + index
                let b = center + 1 + (index + 1) % UInt32(outlineCount)
                indices.append(contentsOf: sign > 0 ? [center, a, b] : [center, b, a])
            }
        }
        return descriptor(positions, normals, uvs, indices)
    }

    static func roundedRectOutline(width: Float, height: Float, radius: Float, steps: Int) -> [(position: SIMD2<Float>, normal: SIMD2<Float>)] {
        let radius = min(radius, width / 2, height / 2)
        let corners: [(SIMD2<Float>, Float)] = [
            (SIMD2(width / 2 - radius, height / 2 - radius), 0),
            (SIMD2(-width / 2 + radius, height / 2 - radius), .pi / 2),
            (SIMD2(-width / 2 + radius, -height / 2 + radius), .pi),
            (SIMD2(width / 2 - radius, -height / 2 + radius), 3 * .pi / 2),
        ]
        var points: [(SIMD2<Float>, SIMD2<Float>)] = []
        for (center, start) in corners {
            for step in 0...steps {
                let angle = start + Float(step) / Float(steps) * .pi / 2
                let normal = SIMD2(cos(angle), sin(angle))
                points.append((center + normal * radius, normal))
            }
        }
        return points.map { (position: $0.0, normal: $0.1) }
    }

    private static func sweepFrames(path: [SIMD3<Float>], closed: Bool, widthAxis: SIMD3<Float>) -> [(SIMD3<Float>, SIMD3<Float>)] {
        path.indices.map { index in
            let previous = path[closed ? (index - 1 + path.count) % path.count : max(index - 1, 0)]
            let next = path[closed ? (index + 1) % path.count : min(index + 1, path.count - 1)]
            let tangent = simd_normalize(next - previous)
            let normal = simd_normalize(simd_cross(widthAxis, tangent))
            let binormal = simd_normalize(simd_cross(tangent, normal))
            return (normal, binormal)
        }
    }

    private static func arcLengths(_ path: [SIMD3<Float>], closed: Bool) -> [Float] {
        var lengths: [Float] = [0]
        let points = closed ? path + [path[0]] : path
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + simd_distance(points[index], points[index - 1]))
        }
        return lengths
    }

    private static func descriptor(_ positions: [SIMD3<Float>], _ normals: [SIMD3<Float>], _ uvs: [SIMD2<Float>], _ indices: [UInt32]) -> MeshDescriptor {
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
}
#endif

struct DeviceReach: Component {
    var value: Float
}

struct PreparedDevices {
    var models: [DataSourceDevice: Entity] = [:]
    var environment: EnvironmentResource?
}

@MainActor
enum DeviceModels {
    private static var preparation: Task<PreparedDevices, Never>?
    private static let bakedName = "Devices"
    private static let bakedDevices: [DataSourceDevice] = [.appleWatch, .fitbit]

    @discardableResult
    static func prepare() -> Task<PreparedDevices, Never> {
        if let preparation { return preparation }
        let task = Task { @MainActor in
            async let environment = studioLighting()
            async let models = bakedModels()
            return await PreparedDevices(models: models, environment: environment)
        }
        preparation = task
        return task
    }

    static func stage() async -> Entity {
        let prepared = await prepare().value
        let stage = Entity()
        for (device, model) in prepared.models {
            let pivot = Entity()
            pivot.name = device.rawValue
            let copy = model.clone(recursive: true)
            let bounds = copy.visualBounds(relativeTo: nil)
            copy.position = -bounds.center
            pivot.components.set(DeviceReach(value: max(simd_length(bounds.extents) / 2, 0.01)))
            pivot.addChild(copy)
            stage.addChild(pivot)
        }
        stage.addChild(lighting(for: stage, environment: prepared.environment))
        return stage
    }

    private static func studioLighting() async -> EnvironmentResource? {
        guard let studio = studioEnvironment() else { return nil }
        return try? await EnvironmentResource(equirectangular: studio)
    }

    private static func bakedModels() async -> [DataSourceDevice: Entity] {
        guard let url = Bundle.main.url(forResource: bakedName, withExtension: "reality"),
              let baked = try? await Entity(contentsOf: url) else { return [:] }
        var models: [DataSourceDevice: Entity] = [:]
        for device in bakedDevices {
            models[device] = baked.findEntity(named: device.rawValue)
        }
        return models
    }

    #if DEBUG
    static func bake() async {
        let root = Entity()
        let watch = await appleWatch()
        watch.name = DataSourceDevice.appleWatch.rawValue
        root.addChild(watch)
        let fitbit = await fitbitAir()
        fitbit.name = DataSourceDevice.fitbit.rawValue
        root.addChild(fitbit)
        let url = URL.documentsDirectory.appending(path: "\(bakedName).reality")
        do {
            try await root.write(to: url)
            print("Baked device models to \(url.path)")
        } catch {
            print("Baking device models failed: \(error)")
        }
    }

    private static func appleWatch() async -> Entity {
        let root = Entity()
        guard let url = Bundle.main.url(forResource: "AppleWatch", withExtension: "usdz"),
              let scene = try? await Entity(contentsOf: url) else { return root }
        root.addChild(scene)
        let glass = scene.findEntity(named: "screen_13") ?? scene
        let unscaled = glass.visualBounds(relativeTo: root)
        let scale = 0.0425 / max(unscaled.extents.x, unscaled.extents.y, 0.0001)
        scene.scale *= SIMD3(repeating: scale)
        scene.position *= scale

        let aluminium = metal(UIColor(red: 0.86, green: 0.87, blue: 0.88, alpha: 1), roughness: 0.34)
        let band = matte(UIColor(red: 0.87, green: 0.84, blue: 0.78, alpha: 1), roughness: 0.62)
        let crystal = glossy(UIColor(white: 0.015, alpha: 1))
        scene.visit { entity in
            guard var model = entity.components[ModelComponent.self] else { return }
            let lineage = entity.lineage
            model.materials = model.materials.map { material in
                if lineage.contains("strap") { return band }
                if lineage.contains("screen") { return crystal }
                guard let surface = material as? PhysicallyBasedMaterial else { return material }
                let lit = brightness(surface.emissiveColor.color) > 0.05
                return !lit && brightness(surface.baseColor.tint) > 0.3 ? aluminium : material
            }
            entity.components.set(model)
        }

        let face = glass.visualBounds(relativeTo: root)
        if let display = await displayMaterial() {
            let width = face.extents.x * 0.87
            let screen = ModelEntity(
                mesh: .generatePlane(width: width, height: face.extents.y * 0.89, cornerRadius: width * 0.21),
                materials: [display]
            )
            screen.position = [face.center.x, face.center.y, face.max.z + 0.00006]
            root.addChild(screen)
        }
        return root
    }

    private static func fitbitAir() async -> Entity {
        let root = Entity()
        let bandWidth: Float = 0.0182, bandThickness: Float = 0.0022
        let front: Float = 0.0221, halfLength: Float = 0.033, halfDepth: Float = 0.027, easing: Float = 0.0012
        let count = 110
        let loop: [SIMD3<Float>] = (0..<count).map { step in
            let angle = Float.pi / 2 - 0.6 + Float(step) / Float(count) * 2 * .pi
            let depth = halfDepth * sin(angle)
            let flattened = -easing * log(exp(-depth / easing) + exp(-front / easing))
            return SIMD3(0, halfLength * cos(angle), depth > 0 ? flattened : depth)
        }
        let buckleIndex = count - 3
        func outward(_ index: Int) -> SIMD3<Float> {
            let tangent = simd_normalize(loop[(index + 1) % loop.count] - loop[(index + loop.count - 1) % loop.count])
            let normal = SIMD3<Float>(0, tangent.z, -tangent.y)
            return simd_dot(normal, loop[index]) > 0 ? normal : -normal
        }
        let fabric = await woven()
        let trim = matte(UIColor(white: 0.035, alpha: 1), roughness: 0.7)
        let lift = bandThickness * 0.92
        let holderEnd = 22, tailLength = 30, ramp = 6
        func eased(_ value: Float) -> Float {
            let clamped = min(max(value, 0), 1)
            return clamped * clamped * (3 - 2 * clamped)
        }
        let band: [SIMD3<Float>] = ((holderEnd - 1)...(count + holderEnd + tailLength)).map { step in
            let leaving = eased(Float(step - holderEnd) / Float(ramp)) - 1
            let overlapping = eased(Float(step - count - holderEnd) / Float(ramp))
            return loop[step % count] + outward(step % count) * lift * (leaving + overlapping)
        }
        await root.addChild(model(MeshSweep.strip(path: band, closed: false, widthAxis: [1, 0, 0], width: bandWidth, thickness: bandThickness), fabric))
        await root.addChild(model(MeshSweep.strip(path: Array(band.suffix(4)), closed: false, widthAxis: [1, 0, 0], width: bandWidth + 0.0003, thickness: bandThickness * 1.08), trim))

        let black = matte(UIColor(white: 0.03, alpha: 1), roughness: 0.4)
        let frame = matte(UIColor(white: 0.055, alpha: 1), roughness: 0.6)
        let clasp = Entity()
        let clearance = bandThickness / 2 + 0.0011
        let bar = await model(
            MeshSweep.roundedSlab(width: bandWidth + 0.0036, height: 0.0036, depth: 0.0017, cornerRadius: 0.0017, edgeRadius: 0.0008, cornerSteps: 10),
            frame
        )
        bar.position.z = clearance
        clasp.addChild(bar)
        let base = await model(
            MeshSweep.roundedSlab(width: bandWidth + 0.0036, height: 0.0060, depth: 0.0024, cornerRadius: 0.0017, edgeRadius: 0.0008, cornerSteps: 10),
            frame
        )
        base.position = [0, -0.0014, -clearance - 0.0002]
        clasp.addChild(base)
        for side in [Float(-1), 1] {
            let post = await model(
                MeshSweep.roundedSlab(width: 0.0016, height: 0.0034, depth: clearance * 2 + 0.0014, cornerRadius: 0.0007, edgeRadius: 0.0007, rings: 6, cornerSteps: 6),
                frame
            )
            post.position = [side * (bandWidth / 2 + 0.0010), 0, 0]
            clasp.addChild(post)
        }
        let claspNormal = outward(buckleIndex)
        clasp.orientation = simd_quatf(angle: atan2(-claspNormal.y, claspNormal.z) * 1.35, axis: [1, 0, 0])
        clasp.position = loop[buckleIndex]
        root.addChild(clasp)

        let inner = front - bandThickness / 2
        let holderDepth: Float = 0.0033
        let holder = await model(
            MeshSweep.roundedSlab(width: 0.0186, height: 0.0396, depth: holderDepth, cornerRadius: 0.0080, edgeRadius: 0.0010, cornerSteps: 18),
            frame
        )
        holder.position.z = inner - holderDepth / 2
        root.addChild(holder)
        let reach: Float = 0.0038
        let pod = await model(
            MeshSweep.roundedSlab(width: 0.0152, height: 0.0349, depth: reach + 0.0012, cornerRadius: 0.0076, edgeRadius: 0.0012, rings: 12, cornerSteps: 18),
            matte(UIColor(white: 0.025, alpha: 1), roughness: 0.32)
        )
        pod.position.z = inner + 0.0012 - (reach + 0.0012) / 2
        root.addChild(pod)
        let window = await model(
            MeshSweep.roundedSlab(width: 0.0118, height: 0.0306, depth: 0.0010, cornerRadius: 0.0059, edgeRadius: 0.0004, rings: 6, cornerSteps: 16),
            glossy(UIColor(white: 0.01, alpha: 1))
        )
        window.position.z = inner - reach + 0.00042
        root.addChild(window)
        let sensorDepth = inner - reach - 0.00012
        let facingWrist = simd_quatf(angle: .pi, axis: [0, 1, 0])
        let emitter = matte(UIColor(red: 0.42, green: 0.05, blue: 0.05, alpha: 1), roughness: 0.35)
        let sensors: [(Float, any RealityKit.Material)] = [
            (0.0032, matte(UIColor(white: 0.16, alpha: 1), roughness: 0.35)),
            (0.0011, emitter),
            (-0.0010, UnlitMaterial(color: UIColor(red: 0.25, green: 1, blue: 0.5, alpha: 1))),
            (-0.0031, emitter)
        ]
        for (offset, material) in sensors {
            let sensor = ModelEntity(mesh: .generatePlane(width: 0.0027, height: 0.0015, cornerRadius: 0.0004), materials: [material])
            sensor.orientation = facingWrist
            sensor.position = [0, offset, sensorDepth]
            root.addChild(sensor)
        }
        for offset in [Float(0.0060), -0.0059] {
            let contact = ModelEntity(mesh: .generatePlane(width: 0.0009, height: 0.0009, cornerRadius: 0.00045), materials: [metal(UIColor(white: 0.75, alpha: 1), roughness: 0.3)])
            contact.orientation = facingWrist
            contact.position = [0, offset, sensorDepth]
            root.addChild(contact)
        }
        return root
    }

    #endif

    private static func lighting(for root: Entity, environment: EnvironmentResource?) -> Entity {
        let rig = Entity()
        if let environment {
            let light = Entity()
            light.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.7))
            rig.addChild(light)
            root.visit { $0.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light)) }
        }
        let key = DirectionalLight()
        key.light.intensity = 2200
        key.look(at: .zero, from: [0.4, 0.6, 0.8], relativeTo: nil)
        rig.addChild(key)
        let rim = DirectionalLight()
        rim.light.intensity = 1100
        rim.light.color = UIColor(red: 0.7, green: 0.78, blue: 1, alpha: 1)
        rim.look(at: .zero, from: [-0.6, 0.2, -0.5], relativeTo: nil)
        rig.addChild(rim)
        return rig
    }

    #if DEBUG
    private static func model(_ descriptor: MeshDescriptor, _ material: any RealityKit.Material) async -> ModelEntity {
        let mesh = (try? await MeshResource(from: [descriptor])) ?? .generateBox(size: 0.001)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private static func brightness(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red + green + blue) / 3
    }

    private static func metal(_ color: UIColor, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 1.0
        material.roughness = .init(floatLiteral: roughness)
        return material
    }

    private static func glossy(_ color: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 0.0
        material.roughness = 0.08
        material.clearcoat = 1.0
        material.clearcoatRoughness = 0.02
        return material
    }

    private static func matte(_ color: UIColor, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = 0.0
        material.roughness = .init(floatLiteral: roughness)
        return material
    }

    private static func repeating(_ texture: TextureResource) -> MaterialParameters.Texture {
        var parameters = MaterialParameters.Texture(texture)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        parameters.sampler = .init(descriptor)
        return parameters
    }

    private static func woven() async -> PhysicallyBasedMaterial {
        var material = matte(UIColor(white: 0.2, alpha: 1), roughness: 0.94)
        let side = 256
        let color = bitmap(side: side) { x, y in
            let across = y - y.rounded(.down)
            let shade = across < 0.07 || across > 0.93 ? 0.03 : 0.025 + 0.40 * knit(x, y)
            return (shade, shade, shade * 1.04)
        }
        let relief = bitmap(side: side) { x, y in
            let step = 1 / Double(side)
            let slopeX = (knit(x + step, y) - knit(x - step, y)) * 3.2
            let slopeY = (knit(x, y + step) - knit(x, y - step)) * 3.2
            let length = (slopeX * slopeX + slopeY * slopeY + 1).squareRoot()
            return (0.5 - 0.5 * slopeX / length, 0.5 - 0.5 * slopeY / length, 0.5 + 0.5 / length)
        }
        if let color, let texture = try? await TextureResource(image: color, options: .init(semantic: .color)) {
            material.baseColor = .init(tint: .white, texture: repeating(texture))
        }
        if let relief, let texture = try? await TextureResource(image: relief, options: .init(semantic: .normal)) {
            material.normal = .init(texture: repeating(texture))
        }
        material.sheen = .init(tint: UIColor(white: 0.5, alpha: 1))
        return material
    }

    private static func knit(_ x: Double, _ y: Double) -> Double {
        let across = y - y.rounded(.down)
        if across < 0.07 || across > 0.93 {
            return 0.55 + 0.25 * abs(sin(x * 40 * .pi))
        }
        let row = across * 11
        let stagger = row.rounded(.down) * 0.3
        let stitch = pow(abs(sin((x * 12 + stagger) * .pi)), 1.8)
        let rib = sin((row - row.rounded(.down)) * .pi)
        return stitch * rib
    }

    private static func bitmap(side: Int, _ pixel: (Double, Double) -> (Double, Double, Double)) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for row in 0..<side {
            for column in 0..<side {
                let (red, green, blue) = pixel(Double(column) / Double(side), Double(row) / Double(side))
                let offset = (row * side + column) * 4
                bytes[offset] = UInt8(max(0, min(1, red)) * 255)
                bytes[offset + 1] = UInt8(max(0, min(1, green)) * 255)
                bytes[offset + 2] = UInt8(max(0, min(1, blue)) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func displayMaterial() async -> UnlitMaterial? {
        guard let image = displayImage(), let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        return material
    }

    private static func displayImage() -> CGImage? {
        let size = CGSize(width: 512, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let time = NSAttributedString(string: "10:09", attributes: [
                .font: UIFont.systemFont(ofSize: 58, weight: .semibold).rounded,
                .foregroundColor: UIColor.white,
            ])
            time.draw(at: CGPoint(x: size.width - time.size().width - 52, y: 40))
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 44)
            let rings: [(UIColor, CGFloat, CGFloat)] = [
                (UIColor(red: 0.30, green: 0.85, blue: 0.52, alpha: 1), 176, 0.82),
                (UIColor(red: 0.50, green: 0.56, blue: 1.0, alpha: 1), 136, 0.68),
                (UIColor(red: 1.0, green: 0.60, blue: 0.24, alpha: 1), 96, 0.55),
            ]
            for (color, radius, fraction) in rings {
                let track = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                track.lineWidth = 32
                color.withAlphaComponent(0.22).setStroke()
                track.stroke()
                let arc = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * fraction, clockwise: true)
                arc.lineWidth = 32
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
        }
        return image.cgImage
    }

    #endif

    private static func studioEnvironment() -> CGImage? {
        let size = CGSize(width: 512, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let space = CGColorSpaceCreateDeviceRGB()
            let wash = [UIColor(red: 0.20, green: 0.22, blue: 0.32, alpha: 1).cgColor, UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: space, colors: wash as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let softboxes: [(CGRect, UIColor)] = [
                (CGRect(x: 176, y: 18, width: 170, height: 78), UIColor(white: 1, alpha: 1)),
                (CGRect(x: 26, y: 62, width: 74, height: 120), UIColor(white: 1, alpha: 0.8)),
                (CGRect(x: 392, y: 78, width: 64, height: 104), UIColor(red: 1, green: 0.86, blue: 0.72, alpha: 0.7)),
                (CGRect(x: 250, y: 150, width: 120, height: 40), UIColor(red: 0.6, green: 0.7, blue: 1, alpha: 0.35)),
            ]
            for (frame, color) in softboxes {
                context.cgContext.setShadow(offset: .zero, blur: 14, color: color.cgColor)
                color.setFill()
                UIBezierPath(roundedRect: frame, cornerRadius: 12).fill()
            }
        }
        return image.cgImage
    }
}

private extension UIFont {
    var rounded: UIFont {
        fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

private extension Entity {
    func visit(_ body: (Entity) -> Void) {
        body(self)
        children.forEach { $0.visit(body) }
    }

    var lineage: String {
        var names: [String] = []
        var current: Entity? = self
        while let entity = current {
            names.append(entity.name.lowercased())
            current = entity.parent
        }
        return names.joined(separator: "/")
    }
}

struct DeviceSlotKey: PreferenceKey {
    static let defaultValue: [DataSourceDevice: Anchor<CGRect>] = [:]

    static func reduce(value: inout [DataSourceDevice: Anchor<CGRect>], nextValue: () -> [DataSourceDevice: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct DeviceSlot: View {
    let device: DataSourceDevice

    var body: some View {
        Color.clear.anchorPreference(key: DeviceSlotKey.self, value: .bounds) { [device: $0] }
    }
}

extension View {
    func deviceStage() -> some View {
        overlayPreferenceValue(DeviceSlotKey.self) { anchors in
            GeometryReader { proxy in
                DeviceStageView(slots: anchors.mapValues { proxy[$0] }, size: proxy.size)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct DeviceStageView: View {
    let slots: [DataSourceDevice: CGRect]
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = Date()

    private static let cameraDistance: Float = 1
    private static let fieldOfView: Float = 15

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let yaw = Float(-0.55 + (reduceMotion ? 0 : timeline.date.timeIntervalSince(appeared) * 0.32))
            RealityView { content in
                content.camera = .virtual
                let camera = PerspectiveCamera()
                camera.camera.fieldOfViewInDegrees = Self.fieldOfView
                camera.position = [0, 0, Self.cameraDistance]
                content.add(camera)
                let stage = await DeviceModels.stage()
                stage.name = "stage"
                content.add(stage)
            } update: { content in
                guard size.height > 0, let stage = content.entities.first(where: { $0.name == "stage" }) else { return }
                let pointsPerMetre = Float(size.height) / (2 * Self.cameraDistance * tan(Self.fieldOfView * .pi / 360))
                for (device, slot) in slots {
                    guard let pivot = stage.findEntity(named: device.rawValue), let reach = pivot.components[DeviceReach.self] else { continue }
                    pivot.position = [Float(slot.midX - size.width / 2) / pointsPerMetre, Float(size.height / 2 - slot.midY) / pointsPerMetre, 0]
                    pivot.scale = SIMD3(repeating: Float(min(slot.width, slot.height)) * 1.12 / (2 * reach.value * pointsPerMetre))
                    pivot.orientation = simd_quatf(angle: 0.18, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
                }
            }
        }
    }
}

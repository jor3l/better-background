import AppKit
import Combine
import RealityKit
import SwiftUI

/// Live numbers for the overlay. Kept separate so updating them doesn't re-render the 3D view.
@MainActor
final class DebugStats: ObservableObject {
    @Published var fps: Double = 0
    @Published var inferenceMs: Double = 0
    @Published var modelStatus = "Loading depth model…"
    @Published var depthPreview: CGImage?
}

/// Owns the RealityKit scene, the camera pipeline and the tuning values.
@MainActor
final class Stage: ObservableObject {
    @Published var tuning = Tuning()
    @Published var status = "Starting camera…"
    @Published var cameras: [CameraInfo] = []
    @Published var selectedCamera = "" {
        didSet { if oldValue != selectedCamera, !selectedCamera.isEmpty { startCamera() } }
    }

    let stats = DebugStats()
    let root = Entity()
    var dragOffset = SIMD2<Float>(0, 0)
    var updateSubscription: EventSubscription?

    private var surface: PersonSurface?
    private let camera = PerspectiveCamera()
    private let keyLight = Entity()
    private let rimLight = Entity()
    private var iblEntity: Entity?
    private var receivers: [Entity] = []

    private let capture = CameraCapture()
    private let pipeline = Pipeline()
    private var time: Double = 0
    private var appliedTuning: Tuning?
    private var frameTimes: [Double] = []
    private var frameCounter = 0

    init() {
        buildScene()
    }

    // MARK: - Camera pipeline

    func start() {
        cameras = CameraCapture.availableDevices().map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
        pipeline.onStatus = { [weak self] message in
            Task { @MainActor in self?.stats.modelStatus = message }
        }
        pipeline.onResult = { [weak self] frame in
            Task { @MainActor in self?.apply(frame) }
        }
        let pipeline = self.pipeline
        capture.onFrame = { pixelBuffer in pipeline.handle(pixelBuffer) }
        startCamera()
    }

    private func startCamera() {
        capture.start(deviceID: selectedCamera.isEmpty ? nil : selectedCamera) { [weak self] error in
            Task { @MainActor in self?.status = error ?? "Camera running" }
        }
    }

    private func apply(_ frame: FrameData) {
        defer { pipeline.resultConsumed() }
        surface?.update(with: frame, tuning: tuning)

        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        frameCounter += 1
        if frameCounter % 5 == 0 {
            stats.fps = Double(frameTimes.count)
            stats.inferenceMs = frame.inferenceMs
            stats.depthPreview = surface?.depthPreview(mirror: tuning.mirror)
        }
    }

    // MARK: - Scene

    private func buildScene() {
        root.name = "Root"

        // Room
        let floor = ModelEntity(mesh: .generateBox(width: 7, height: 0.02, depth: 7), materials: [Self.pbr(NSColor(red: 0.42, green: 0.30, blue: 0.22, alpha: 1), roughness: 0.6)])
        floor.position = [0, -0.01, -0.5]
        let wallMaterial = Self.pbr(NSColor(red: 0.78, green: 0.74, blue: 0.68, alpha: 1), roughness: 0.9)
        let backWall = ModelEntity(mesh: .generateBox(width: 7, height: 3.2, depth: 0.05), materials: [wallMaterial])
        backWall.position = [0, 1.6, -2.2]
        let leftWall = ModelEntity(mesh: .generateBox(width: 0.05, height: 3.2, depth: 5), materials: [wallMaterial])
        leftWall.position = [-3.0, 1.6, 0.3]
        let rightWall = ModelEntity(mesh: .generateBox(width: 0.05, height: 3.2, depth: 5), materials: [wallMaterial])
        rightWall.position = [3.0, 1.6, 0.3]

        // A "window" glowing on the back wall
        var windowMaterial = UnlitMaterial(color: NSColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 1))
        windowMaterial.blending = .opaque
        let window = ModelEntity(mesh: .generatePlane(width: 1.4, height: 1.0), materials: [windowMaterial])
        window.position = [-1.6, 1.7, -2.17]

        // Shelf with a few objects
        let shelf = ModelEntity(mesh: .generateBox(width: 1.4, height: 0.04, depth: 0.3), materials: [Self.pbr(NSColor(red: 0.3, green: 0.2, blue: 0.14, alpha: 1), roughness: 0.5)])
        shelf.position = [1.3, 1.5, -2.02]
        let book1 = ModelEntity(mesh: .generateBox(width: 0.08, height: 0.28, depth: 0.2), materials: [Self.pbr(.systemRed, roughness: 0.7)])
        book1.position = [1.0, 1.66, -2.02]
        let book2 = ModelEntity(mesh: .generateBox(width: 0.07, height: 0.24, depth: 0.2), materials: [Self.pbr(.systemTeal, roughness: 0.7)])
        book2.position = [1.1, 1.64, -2.02]
        let vase = ModelEntity(mesh: .generateCylinder(height: 0.3, radius: 0.07), materials: [Self.pbr(.white, roughness: 0.2)])
        vase.position = [1.6, 1.67, -2.02]
        let ball = ModelEntity(mesh: .generateSphere(radius: 0.18), materials: [Self.pbr(.systemOrange, roughness: 0.3, metallic: 0.8)])
        ball.position = [-0.9, 0.18, -1.2]
        let plant = ModelEntity(mesh: .generateCylinder(height: 1.1, radius: 0.18), materials: [Self.pbr(NSColor(red: 0.2, green: 0.45, blue: 0.25, alpha: 1), roughness: 0.8)])
        plant.position = [2.2, 0.55, -1.5]

        // Desk in front of the person hides where the video frame ends
        let desk = ModelEntity(mesh: .generateBox(width: 2.0, height: 0.05, depth: 0.7, cornerRadius: 0.01), materials: [Self.pbr(NSColor(red: 0.22, green: 0.22, blue: 0.25, alpha: 1), roughness: 0.35)])
        desk.position = [0, 0.74, 0.55]

        let props: [Entity] = [floor, backWall, leftWall, rightWall, window, shelf, book1, book2, vase, ball, plant, desk]
        props.forEach { root.addChild($0) }
        receivers = props.filter { $0 !== window }

        // Person
        do {
            let surface = try PersonSurface()
            self.surface = surface
            root.addChild(surface.entity)
            receivers.append(surface.entity)
        } catch {
            status = "Could not create the person surface: \(error.localizedDescription)"
        }

        // Lights
        keyLight.components.set(SpotLightComponent(color: .white, intensity: 60_000, innerAngleInDegrees: 25, outerAngleInDegrees: 55, attenuationRadius: 10))
        keyLight.components.set(SpotLightComponent.Shadow())
        root.addChild(keyLight)

        rimLight.components.set(PointLightComponent(color: NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1), intensity: 25_000, attenuationRadius: 4))
        rimLight.position = [-1.3, 1.7, -0.7]
        root.addChild(rimLight)

        // Environment (image-based) light from a generated equirectangular gradient
        let ibl = Entity()
        root.addChild(ibl)
        iblEntity = ibl
        for entity in receivers {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        }
        if let image = Self.makeEnvironmentImage() {
            Task { @MainActor [weak self] in
                guard let environment = try? await EnvironmentResource(equirectangular: image) else { return }
                ibl.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: self?.tuning.environment ?? 0))
            }
        }

        // Camera
        camera.camera.fieldOfViewInDegrees = 42
        root.addChild(camera)

        applyTuning(force: true)
        tick(0)
    }

    /// Called every rendered frame.
    func tick(_ dt: TimeInterval) {
        time += dt
        let t = Float(time)
        let sway = tuning.sway
        let position = SIMD3<Float>(
            sin(t * 0.5) * sway + dragOffset.x,
            1.2 + sin(t * 0.37) * sway * 0.3 + dragOffset.y,
            2.5
        )
        camera.look(at: [0, 1.05, 0.1], from: position, relativeTo: nil)
        applyTuning(force: false)
    }

    private func applyTuning(force: Bool) {
        guard force || appliedTuning != tuning else { return }
        appliedTuning = tuning

        let az = tuning.keyAzimuth * .pi / 180
        let radius: Float = 2.4
        let keyPosition = SIMD3<Float>(sin(az) * radius, 2.2, cos(az) * radius)
        keyLight.look(at: [0, 1.05, 0], from: keyPosition, relativeTo: nil)
        keyLight.components.set(SpotLightComponent(
            color: Self.color(kelvin: tuning.keyKelvin),
            intensity: tuning.keyIntensity,
            innerAngleInDegrees: 25,
            outerAngleInDegrees: 55,
            attenuationRadius: 10
        ))

        rimLight.isEnabled = tuning.rimOn
        rimLight.components.set(PointLightComponent(
            color: NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1),
            intensity: tuning.rimIntensity,
            attenuationRadius: 4
        ))

        if let ibl = iblEntity, var component = ibl.components[ImageBasedLightComponent.self] {
            component.intensityExponent = tuning.environment
            ibl.components.set(component)
        }
    }

    // MARK: - Helpers

    static func pbr(_ color: NSColor, roughness: Float, metallic: Float = 0) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        return material
    }

    /// Approximate colour of a black body at the given temperature.
    static func color(kelvin: Float) -> NSColor {
        let t = Double(kelvin) / 100
        var r: Double, g: Double, b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        func c(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 255) / 255) }
        return NSColor(red: c(r), green: c(g), blue: c(b), alpha: 1)
    }

    /// Small equirectangular image: warm ceiling, neutral walls, a bright window to one side, dark floor.
    static func makeEnvironmentImage() -> CGImage? {
        let w = 256, h = 128
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let v = Float(y) / Float(h - 1) // 0 top ... 1 bottom
            for x in 0..<w {
                let u = Float(x) / Float(w - 1)
                var c: SIMD3<Float>
                if v < 0.5 {
                    let k = v / 0.5
                    c = SIMD3<Float>(1.0, 0.93, 0.82) * (1 - k) + SIMD3<Float>(0.75, 0.72, 0.68) * k
                } else {
                    let k = (v - 0.5) / 0.5
                    c = SIMD3<Float>(0.55, 0.45, 0.38) * (1 - k) + SIMD3<Float>(0.15, 0.12, 0.1) * k
                }
                // Window blob
                let du = (u - 0.62) * 2, dv = (v - 0.42) * 3
                let blob = exp(-(du * du + dv * dv) * 18)
                c += SIMD3<Float>(0.8, 0.9, 1.0) * blob
                let i = (y * w + x) * 4
                pixels[i] = UInt8(min(c.x, 1) * 255)
                pixels[i + 1] = UInt8(min(c.y, 1) * 255)
                pixels[i + 2] = UInt8(min(c.z, 1) * 255)
                pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

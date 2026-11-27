import AppKit
import Combine
import CoreImage
import RealityKit
import SwiftUI

enum PreviewMode: String, CaseIterable, Identifiable {
    case composite, camera, mask, depth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .composite: "Composite"
        case .camera: "Camera"
        case .mask: "Mask"
        case .depth: "Depth"
        }
    }
}

/// Live numbers for the overlay. Kept separate so updating them doesn't re-render the panels.
@MainActor
final class DebugStats: ObservableObject {
    @Published var fps: Double = 0
    @Published var inferenceMs: Double = 0
    @Published var modelStatus = "Loading depth model…"
    @Published var cameraStatus = "Starting camera…"
    @Published var maskCoverage: Double = 0
    @Published var depthPreview: CGImage?
}

/// The 2D image shown in the camera, mask and depth preview modes.
@MainActor
final class PreviewImage: ObservableObject {
    @Published var image: CGImage?
}

/// Owns the RealityKit scene, the camera pipeline and every setting.
@MainActor
final class Stage: ObservableObject {
    @Published var tuning: Tuning
    @Published var presets: [SavedPreset]
    @Published var cameras: [CameraInfo] = []
    @Published var selectedCamera: String {
        didSet {
            guard oldValue != selectedCamera else { return }
            SettingsStore.cameraID = selectedCamera
            startCamera()
        }
    }
    @Published var previewMode: PreviewMode = .composite
    @Published var showStats = true
    @Published var paused = false {
        didSet { pipeline.setPaused(paused) }
    }

    let stats = DebugStats()
    let preview = PreviewImage()
    let root = Entity()
    var dragOffset = SIMD2<Float>(0, 0)
    var updateSubscription: EventSubscription?

    private var surface: PersonSurface?
    private let personAnchor = Entity()
    private var environmentEntity: Entity?
    private var builtEnvironmentKey: EnvironmentKey?
    private let camera = PerspectiveCamera()
    private let keyLight = Entity()
    private let rimLight = Entity()
    private let fillLight = Entity()
    private let ibl = Entity()
    private var hasEnvironmentResource = false

    private let capture = CameraCapture()
    private let pipeline = Pipeline()
    private let ciContext = CIContext()
    private var time: Double = 0
    private var appliedTuning: Tuning?
    private var frameTimes: [Double] = []
    private var frameCounter = 0
    private var cancellables: Set<AnyCancellable> = []

    /// The parts of the settings that require rebuilding the room.
    private struct EnvironmentKey: Equatable {
        var kind: EnvironmentKind
        var wall, floor, accent, rim: RGBColor
        var props, desk: Bool
        init(_ t: Tuning) {
            kind = t.environment
            wall = t.wallColor; floor = t.floorColor; accent = t.accentColor; rim = t.rimColor
            props = t.showProps; desk = t.showDesk
        }
    }

    init() {
        tuning = SettingsStore.loadTuning()
        presets = SettingsStore.loadPresets()
        selectedCamera = SettingsStore.cameraID
        buildScene()

        // Save settings shortly after they stop changing.
        $tuning
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { SettingsStore.save($0) }
            .store(in: &cancellables)

        $tuning
            .map(\.segmentationQuality)
            .removeDuplicates()
            .sink { [pipeline] in pipeline.setQuality($0) }
            .store(in: &cancellables)

        $tuning
            .map(\.resolution)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.startCamera() }
            .store(in: &cancellables)
    }

    // MARK: - Presets

    func resetAll() {
        tuning = Tuning()
    }

    func resetLookToEnvironment() {
        tuning = tuning.applyingEnvironment(tuning.environment)
    }

    func selectEnvironment(_ kind: EnvironmentKind) {
        tuning = tuning.applyingEnvironment(kind)
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[i].tuning = tuning
        } else {
            presets.append(SavedPreset(name: trimmed, tuning: tuning))
        }
        SettingsStore.save(presets)
    }

    func load(_ preset: SavedPreset) {
        tuning = preset.tuning
    }

    func delete(_ preset: SavedPreset) {
        presets.removeAll { $0.id == preset.id }
        SettingsStore.save(presets)
    }

    // MARK: - Camera pipeline

    func start() {
        refreshCameras()
        pipeline.setQuality(tuning.segmentationQuality)
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

    func refreshCameras() {
        cameras = CameraCapture.availableDevices().map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    private func startCamera() {
        stats.cameraStatus = "Starting camera…"
        capture.start(deviceID: selectedCamera.isEmpty ? nil : selectedCamera, resolution: tuning.resolution) { [weak self] error in
            Task { @MainActor in self?.stats.cameraStatus = error ?? "Camera running" }
        }
    }

    private func apply(_ frame: FrameData) {
        defer { pipeline.resultConsumed() }
        surface?.update(with: frame, tuning: tuning)

        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        frameCounter += 1

        if previewMode != .composite {
            preview.image = previewImage(for: frame)
        } else if preview.image != nil {
            preview.image = nil
        }

        if frameCounter % 5 == 0 {
            stats.fps = Double(frameTimes.count)
            stats.inferenceMs = frame.inferenceMs
            if let mask = frame.mask {
                stats.maskCoverage = Double(mask.reduce(0) { $0 + ($1 >= tuning.maskThreshold ? 1 : 0) }) / Double(mask.count)
            }
            if showStats {
                stats.depthPreview = surface?.depthPreview(mirror: tuning.mirror)
            }
        }
    }

    private func previewImage(for frame: FrameData) -> CGImage? {
        switch previewMode {
        case .composite:
            return nil
        case .camera:
            return cgImage(from: frame.pixelBuffer)
        case .mask:
            return frame.maskBuffer.flatMap { cgImage(from: $0) }
        case .depth:
            return surface?.depthPreview(mirror: tuning.mirror)
        }
    }

    private func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        if tuning.mirror { image = image.oriented(.upMirrored) }
        return ciContext.createCGImage(image, from: image.extent)
    }

    // MARK: - Scene

    private func buildScene() {
        root.name = "Root"
        root.addChild(ibl)

        do {
            let surface = try PersonSurface()
            self.surface = surface
            personAnchor.addChild(surface.entity)
            surface.entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        } catch {
            stats.cameraStatus = "Could not create the person surface: \(error.localizedDescription)"
        }
        root.addChild(personAnchor)

        root.addChild(keyLight)
        root.addChild(rimLight)
        fillLight.look(at: [0, 1.0, 0], from: [0, 1.4, 3], relativeTo: nil)
        root.addChild(fillLight)

        if let image = Self.makeEnvironmentImage() {
            Task { @MainActor [weak self] in
                guard let self, let environment = try? await EnvironmentResource(equirectangular: image) else { return }
                self.ibl.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: self.tuning.environmentLight))
                self.hasEnvironmentResource = true
            }
        }

        root.addChild(camera)
        applyTuning(force: true)
        tick(0)
    }

    private func rebuildEnvironmentIfNeeded() {
        let key = EnvironmentKey(tuning)
        guard key != builtEnvironmentKey else { return }
        builtEnvironmentKey = key
        environmentEntity?.removeFromParent()
        let built = EnvironmentBuilder.build(tuning)
        for model in built.litModels {
            model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        }
        root.addChild(built.root)
        environmentEntity = built.root
    }

    /// Called every rendered frame.
    func tick(_ dt: TimeInterval) {
        time += dt
        let t = Float(time)
        let sway = tuning.sway
        let position = SIMD3<Float>(
            sin(t * 0.5) * sway + dragOffset.x,
            tuning.cameraHeight + sin(t * 0.37) * sway * 0.3 + dragOffset.y,
            tuning.cameraDistance
        )
        camera.look(at: [0, 1.05, 0.1], from: position, relativeTo: nil)
        applyTuning(force: false)
    }

    private func applyTuning(force: Bool) {
        guard force || appliedTuning != tuning else { return }
        appliedTuning = tuning

        rebuildEnvironmentIfNeeded()

        camera.camera.fieldOfViewInDegrees = tuning.fieldOfView

        // Person placement: scale around the centre of the video frame.
        let center: SIMD3<Float> = [0, surface?.centerY ?? 1.05, 0]
        let s = tuning.personScale
        personAnchor.scale = [s, s, s]
        personAnchor.position = center * (1 - s) + [tuning.personOffsetX, tuning.personOffsetY, tuning.personDistance]

        let az = tuning.keyAzimuth * .pi / 180
        let radius: Float = 2.4
        let keyPosition = SIMD3<Float>(sin(az) * radius, tuning.keyHeight, cos(az) * radius)
        keyLight.look(at: [0, 1.05, 0], from: keyPosition, relativeTo: nil)
        keyLight.components.set(SpotLightComponent(
            color: Self.color(kelvin: tuning.keyKelvin),
            intensity: tuning.keyIntensity,
            innerAngleInDegrees: 25,
            outerAngleInDegrees: 55,
            attenuationRadius: 10
        ))
        if tuning.keyShadows {
            keyLight.components.set(SpotLightComponent.Shadow())
        } else {
            keyLight.components.remove(SpotLightComponent.Shadow.self)
        }

        rimLight.isEnabled = tuning.rimOn
        rimLight.position = [-1.3, 1.7, -0.7]
        rimLight.components.set(PointLightComponent(
            color: tuning.rimColor.nsColor,
            intensity: tuning.rimIntensity,
            attenuationRadius: 4
        ))

        fillLight.isEnabled = tuning.fillIntensity > 0
        fillLight.components.set(DirectionalLightComponent(color: .white, intensity: tuning.fillIntensity))

        if hasEnvironmentResource, var component = ibl.components[ImageBasedLightComponent.self] {
            component.intensityExponent = tuning.environmentLight
            ibl.components.set(component)
        }
    }

    // MARK: - Helpers

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

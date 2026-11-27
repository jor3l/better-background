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
    @Published var matchSummary = "Looking for your face…"
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
    let aiScene = AISceneController()
    let preview = PreviewImage()
    let root = Entity()
    var dragOffset = SIMD2<Float>(0, 0)
    var updateSubscription: EventSubscription?

    private var surface: PersonSurface?
    private let personAnchor = Entity()
    private var backgroundPlate: Entity?

    /// When true the virtual camera and the person stay where they are: no sway, drag or face following.
    var cameraLocked = false

    // Camera match state, smoothed over frames.
    private var estDistance: Float = 0.7
    private var estTilt: Float = 0
    private var estFace = SIMD2<Float>(0, 0)     // face position on the person plane, metres from its centre
    private var haveFace = false
    private var frameAspect: Float = 9.0 / 16.0
    /// Where the virtual camera sits and looks, recomputed every frame.
    private var rigCamera = SIMD3<Float>(0, 1.2, 0.7)
    private var rigRotation = simd_quatf(angle: 0, axis: [1, 0, 0])
    private var headWorld = SIMD3<Float>(0, 1.2, 0)

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

        // AI scene: show or hide its plate, and keep its refresh timer in step with the settings.
        $tuning
            .map { ($0.ai, $0.mirror) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] ai, _ in
                guard let self else { return }
                self.aiScene.updateRefresh(ai) { [weak self] in self?.tuning.ai ?? ai }
                Task { @MainActor in self.syncAIScene(self.tuning.ai) }
            }
            .store(in: &cancellables)
        aiScene.$plate
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.syncAIScene(self.tuning.ai)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - AI scene

    /// Regenerates the AI scene from the next camera frame.
    func regenerateAIScene() {
        aiScene.regenerate(tuning.ai)
    }

    private func syncAIScene(_ ai: AISceneSettings) {
        if ai.enabled, let entity = aiScene.plateEntity(mirror: tuning.mirror) {
            if backgroundPlate !== entity { addBackgroundPlate(entity) }
        } else if let plate = backgroundPlate, plate.name == "AIScenePlate" {
            removeBackgroundPlate()
        }
        cameraLocked = ai.enabled
        if ai.enabled {
            dragOffset = .zero
            if aiScene.plate == nil, aiScene.models.state == .ready, !aiScene.status.isWorking {
                aiScene.regenerate(ai)
            }
        }
    }

    /// Keeps the plate filling the virtual camera's view, far behind the person.
    private func placeBackgroundPlate() {
        guard let plate = backgroundPlate else { return }
        let distance: Float = 8
        let width = 2 * distance * tan(tuning.webcamFOV * .pi / 360)
        plate.orientation = camera.orientation
        plate.position = camera.position + camera.orientation.act([0, 0, -distance])
        plate.scale = [width, width * frameAspect, 1]
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
        updateCameraMatch(frame)
        aiScene.consume(frame, invertDepth: tuning.invertDepth)
        surface?.update(with: frame, tuning: tuning, lights: relightParams())

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

    // MARK: - Camera match

    /// Estimates webcam distance and tilt from the face, then places the person plane and the
    /// virtual camera so the scene is seen from where the real webcam is.
    private func updateCameraMatch(_ frame: FrameData) {
        let w = Float(CVPixelBufferGetWidth(frame.pixelBuffer))
        let h = Float(CVPixelBufferGetHeight(frame.pixelBuffer))
        if w > 0 { frameAspect = h / w }
        guard !cameraLocked else { return }

        let tanH = tan(tuning.webcamFOV * .pi / 360)

        if let face = frame.face {
            // An adult face box from Vision is roughly 15 cm wide.
            let measured = min(max(0.15 / max(face.width * 2 * tanH, 1e-3), 0.3), 3.0)
            estDistance = haveFace ? estDistance + (measured - estDistance) * 0.08 : measured
            if let pitch = face.pitch {
                let p = tuning.invertTilt ? -pitch : pitch
                estTilt += (min(max(p, -0.5), 0.5) - estTilt) * 0.05
            }
            let D = tuning.autoDistance ? estDistance : tuning.manualDistance
            let W = 2 * D * tanH
            let H = W * frameAspect
            let u = tuning.mirror ? 1 - face.centerX : face.centerX
            let local = SIMD2<Float>((u - 0.5) * W, (0.5 - face.centerY) * H)
            estFace = haveFace ? estFace + (local - estFace) * 0.15 : local
            haveFace = true
        }

        let D = tuning.autoDistance ? estDistance : tuning.manualDistance
        let W = 2 * D * tanH
        let H = W * frameAspect
        let tilt = (tuning.autoTilt ? estTilt : 0) + tuning.tiltOffset * .pi / 180

        let rotation = simd_quatf(angle: tilt, axis: [1, 0, 0])
        let forward = rotation.act([0, 0, -1])
        let up = rotation.act([0, 1, 0])
        let right = rotation.act([1, 0, 0])

        // Rig in its own space: camera at (0, 0, D), plane centre D metres along its view.
        let camera0 = SIMD3<Float>(0, 0, D)
        let planeCenter0 = camera0 + forward * D
        let face0 = planeCenter0 + right * estFace.x + up * estFace.y
        let target = SIMD3<Float>(tuning.followFace ? 0 : face0.x, tuning.headHeight, 0)
        let shift = target - face0

        rigCamera = camera0 + shift
        rigRotation = rotation
        headWorld = target

        surface?.width = W
        surface?.height = H
        personAnchor.position = planeCenter0 + shift
        personAnchor.orientation = rotation
        personAnchor.scale = [1, 1, 1]

        let summary = haveFace
            ? String(format: "Webcam %.2f m away, tilted %+.0f°", D, tilt * 180 / .pi)
            : "Looking for your face…"
        if frameCounter % 10 == 0, stats.matchSummary != summary { stats.matchSummary = summary }
    }

    /// Scene lights expressed for the relight shader, in the person's image space.
    private func relightParams() -> RelightParams {
        var p = RelightParams()
        let inverse = rigRotation.inverse
        func imageSpace(_ worldDir: SIMD3<Float>) -> SIMD4<Float> {
            var d = inverse.act(simd_normalize(worldDir))
            if tuning.mirror { d.x = -d.x }
            return SIMD4(d.x, d.y, d.z, 0)
        }
        func rgb(_ c: NSColor) -> SIMD3<Float> {
            let s = c.usingColorSpace(.sRGB) ?? c
            return [Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)]
        }

        p.keyDir = imageSpace(keyLight.position(relativeTo: nil) - headWorld)
        let key = rgb(Self.color(kelvin: tuning.keyKelvin)) * (tuning.keyIntensity / 60_000 * 0.75)
        p.keyColor = SIMD4(key, 0)

        p.rimDir = imageSpace(rimLight.position(relativeTo: nil) - headWorld)
        let rim = tuning.rimOn ? rgb(tuning.rimColor.nsColor) * (tuning.rimIntensity / 25_000 * 0.45) : .zero
        p.rimColor = SIMD4(rim, 0)

        let ambientLevel = 0.25 * pow(2, tuning.environmentLight) + tuning.fillIntensity / 1_000 * 0.4
        let wall = rgb(tuning.wallColor.nsColor)
        let ambient = (SIMD3<Float>(repeating: 0.7) + wall * 0.3) * ambientLevel
        p.ambient = SIMD4(ambient, 0)

        p.misc = [backgroundPlate == nil ? tuning.relight : 0, tuning.relief, 0, 1]
        if let plate = backgroundPlate, plate.name == "AIScenePlate" {
            p = aiScene.relightParams(base: p, mirror: tuning.mirror, amount: tuning.ai.matchLight)
        }
        return p
    }

    // MARK: - Background plate (used by other scene modes)

    /// Shows `entity` instead of the room.
    func addBackgroundPlate(_ entity: Entity) {
        removeBackgroundPlate()
        backgroundPlate = entity
        root.addChild(entity)
        environmentEntity?.isEnabled = false
    }

    func removeBackgroundPlate() {
        backgroundPlate?.removeFromParent()
        backgroundPlate = nil
        environmentEntity?.isEnabled = true
    }

    /// Called every rendered frame.
    func tick(_ dt: TimeInterval) {
        time += dt
        let t = Float(time)
        var offset = SIMD3<Float>.zero
        if !cameraLocked {
            let sway = tuning.sway
            let drag = dragOffset.clamped(lowerBound: SIMD2(repeating: -1), upperBound: SIMD2(repeating: 1)) * tuning.dragRange
            offset = rigRotation.act(SIMD3(sin(t * 0.5) * sway + drag.x, sin(t * 0.37) * sway * 0.5 + drag.y, 0))
        }
        camera.position = rigCamera + offset
        camera.orientation = rigRotation
        let vfov = 2 * atan(tan(tuning.webcamFOV * .pi / 360) * frameAspect) * 180 / .pi
        camera.camera.fieldOfViewInDegrees = vfov
        placeBackgroundPlate()
        applyTuning(force: false)
    }

    private func applyTuning(force: Bool) {
        guard force || appliedTuning != tuning else { return }
        appliedTuning = tuning

        rebuildEnvironmentIfNeeded()
        if backgroundPlate != nil { environmentEntity?.isEnabled = false }

        let az = tuning.keyAzimuth * .pi / 180
        let radius: Float = 2.4
        let keyPosition = SIMD3<Float>(sin(az) * radius, tuning.keyHeight, cos(az) * radius)
        keyLight.look(at: headWorld, from: keyPosition, relativeTo: nil)
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

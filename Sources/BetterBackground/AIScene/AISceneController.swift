import AppKit
import ImageIO
import CoreImage
import RealityKit
import SwiftUI
import UniformTypeIdentifiers

/// The AI scene: takes a snapshot of the camera, paints you out, has Stable Diffusion redraw the
/// room from a prompt (keeping its layout through the depth map), and shows the result behind
/// the live cutout, seen from the webcam's own angle.
@MainActor
final class AISceneController: ObservableObject {
    enum Status: Equatable {
        case idle
        case waitingForFrame
        case loadingModel
        case generating(step: Int, of: Int)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .waitingForFrame, .loadingModel, .generating: true
            default: false
            }
        }
    }

    let models = SceneModelStore()

    @Published private(set) var status: Status = .idle
    /// The last generated plate as the camera sees it (not mirrored).
    @Published private(set) var plate: CGImage?
    /// The camera picture with you painted out, and the depth map, that the last plate was made from.
    @Published private(set) var lastSnapshot: SceneSnapshot?
    @Published private(set) var lighting: PlateLighting?
    @Published private(set) var lastDuration: TimeInterval?

    private let generator = SceneGenerator()
    private var wantsSnapshot = false
    private var pendingSettings: AISceneSettings?
    private var lastRequestTime: Date?
    private var plateEntity: ModelEntity?
    private var plateMirrored: Bool?
    private var refreshTimer: Timer?

    init() {
        if let saved = Self.loadSavedPlate() {
            plate = saved
            lighting = PlateImage.analyzeLighting(saved)
        }
    }

    // MARK: - Requests

    /// Asks for a new plate from the next camera frame.
    func regenerate(_ settings: AISceneSettings) {
        guard models.state == .ready else { return }
        if status.isWorking { return }
        pendingSettings = settings
        wantsSnapshot = true
        status = .waitingForFrame
        lastRequestTime = Date()
    }

    func cancel() {
        wantsSnapshot = false
        generator.cancel()
        if status.isWorking { status = .idle }
    }

    /// Frees the several GB the model keeps in memory.
    func unloadModel() {
        generator.unload()
    }

    /// Starts or stops the timer for automatic refreshes.
    func updateRefresh(_ settings: AISceneSettings, current: @escaping () -> AISceneSettings) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard settings.enabled, let interval = settings.refresh.seconds else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = current()
                guard s.enabled, !self.status.isWorking else { return }
                self.regenerate(s)
            }
        }
    }

    // MARK: - Frames

    /// Called by the stage with every processed camera frame. Cheap unless a snapshot is wanted.
    func consume(_ frame: FrameData, invertDepth: Bool) {
        guard wantsSnapshot, var settings = pendingSettings, let folder = models.modelFolder else { return }
        wantsSnapshot = false
        pendingSettings = nil

        if settings.newSeedEachTime { settings.seed = Int.random(in: 0...Int(Int32.max)) }
        let size = models.imageSize
        let camera = frame.pixelBuffer, mask = frame.maskBuffer, depth = frame.depthBuffer
        let grid = frame.disparity.map { (values: $0, width: FrameProcessor.gridW, height: FrameProcessor.gridH) }
        let request = SceneRequest(
            prompt: settings.prompt,
            negativePrompt: settings.negativePrompt,
            strength: settings.strength,
            steps: settings.steps,
            guidance: settings.guidance,
            seed: UInt32(truncatingIfNeeded: settings.seed)
        )
        let generator = self.generator
        let started = Date()

        Task { [weak self] in
            // Painting out and depth filling run off the main thread.
            let snapshot = await Task.detached(priority: .userInitiated) {
                PlateImage.makeSnapshot(camera: camera, mask: mask, depth: depth, disparityGrid: grid,
                                        width: size.width, height: size.height, invertDepth: invertDepth)
            }.value
            guard let self else { return }
            guard let snapshot else {
                self.status = .failed("Could not read the camera frame.")
                return
            }
            self.lastSnapshot = snapshot
            do {
                let image = try await generator.generate(request, snapshot: snapshot, modelFolder: folder) { phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.status.isWorking else { return }
                        switch phase {
                        case .loading: self.status = .loadingModel
                        case let .step(s, n): self.status = .generating(step: s, of: n)
                        }
                    }
                }
                // Back to the camera's own aspect ratio (the model works at 3:2).
                let w = CVPixelBufferGetWidth(camera), h = CVPixelBufferGetHeight(camera)
                let outW = 1280, outH = max(1, Int(Double(outW) * Double(h) / Double(max(w, 1))))
                let plate = PlateImage.resized(image, width: outW, height: outH) ?? image
                self.plate = plate
                self.lighting = PlateImage.analyzeLighting(plate)
                self.lastDuration = Date().timeIntervalSince(started)
                self.plateMirrored = nil
                self.status = .idle
                Self.savePlate(plate)
            } catch is CancellationError {
                self.status = .idle
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Scene

    /// The plane that shows the plate behind the person, with its texture up to date.
    /// Returns nil when there's nothing to show.
    func plateEntity(mirror: Bool) -> ModelEntity? {
        guard let plate else { return nil }
        let entity: ModelEntity
        if let existing = plateEntity {
            entity = existing
        } else {
            entity = ModelEntity(mesh: .generatePlane(width: 1, height: 1))
            entity.name = "AIScenePlate"
            plateEntity = entity
        }
        if plateMirrored != mirror || entity.model?.materials.isEmpty != false {
            let shown = mirror ? (PlateImage.mirrored(plate) ?? plate) : plate
            if let texture = try? TextureResource.generate(from: shown, options: .init(semantic: .color)) {
                var material = UnlitMaterial(applyPostProcessToneMap: false)
                material.color = .init(tint: .white, texture: .init(texture))
                entity.model?.materials = [material]
                plateMirrored = mirror
            }
        }
        return entity
    }

    /// Lighting for the relight pass that makes the person sit in the generated room.
    /// Directions are in the camera's image space (x right, y up, z towards the viewer).
    func relightParams(base: RelightParams, mirror: Bool, amount: Float) -> RelightParams {
        guard let lighting else {
            var p = base
            p.misc.x = 0
            return p
        }
        var p = base
        let az = lighting.keyAzimuth * .pi / 180
        // The plate is analysed as shown (mirrored), the shader works on the unmirrored camera image.
        let x = mirror ? -sin(az) : sin(az)
        p.keyDir = SIMD4(x, 0.35, cos(az), 0)

        let hi = lighting.highlightColor / max(lighting.highlightColor.max(), 1e-3)
        let contrast = min(max(lighting.highlightColor.max() - lighting.brightness, 0.1), 0.8)
        p.keyColor = SIMD4(hi * (0.25 + contrast * 0.6), 0)
        p.rimColor = .zero

        let avg = lighting.averageColor
        let avgLum = max(0.2126 * avg.x + 0.7152 * avg.y + 0.0722 * avg.z, 0.04)
        let level = min(max(lighting.brightness * 1.5, 0.3), 1.0) * 0.7
        p.ambient = SIMD4(avg / avgLum * level, 0)
        p.misc.x = min(max(amount, 0), 1)
        return p
    }

    // MARK: - Saving

    func savePlateAs() {
        guard let plate else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "AI scene.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Self.writePNG(plate, to: url)
    }

    private static var savedPlateURL: URL {
        SceneModelStore.modelsRoot.deletingLastPathComponent().appending(path: "last-ai-scene.png")
    }

    private static func savePlate(_ image: CGImage) {
        try? FileManager.default.createDirectory(at: savedPlateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        writePNG(image, to: savedPlateURL)
    }

    private static func loadSavedPlate() -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(savedPlateURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

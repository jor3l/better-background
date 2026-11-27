import CoreGraphics
import CoreML
import Foundation
import StableDiffusion

/// What to generate.
struct SceneRequest {
    var prompt: String
    var negativePrompt: String
    /// 0...1: how much of the camera picture is replaced. 1 keeps only the room's layout (from depth).
    var strength: Float
    var steps: Int
    var guidance: Float
    var seed: UInt32
}

/// Runs Stable Diffusion 1.5 with the Depth ControlNet on Core ML, off the main thread.
/// The pipeline is loaded once and kept, since loading takes much longer than a generation.
final class SceneGenerator: @unchecked Sendable {
    enum Phase {
        case loading
        case step(Int, Int)
    }

    private let queue = DispatchQueue(label: "bb.ai-scene.generator", qos: .userInitiated)
    private var pipeline: StableDiffusionPipeline?
    private var loadedFolder: URL?
    private let cancelLock = NSLock()
    private var cancelRequested = false

    /// Generates a plate. `onPhase` is called on a background queue.
    func generate(
        _ request: SceneRequest,
        snapshot: SceneSnapshot,
        modelFolder: URL,
        onPhase: @escaping @Sendable (Phase) -> Void
    ) async throws -> CGImage {
        setCancelled(false)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let image = try run(request, snapshot: snapshot, modelFolder: modelFolder, onPhase: onPhase)
                    continuation.resume(returning: image)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the generation in progress after its current step.
    func cancel() {
        setCancelled(true)
    }

    /// Frees the model's memory (several GB). The next generation loads it again.
    func unload() {
        queue.async { [self] in
            pipeline?.unloadResources()
            pipeline = nil
            loadedFolder = nil
        }
    }

    private func setCancelled(_ value: Bool) {
        cancelLock.lock(); cancelRequested = value; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelRequested
    }

    private func run(
        _ request: SceneRequest,
        snapshot: SceneSnapshot,
        modelFolder: URL,
        onPhase: @escaping @Sendable (Phase) -> Void
    ) throws -> CGImage {
        if pipeline == nil || loadedFolder != modelFolder {
            onPhase(.loading)
            pipeline?.unloadResources()
            let config = MLModelConfiguration()
            // The "original" attention models run best on the GPU; split-einsum ones prefer the Neural Engine.
            config.computeUnits = modelFolder.path.contains("split") ? .cpuAndNeuralEngine : .cpuAndGPU
            let p = try StableDiffusionPipeline(
                resourcesAt: modelFolder,
                controlNet: [SceneModelStore.controlNetName],
                configuration: config,
                disableSafety: true,
                reduceMemory: false
            )
            try p.loadResources()
            pipeline = p
            loadedFolder = modelFolder
        }
        guard let pipeline else { throw SceneModelStore.error("The model could not be loaded.") }

        var config = StableDiffusionPipeline.Configuration(prompt: request.prompt)
        config.negativePrompt = request.negativePrompt
        config.startingImage = snapshot.paintedOut
        config.strength = min(max(request.strength, 0.05), 1)
        config.stepCount = request.steps
        config.guidanceScale = request.guidance
        config.seed = request.seed
        config.controlNetInputs = [snapshot.depth]
        config.schedulerType = .dpmSolverMultistepScheduler
        config.disableSafety = true
        config.useDenoisedIntermediates = false

        let images = try pipeline.generateImages(configuration: config) { progress in
            onPhase(.step(progress.step + 1, progress.stepCount))
            return !self.isCancelled
        }
        if isCancelled { throw CancellationError() }
        guard let image = images.compactMap({ $0 }).first else {
            throw SceneModelStore.error("The model returned no image.")
        }
        return image
    }
}

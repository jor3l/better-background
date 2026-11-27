import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import RealityKit
import simd

/// The person, drawn as a grid mesh displaced by depth. Its texture is the camera image relit on the GPU
/// (see RelightShader), with a soft alpha from the Vision mask. Mesh and textures update in place every frame.
@MainActor
final class PersonSurface {
    struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    let entity = ModelEntity()

    /// Size of the video frame in the scene, in metres. Set by the camera match every frame.
    var width: Float = 1.6
    var height: Float = 0.9

    private let gw = FrameProcessor.gridW
    private let gh = FrameProcessor.gridH
    private let mesh: LowLevelMesh

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var colorTexture: LowLevelTexture?
    private var alphaTexture: LowLevelTexture?
    private var textureSize = (0, 0)
    private var material = UnlitMaterial(applyPostProcessToneMap: false)
    private let flatDepth: MTLTexture?
    private let fullMask: MTLTexture?

    private var z: [Float]
    private(set) var lo: Float = 0
    private(set) var hi: Float = 1
    private var haveRange = false

    /// Normalised depth (0 far ... 1 near) of the last frame, for the debug preview.
    private(set) var lastNormalized: [Float] = []

    /// Set to describe the relight shader failing to compile, if it did.
    private(set) var shaderError: String?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "BetterBackground", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is not available"])
        }
        self.device = device
        self.commandQueue = queue
        do {
            pipeline = try RelightShader.makePipeline(device: device)
        } catch {
            pipeline = nil
            shaderError = "Relight shader failed: \(error.localizedDescription)"
        }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        flatDepth = Self.makeConstantTexture(device: device, format: .r32Float, value: 0)
        fullMask = Self.makeConstantTexture(device: device, format: .r32Float, value: 1)

        z = [Float](repeating: 0, count: gw * gh)

        var desc = LowLevelMesh.Descriptor()
        desc.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
        ]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        desc.vertexCapacity = gw * gh
        desc.indexCapacity = (gw - 1) * (gh - 1) * 6
        desc.indexType = .uint32
        mesh = try LowLevelMesh(descriptor: desc)

        material.color = .init(tint: .gray)
        entity.model = ModelComponent(mesh: try MeshResource(from: mesh), materials: [material])
        entity.name = "Person"
    }

    func update(with frame: FrameData, tuning: Tuning, lights: RelightParams) {
        updateMesh(frame, tuning: tuning)
        updateTextures(frame, tuning: tuning, lights: lights)
    }

    // MARK: - Textures

    private func makeTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> LowLevelTexture? {
        var desc = LowLevelTexture.Descriptor()
        desc.textureType = .type2D
        desc.pixelFormat = format
        desc.width = w
        desc.height = h
        desc.depth = 1
        desc.mipmapLevelCount = 1
        desc.textureUsage = [.shaderRead, .shaderWrite]
        return try? LowLevelTexture(descriptor: desc)
    }

    private func metalTexture(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        guard let cache = textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }

    private static func singleChannelFormat(_ buffer: CVPixelBuffer) -> MTLPixelFormat? {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8: return .r8Unorm
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16: return .r16Float
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32: return .r32Float
        default: return nil
        }
    }

    private static func makeConstantTexture(device: MTLDevice, format: MTLPixelFormat, value: Float) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        var v = value
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &v, bytesPerRow: 4)
        return texture
    }

    private func updateTextures(_ frame: FrameData, tuning: Tuning, lights: RelightParams) {
        let pixelBuffer = frame.pixelBuffer
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        if colorTexture == nil || alphaTexture == nil || textureSize != (w, h) {
            guard let color = makeTexture(.rgba16Float, w, h),
                  let alpha = makeTexture(.rgba8Unorm, w, h),
                  let colorResource = try? TextureResource(from: color),
                  let alphaResource = try? TextureResource(from: alpha) else { return }
            colorTexture = color
            alphaTexture = alpha
            textureSize = (w, h)
            material.color = .init(tint: .white, texture: .init(colorResource))
            material.blending = .transparent(opacity: .init(scale: 1, texture: .init(alphaResource)))
            entity.model?.materials = [material]
        }

        guard let pipeline, let colorTexture, let alphaTexture,
              let (camera, cvCamera) = metalTexture(pixelBuffer, .bgra8Unorm_srgb),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var keep: [CVMetalTexture] = [cvCamera]
        var depthTexture = flatDepth
        if let buffer = frame.depthBuffer, let format = Self.singleChannelFormat(buffer), let (t, cv) = metalTexture(buffer, format) {
            depthTexture = t
            keep.append(cv)
        }
        var maskTexture = fullMask
        if tuning.useMask, let buffer = frame.maskBuffer, let format = Self.singleChannelFormat(buffer), let (t, cv) = metalTexture(buffer, format) {
            maskTexture = t
            keep.append(cv)
        }

        var params = lights
        params.misc.z = lo
        params.misc.w = max(hi - lo, 1e-4)
        params.misc2 = [tuning.feather, tuning.useMask ? tuning.maskThreshold : 0, tuning.invertDepth ? 1 : 0, 0]
        if frame.depthBuffer == nil { params.misc.y = 0 }

        let outColor = colorTexture.replace(using: commandBuffer)
        let outAlpha = alphaTexture.replace(using: commandBuffer)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(camera, index: 0)
            encoder.setTexture(depthTexture, index: 1)
            encoder.setTexture(maskTexture, index: 2)
            encoder.setTexture(outColor, index: 3)
            encoder.setTexture(outAlpha, index: 4)
            encoder.setBytes(&params, length: MemoryLayout<RelightParams>.stride, index: 0)
            let tw = pipeline.threadExecutionWidth
            let th = max(pipeline.maxTotalThreadsPerThreadgroup / tw, 1)
            encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            encoder.endEncoding()
        }
        commandBuffer.addCompletedHandler { _ in
            _ = keep // keep the camera, depth and mask textures alive until the GPU is done
        }
        commandBuffer.commit()
    }

    // MARK: - Mesh

    private func updateMesh(_ frame: FrameData, tuning: Tuning) {
        let count = gw * gh
        let gw = self.gw, gh = self.gh
        let mask: [Float] = (tuning.useMask ? frame.mask : nil) ?? [Float](repeating: 1, count: count)
        let raw: [Float] = frame.disparity ?? [Float](repeating: 0, count: count)
        let threshold = tuning.useMask ? tuning.maskThreshold : 0

        // Robust range of the person's depth, smoothed over time so the surface doesn't pump.
        var inside: [Float] = []
        inside.reserveCapacity(count)
        for k in 0..<count where mask[k] >= threshold { inside.append(raw[k]) }
        if inside.count > 50 {
            inside.sort()
            let newLo = inside[Int(Float(inside.count - 1) * 0.03)]
            let newHi = inside[Int(Float(inside.count - 1) * 0.98)]
            if haveRange {
                lo += (newLo - lo) * 0.2
                hi += (newHi - hi) * 0.2
            } else {
                lo = newLo; hi = newHi; haveRange = true
            }
        }
        let span = max(hi - lo, 1e-4)
        let keep = 1 - min(max(tuning.smoothing, 0), 0.95)

        var normalized = [Float](repeating: 0, count: count)
        for k in 0..<count {
            var n = min(max((raw[k] - lo) / span, 0), 1)
            if tuning.invertDepth { n = 1 - n }
            if frame.disparity == nil { n = 0.5 }
            normalized[k] = n
        }
        lastNormalized = normalized

        // Outside the person, borrow depth from neighbouring person samples so soft edges don't fold back.
        var target = normalized
        var known = mask.map { $0 >= threshold }
        for _ in 0..<3 {
            var nextTarget = target
            var nextKnown = known
            for j in 0..<gh {
                for i in 0..<gw where !known[j * gw + i] {
                    var sum: Float = 0, n: Float = 0
                    for dj in -1...1 {
                        for di in -1...1 {
                            let x = i + di, y = j + dj
                            guard x >= 0, x < gw, y >= 0, y < gh, known[y * gw + x] else { continue }
                            sum += target[y * gw + x]; n += 1
                        }
                    }
                    if n > 0 {
                        nextTarget[j * gw + i] = sum / n
                        nextKnown[j * gw + i] = true
                    }
                }
            }
            target = nextTarget
            known = nextKnown
        }
        for k in 0..<count {
            let t = known[k] ? target[k] : 0
            z[k] += (t * tuning.depthScale - z[k]) * keep
        }

        let width = self.width, height = self.height
        let zs = self.z
        let mirror = tuning.mirror, flipV = tuning.flipV

        func src(_ i: Int, _ j: Int) -> Int {
            j * gw + (mirror ? (gw - 1 - i) : i)
        }
        func position(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let x = (Float(i) / Float(gw - 1) - 0.5) * width
            let y = (0.5 - Float(j) / Float(gh - 1)) * height
            return SIMD3(x, y, zs[src(i, j)])
        }

        var vertices = [Vertex]()
        vertices.reserveCapacity(count)
        for j in 0..<gh {
            for i in 0..<gw {
                let p = position(i, j)
                let dx = position(min(i + 1, gw - 1), j) - position(max(i - 1, 0), j)
                let dy = position(i, max(j - 1, 0)) - position(i, min(j + 1, gh - 1))
                var n = simd_cross(dx, dy)
                let len = simd_length(n)
                n = len > 1e-6 ? n / len : SIMD3(0, 0, 1)
                let ic = mirror ? (gw - 1 - i) : i
                let u = Float(ic) / Float(gw - 1)
                let v = Float(j) / Float(gh - 1)
                vertices.append(Vertex(position: p, normal: n, uv: SIMD2(u, flipV ? v : 1 - v)))
            }
        }

        // Keep triangles that touch the person; the soft alpha texture draws the real edge.
        let cull = tuning.useMask ? max(threshold * 0.25, 0.02) : -1
        let maxJump = tuning.edgeCut * tuning.depthScale + 0.01
        var indices = [UInt32]()
        indices.reserveCapacity((gw - 1) * (gh - 1) * 6)
        func add(_ a: (Int, Int), _ b: (Int, Int), _ c: (Int, Int)) {
            let sa = src(a.0, a.1), sb = src(b.0, b.1), sc = src(c.0, c.1)
            guard max(mask[sa], mask[sb], mask[sc]) >= cull else { return }
            let za = zs[sa], zb = zs[sb], zc = zs[sc]
            guard max(za, zb, zc) - min(za, zb, zc) <= maxJump else { return }
            indices.append(UInt32(a.1 * gw + a.0))
            indices.append(UInt32(b.1 * gw + b.0))
            indices.append(UInt32(c.1 * gw + c.0))
        }
        for j in 0..<(gh - 1) {
            for i in 0..<(gw - 1) {
                add((i, j), (i, j + 1), (i + 1, j))
                add((i + 1, j), (i, j + 1), (i + 1, j + 1))
            }
        }
        let indexCount = indices.count

        mesh.withUnsafeMutableBytes(bufferIndex: 0) { destination in
            vertices.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        mesh.withUnsafeMutableIndices { destination in
            indices.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }

        let bounds = BoundingBox(
            min: SIMD3(-width / 2, -height / 2, -0.05),
            max: SIMD3(width / 2, height / 2, tuning.depthScale + 0.05)
        )
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0, indexCount: indexCount, topology: .triangle, materialIndex: 0, bounds: bounds)
        ])
    }

    /// Grayscale image of the last normalised depth, for the debug overlay.
    func depthPreview(mirror: Bool) -> CGImage? {
        guard lastNormalized.count == gw * gh else { return nil }
        var bytes = [UInt8](repeating: 0, count: gw * gh)
        for j in 0..<gh {
            for i in 0..<gw {
                let ic = mirror ? (gw - 1 - i) : i
                bytes[j * gw + i] = UInt8(min(max(lastNormalized[j * gw + ic], 0), 1) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gw,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

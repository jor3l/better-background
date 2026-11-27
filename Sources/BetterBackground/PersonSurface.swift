import AppKit
import CoreGraphics
import CoreVideo
import Metal
import RealityKit
import simd

/// The person, drawn as a grid mesh displaced by depth and textured with the live camera image.
/// Both the mesh and the texture are updated in place every frame (LowLevelMesh / LowLevelTexture).
@MainActor
final class PersonSurface {
    struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    let entity = ModelEntity()

    /// Size of the video frame in the scene, in metres.
    let width: Float = 1.6
    let height: Float = 0.9
    let centerY: Float = 1.05

    private let gw = FrameProcessor.gridW
    private let gh = FrameProcessor.gridH
    private let mesh: LowLevelMesh

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var texture: LowLevelTexture?
    private var textureSize = (0, 0)
    private var material = PhysicallyBasedMaterial()

    private var z: [Float]
    private var lo: Float = 0
    private var hi: Float = 1
    private var haveRange = false

    /// Normalised depth (0 far ... 1 near) of the last frame, for the debug preview.
    private(set) var lastNormalized: [Float] = []

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "BetterBackground", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is not available"])
        }
        self.device = device
        self.commandQueue = queue
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

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

        material.baseColor = .init(tint: .gray)
        material.roughness = .init(floatLiteral: 0.7)
        material.metallic = .init(floatLiteral: 0)
        material.faceCulling = .none

        entity.model = ModelComponent(mesh: try MeshResource(from: mesh), materials: [material])
        entity.name = "Person"
    }

    func update(with frame: FrameData, tuning: Tuning) {
        updateTexture(frame.pixelBuffer, tuning: tuning)
        updateMesh(frame, tuning: tuning)
    }

    // MARK: - Texture

    private var lastMaterialKey: SIMD2<Float> = [-1, -1]

    private func updateTexture(_ pixelBuffer: CVPixelBuffer, tuning: Tuning) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        if texture == nil || textureSize != (w, h) {
            var desc = LowLevelTexture.Descriptor()
            desc.textureType = .type2D
            desc.pixelFormat = .bgra8Unorm_srgb
            desc.width = w
            desc.height = h
            desc.depth = 1
            desc.mipmapLevelCount = 1
            desc.textureUsage = [.shaderRead, .shaderWrite]
            guard let llt = try? LowLevelTexture(descriptor: desc),
                  let resource = try? TextureResource(from: llt) else { return }
            texture = llt
            textureSize = (w, h)
            material.baseColor = .init(tint: .white, texture: .init(resource))
            material.emissiveColor = .init(color: .white, texture: .init(resource))
            lastMaterialKey = [-1, -1]
        }

        let key = SIMD2<Float>(tuning.originalLight, tuning.personRoughness)
        if lastMaterialKey != key {
            material.emissiveIntensity = tuning.originalLight
            material.roughness = .init(floatLiteral: tuning.personRoughness)
            entity.model?.materials = [material]
            lastMaterialKey = key
        }

        guard let cache = textureCache, let texture else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm_srgb, w, h, 0, &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let destination = texture.replace(using: commandBuffer)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: source, to: destination)
            blit.endEncoding()
        }
        commandBuffer.addCompletedHandler { _ in
            _ = cvTexture // keep the camera texture alive until the GPU copy finishes
        }
        commandBuffer.commit()
    }

    // MARK: - Mesh

    private func updateMesh(_ frame: FrameData, tuning: Tuning) {
        let count = gw * gh
        let mask: [Float] = (tuning.useMask ? frame.mask : nil) ?? [Float](repeating: 1, count: count)
        let raw: [Float] = frame.disparity ?? [Float](repeating: 0, count: count)

        // Robust range of the person's depth, smoothed over time so the surface doesn't pump.
        var inside: [Float] = []
        inside.reserveCapacity(count)
        for k in 0..<count where mask[k] >= tuning.maskThreshold { inside.append(raw[k]) }
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
            z[k] += (n * tuning.depthScale - z[k]) * keep
        }
        lastNormalized = normalized

        // Build vertices and indices in plain arrays first, then copy them into the mesh buffers.
        let gw = self.gw, gh = self.gh
        let width = self.width, height = self.height, centerY = self.centerY
        let zs = self.z
        let mirror = tuning.mirror, flipV = tuning.flipV, threshold = tuning.maskThreshold

        // Image index for mesh column i, row j (mirrored like a selfie view by default).
        func src(_ i: Int, _ j: Int) -> Int {
            j * gw + (mirror ? (gw - 1 - i) : i)
        }
        func position(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let x = (Float(i) / Float(gw - 1) - 0.5) * width
            let y = centerY + (0.5 - Float(j) / Float(gh - 1)) * height
            return SIMD3(x, y, zs[src(i, j)])
        }

        var vertices = [Vertex]()
        vertices.reserveCapacity(gw * gh)
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

        let maxJump = tuning.edgeCut * tuning.depthScale + 0.01
        var indices = [UInt32]()
        indices.reserveCapacity((gw - 1) * (gh - 1) * 6)
        func add(_ a: (Int, Int), _ b: (Int, Int), _ c: (Int, Int)) {
            let sa = src(a.0, a.1), sb = src(b.0, b.1), sc = src(c.0, c.1)
            guard mask[sa] >= threshold, mask[sb] >= threshold, mask[sc] >= threshold else { return }
            let za = zs[sa], zb = zs[sb], zc = zs[sc]
            guard max(za, zb, zc) - min(za, zb, zc) <= maxJump else { return }
            indices.append(UInt32(a.1 * gw + a.0))
            indices.append(UInt32(b.1 * gw + b.0))
            indices.append(UInt32(c.1 * gw + c.0))
        }
        for j in 0..<(gh - 1) {
            for i in 0..<(gw - 1) {
                // Counter-clockwise when seen from the camera (+z).
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
            min: SIMD3(-width / 2, centerY - height / 2, -0.05),
            max: SIMD3(width / 2, centerY + height / 2, tuning.depthScale + 0.05)
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

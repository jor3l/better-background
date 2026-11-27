import CoreML
import CoreVideo
import Foundation
import Vision

/// One processed camera frame, sampled down to the surface grid.
struct FrameData {
    let pixelBuffer: CVPixelBuffer
    /// Relative inverse depth from Depth Anything (bigger = closer), gridW * gridH, image space, row 0 = top.
    let disparity: [Float]?
    /// Person mask 0...1, same layout.
    let mask: [Float]?
    /// Full-resolution Vision mask and depth output, for the playground's preview modes.
    let maskBuffer: CVPixelBuffer?
    let depthBuffer: CVPixelBuffer?
    let inferenceMs: Double
    /// Largest face, if any.
    let face: FaceInfo?
}

/// A detected face in image space (0...1, origin top-left, not mirrored).
struct FaceInfo {
    var centerX: Float
    var centerY: Float
    var width: Float
    var height: Float
    /// Head pitch in radians as Vision reports it, if available.
    var pitch: Float?
}

/// Runs Vision person segmentation and Depth Anything V2 on a frame.
final class FrameProcessor {
    static let gridW = 192
    static let gridH = 108
    static let modelName = "DepthAnythingV2SmallF16"

    private let segRequest: VNGeneratePersonSegmentationRequest
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private var depthRequest: VNCoreMLRequest?
    let modelStatus: String

    init() {
        segRequest = VNGeneratePersonSegmentationRequest()
        segRequest.qualityLevel = .balanced
        segRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8

        var status: String
        if let url = Self.modelURL() {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try MLModel(contentsOf: url, configuration: config)
                let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
                request.imageCropAndScaleOption = .scaleFill
                depthRequest = request
                status = "Depth Anything V2 Small loaded"
            } catch {
                status = "Could not load depth model: \(error.localizedDescription)"
            }
        } else {
            status = "Depth model not found in the app bundle"
        }
        modelStatus = status
    }

    static func modelURL() -> URL? {
        if let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            return url
        }
        if let path = ProcessInfo.processInfo.environment["BB_DEPTH_MODEL"] {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func process(_ pixelBuffer: CVPixelBuffer, quality: SegmentationQuality) -> FrameData {
        switch quality {
        case .fast: segRequest.qualityLevel = .fast
        case .balanced: segRequest.qualityLevel = .balanced
        case .accurate: segRequest.qualityLevel = .accurate
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var requests: [VNRequest] = [segRequest, faceRequest]
        if let depthRequest { requests.append(depthRequest) }

        let start = DispatchTime.now().uptimeNanoseconds
        try? handler.perform(requests)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        let w = Self.gridW, h = Self.gridH
        var mask: [Float]?
        let maskBuffer = segRequest.results?.first?.pixelBuffer
        if let maskBuffer {
            mask = Self.sample(maskBuffer, w: w, h: h)
        }

        var disparity: [Float]?
        var depthBuffer: CVPixelBuffer?
        if let result = depthRequest?.results?.first {
            if let obs = result as? VNPixelBufferObservation {
                depthBuffer = obs.pixelBuffer
                disparity = Self.sample(obs.pixelBuffer, w: w, h: h)
            } else if let obs = result as? VNCoreMLFeatureValueObservation,
                      let array = obs.featureValue.multiArrayValue {
                disparity = Self.sample(array, w: w, h: h)
            }
        }
        var face: FaceInfo?
        if let best = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            let box = best.boundingBox // normalised, origin bottom-left
            face = FaceInfo(
                centerX: Float(box.midX),
                centerY: Float(1 - box.midY),
                width: Float(box.width),
                height: Float(box.height),
                pitch: best.pitch.map { Float(truncating: $0) }
            )
        }

        return FrameData(pixelBuffer: pixelBuffer, disparity: disparity, mask: mask,
                         maskBuffer: maskBuffer, depthBuffer: depthBuffer, inferenceMs: ms, face: face)
    }

    // MARK: - Sampling

    /// Nearest-neighbour sample of a one-channel buffer onto a w*h grid whose corners hit the image corners.
    static func sample(_ buffer: CVPixelBuffer, w: Int, h: Int) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        let read: (UnsafeRawPointer, Int) -> Float
        switch format {
        case kCVPixelFormatType_OneComponent8:
            read = { row, x in Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255 }
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            read = { row, x in Float(row.loadUnaligned(fromByteOffset: x * 2, as: Float16.self)) }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            read = { row, x in row.loadUnaligned(fromByteOffset: x * 4, as: Float.self) }
        default:
            return nil
        }

        let xs = (0..<w).map { Int((Float($0) / Float(w - 1) * Float(bw - 1)).rounded()) }
        var out = [Float](repeating: 0, count: w * h)
        for j in 0..<h {
            let sy = Int((Float(j) / Float(h - 1) * Float(bh - 1)).rounded())
            let row = UnsafeRawPointer(base.advanced(by: sy * rowBytes))
            for i in 0..<w {
                out[j * w + i] = read(row, xs[i])
            }
        }
        return out
    }

    static func sample(_ array: MLMultiArray, w: Int, h: Int) -> [Float]? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let ah = shape[shape.count - 2], aw = shape[shape.count - 1]
        let sh = strides[strides.count - 2], sw = strides[strides.count - 1]

        let read: (Int) -> Float
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.assumingMemoryBound(to: Float.self)
            read = { p[$0] }
        case .float16:
            let p = array.dataPointer.assumingMemoryBound(to: Float16.self)
            read = { Float(p[$0]) }
        case .double:
            let p = array.dataPointer.assumingMemoryBound(to: Double.self)
            read = { Float(p[$0]) }
        default:
            return nil
        }

        var out = [Float](repeating: 0, count: w * h)
        for j in 0..<h {
            let sy = Int((Float(j) / Float(h - 1) * Float(ah - 1)).rounded())
            for i in 0..<w {
                let sx = Int((Float(i) / Float(w - 1) * Float(aw - 1)).rounded())
                out[j * w + i] = read(sy * sh + sx * sw)
            }
        }
        return out
    }
}

/// Runs the processor on the camera queue and never lets more than one result wait for the main thread.
final class Pipeline {
    private var processor: FrameProcessor?
    private let lock = NSLock()
    private var waitingForMain = false
    private var quality: SegmentationQuality = .balanced
    private var paused = false

    var onStatus: ((String) -> Void)?
    var onResult: ((FrameData) -> Void)?

    func setQuality(_ q: SegmentationQuality) {
        lock.lock(); quality = q; lock.unlock()
    }

    func setPaused(_ p: Bool) {
        lock.lock(); paused = p; lock.unlock()
    }

    /// Called on the camera queue.
    func handle(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let skip = waitingForMain || paused
        let quality = self.quality
        lock.unlock()
        if skip { return }

        if processor == nil {
            let p = FrameProcessor()
            processor = p
            onStatus?(p.modelStatus)
        }
        guard let processor else { return }
        let data = processor.process(pixelBuffer, quality: quality)

        lock.lock()
        waitingForMain = true
        lock.unlock()
        onResult?(data)
    }

    /// Called once the main thread has consumed a result.
    func resultConsumed() {
        lock.lock()
        waitingForMain = false
        lock.unlock()
    }
}

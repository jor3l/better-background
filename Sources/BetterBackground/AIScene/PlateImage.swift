import Accelerate
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// A small float image, `channels` values per pixel, row 0 = top.
struct FloatImage {
    var width: Int
    var height: Int
    var channels: Int
    var data: [Float]

    init(width: Int, height: Int, channels: Int, data: [Float]? = nil) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data ?? [Float](repeating: 0, count: width * height * channels)
    }

    subscript(x: Int, y: Int, c: Int) -> Float {
        get { data[(y * width + x) * channels + c] }
        set { data[(y * width + x) * channels + c] = newValue }
    }
}

/// Everything the generator needs from one camera frame, already resized to the model's size.
struct SceneSnapshot {
    /// Camera image with the person painted out, opaque sRGB.
    let paintedOut: CGImage
    /// Depth map for ControlNet (near = white), with the person filled in from the room behind.
    let depth: CGImage
    /// How much of the frame was the person (0...1), before dilation.
    let personCoverage: Double
    /// The unedited camera frame at model size, for the playground's preview.
    let original: CGImage
}

/// The lighting read from a generated plate, used to light the person to match.
struct PlateLighting: Equatable {
    /// Degrees, 0 = from the front, positive = from the right of the picture as shown.
    var keyAzimuth: Float
    /// Colour temperature of the brightest part of the picture.
    var keyKelvin: Float
    /// 0...1, average brightness of the picture.
    var brightness: Float
    /// Average colour of the picture (sRGB 0...1).
    var averageColor: SIMD3<Float>
    /// Colour of the brightest part of the picture (sRGB 0...1).
    var highlightColor: SIMD3<Float>
}

/// Image operations for the AI scene: painting the person out, depth for ControlNet, light analysis.
enum PlateImage {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Snapshot

    /// Builds the generator's inputs from a camera frame, its Vision person mask and the depth map.
    /// - Parameters:
    ///   - disparityGrid: fallback depth (gridW * gridH, bigger = closer) when there is no full depth buffer.
    static func makeSnapshot(
        camera: CVPixelBuffer,
        mask: CVPixelBuffer?,
        depth: CVPixelBuffer?,
        disparityGrid: (values: [Float], width: Int, height: Int)?,
        width: Int,
        height: Int,
        invertDepth: Bool
    ) -> SceneSnapshot? {
        let cameraImage = CIImage(cvPixelBuffer: camera)
        guard let rgb = render(cameraImage, width: width, height: height, channels: 4) else { return nil }

        // Person mask at model size, dilated so the halo around the person goes too.
        var person = FloatImage(width: width, height: height, channels: 1)
        if let mask, let m = render(CIImage(cvPixelBuffer: mask), width: width, height: height, channels: 1) {
            person = m
        }
        let coverage = Double(person.data.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }) / Double(max(person.data.count, 1))
        let hole = dilate(threshold(person, 0.25), radius: max(4, width / 40))
        let known = hole.data.map { 1 - $0 }

        // Paint the person out of the colour image by pulling in the surroundings.
        var colour = FloatImage(width: width, height: height, channels: 3)
        for i in 0..<(width * height) {
            colour.data[i * 3] = rgb.data[i * 4]
            colour.data[i * 3 + 1] = rgb.data[i * 4 + 1]
            colour.data[i * 3 + 2] = rgb.data[i * 4 + 2]
        }
        let paintedColour = pushPullFill(colour, weights: known)

        // Depth: full-resolution model output if we have it, otherwise the surface grid.
        var depthImage: FloatImage?
        if let depth {
            depthImage = render(CIImage(cvPixelBuffer: depth), width: width, height: height, channels: 1)
        }
        if depthImage == nil, let grid = disparityGrid {
            depthImage = resize(FloatImage(width: grid.width, height: grid.height, channels: 1, data: grid.values),
                                width: width, height: height)
        }
        var depthOut = depthImage ?? FloatImage(width: width, height: height, channels: 1,
                                                data: [Float](repeating: 0.5, count: width * height))
        depthOut = normalize(depthOut, weights: known, invert: invertDepth)
        depthOut = pushPullFill(depthOut, weights: known)
        depthOut = blur(depthOut, radius: 2)

        guard let paintedOut = cgImage(from: paintedColour),
              let depthCG = cgImage(from: depthOut),
              let original = cgImage(from: colour) else { return nil }
        return SceneSnapshot(paintedOut: paintedOut, depth: depthCG, personCoverage: coverage, original: original)
    }

    /// Renders a Core Image image stretched to width x height into floats (row 0 = top).
    static func render(_ image: CIImage, width: Int, height: Int, channels: Int) -> FloatImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        var out = FloatImage(width: width, height: height, channels: channels)
        let format: CIFormat = channels == 1 ? .Rf : .RGBAf
        let space: CGColorSpace? = channels == 1 ? nil : CGColorSpace(name: CGColorSpace.sRGB)
        out.data.withUnsafeMutableBytes { buffer in
            ciContext.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: width * channels * 4,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             format: format, colorSpace: space)
        }
        return out
    }

    // MARK: - Filters

    static func threshold(_ image: FloatImage, _ t: Float) -> FloatImage {
        var out = image
        out.data = image.data.map { $0 >= t ? 1 : 0 }
        return out
    }

    /// Separable max filter on a one-channel image.
    static func dilate(_ image: FloatImage, radius: Int) -> FloatImage {
        let w = image.width, h = image.height
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var m: Float = 0
                for k in max(0, x - radius)...min(w - 1, x + radius) { m = max(m, image.data[y * w + k]) }
                tmp[y * w + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m: Float = 0
                for k in max(0, y - radius)...min(h - 1, y + radius) { m = max(m, tmp[k * w + x]) }
                out[y * w + x] = m
            }
        }
        return FloatImage(width: w, height: h, channels: 1, data: out)
    }

    /// Separable box blur, any number of channels.
    static func blur(_ image: FloatImage, radius: Int) -> FloatImage {
        guard radius > 0 else { return image }
        let w = image.width, h = image.height, c = image.channels
        var tmp = image.data
        var out = image.data
        for y in 0..<h {
            for x in 0..<w {
                let lo = max(0, x - radius), hi = min(w - 1, x + radius)
                for ch in 0..<c {
                    var s: Float = 0
                    for k in lo...hi { s += image.data[(y * w + k) * c + ch] }
                    tmp[(y * w + x) * c + ch] = s / Float(hi - lo + 1)
                }
            }
        }
        for y in 0..<h {
            let lo = max(0, y - radius), hi = min(h - 1, y + radius)
            for x in 0..<w {
                for ch in 0..<c {
                    var s: Float = 0
                    for k in lo...hi { s += tmp[(k * w + x) * c + ch] }
                    out[(y * w + x) * c + ch] = s / Float(hi - lo + 1)
                }
            }
        }
        return FloatImage(width: w, height: h, channels: c, data: out)
    }

    /// Bilinear resize, any number of channels.
    static func resize(_ image: FloatImage, width: Int, height: Int) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: image.channels)
        let sx = Float(image.width) / Float(width), sy = Float(image.height) / Float(height)
        for y in 0..<height {
            let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
            let y0 = min(Int(fy), image.height - 1), y1 = min(y0 + 1, image.height - 1)
            let ty = fy - Float(y0)
            for x in 0..<width {
                let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                let x0 = min(Int(fx), image.width - 1), x1 = min(x0 + 1, image.width - 1)
                let tx = fx - Float(x0)
                for c in 0..<image.channels {
                    let a = image[x0, y0, c] * (1 - tx) + image[x1, y0, c] * tx
                    let b = image[x0, y1, c] * (1 - tx) + image[x1, y1, c] * tx
                    out[x, y, c] = a * (1 - ty) + b * ty
                }
            }
        }
        return out
    }

    /// Rescales depth to 0...1 using the known (non-person) pixels' 2nd and 98th percentiles.
    static func normalize(_ image: FloatImage, weights: [Float], invert: Bool) -> FloatImage {
        var values = zip(image.data, weights).compactMap { $1 > 0.5 && $0.isFinite ? $0 : nil }
        if values.count < 100 { values = image.data.filter(\.isFinite) }
        guard !values.isEmpty else { return image }
        values.sort()
        let lo = values[Int(Float(values.count - 1) * 0.02)]
        let hi = values[Int(Float(values.count - 1) * 0.98)]
        let span = max(hi - lo, 1e-5)
        var out = image
        out.data = image.data.map { v in
            var n = v.isFinite ? min(max((v - lo) / span, 0), 1) : 0
            if invert { n = 1 - n }
            return n
        }
        return out
    }

    /// Fills pixels whose weight is 0 from their surroundings (push-pull / pyramid hole filling).
    /// Pixels with weight 1 are kept exactly; the filled area is a smooth blend of the edges around it.
    static func pushPullFill(_ image: FloatImage, weights: [Float]) -> FloatImage {
        let c = image.channels
        // Level 0: premultiplied values and weights.
        var levels: [(img: FloatImage, w: [Float])] = []
        var pm = image
        for i in 0..<(image.width * image.height) {
            for ch in 0..<c { pm.data[i * c + ch] *= weights[i] }
        }
        levels.append((pm, weights))

        // Push: halve until tiny, summing premultiplied colour and weight (weights capped at 1).
        while let last = levels.last, last.img.width > 2 || last.img.height > 2 {
            let w = max(1, (last.img.width + 1) / 2), h = max(1, (last.img.height + 1) / 2)
            var img = FloatImage(width: w, height: h, channels: c)
            var wt = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var sw: Float = 0
                    var sc = [Float](repeating: 0, count: c)
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let px = min(x * 2 + dx, last.img.width - 1), py = min(y * 2 + dy, last.img.height - 1)
                            let i = py * last.img.width + px
                            sw += last.w[i]
                            for ch in 0..<c { sc[ch] += last.img.data[i * c + ch] }
                        }
                    }
                    let k = y * w + x
                    if sw > 0 {
                        let norm = min(sw, 1) / sw
                        for ch in 0..<c { img.data[k * c + ch] = sc[ch] * norm }
                        wt[k] = min(sw, 1)
                    }
                }
            }
            levels.append((img, wt))
        }

        // Pull: from coarse to fine, fill what's missing at each level from the level above.
        var filled = unpremultiply(levels[levels.count - 1])
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let level = levels[l]
            let up = resize(filled, width: level.img.width, height: level.img.height)
            var next = FloatImage(width: level.img.width, height: level.img.height, channels: c)
            for i in 0..<(level.img.width * level.img.height) {
                let wi = level.w[i]
                for ch in 0..<c {
                    next.data[i * c + ch] = level.img.data[i * c + ch] + (1 - wi) * up.data[i * c + ch]
                }
            }
            filled = next
        }
        return filled
    }

    private static func unpremultiply(_ level: (img: FloatImage, w: [Float])) -> FloatImage {
        var out = level.img
        let c = out.channels
        let mean: [Float] = (0..<c).map { ch in
            var s: Float = 0, n: Float = 0
            for i in 0..<level.w.count where level.w[i] > 0 { s += level.img.data[i * c + ch] / level.w[i]; n += 1 }
            return n > 0 ? s / n : 0.5
        }
        for i in 0..<level.w.count {
            for ch in 0..<c {
                out.data[i * c + ch] = level.w[i] > 0 ? level.img.data[i * c + ch] / level.w[i] : mean[ch]
            }
        }
        return out
    }

    // MARK: - Conversion

    /// Opaque sRGB image from a 1-channel (grey) or 3/4-channel float image.
    static func cgImage(from image: FloatImage) -> CGImage? {
        let w = image.width, h = image.height, c = image.channels
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for ch in 0..<3 {
                let v = c == 1 ? image.data[i] : image.data[i * c + ch]
                bytes[i * 4 + ch] = UInt8(min(max(v, 0), 1) * 255 + 0.5)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// RGB floats (0...1) of a CGImage at a given size.
    static func floats(from image: CGImage, width: Int, height: Int) -> FloatImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        var out = FloatImage(width: width, height: height, channels: 3)
        for i in 0..<(width * height) {
            for ch in 0..<3 { out.data[i * 3 + ch] = Float(bytes[i * 4 + ch]) / 255 }
        }
        return out
    }

    /// The image flipped left to right.
    static func mirrored(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image).oriented(.upMirrored)
        return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The image stretched to a new size.
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let f = floats(from: image, width: width, height: height) else { return nil }
        return cgImage(from: f)
    }

    // MARK: - Lighting

    /// Reads where the light comes from and its colour, from the plate as it is shown.
    static func analyzeLighting(_ plate: CGImage) -> PlateLighting? {
        let w = 96, h = 64
        guard let img = floats(from: plate, width: w, height: h) else { return nil }
        var lum = [Float](repeating: 0, count: w * h)
        var sum = SIMD3<Float>(0, 0, 0)
        for i in 0..<(w * h) {
            let c = SIMD3(img.data[i * 3], img.data[i * 3 + 1], img.data[i * 3 + 2])
            sum += c
            lum[i] = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        }
        let average = sum / Float(w * h)

        // Left/right balance of brightness, weighted towards the upper part of the picture
        // where lamps and windows usually are.
        var left: Float = 0, right: Float = 0
        for y in 0..<h {
            let wy: Float = y < h * 2 / 3 ? 1 : 0.4
            for x in 0..<w {
                let v = lum[y * w + x] * wy
                if x < w / 3 { left += v } else if x >= w - w / 3 { right += v }
            }
        }
        let balance = (right - left) / max(right + left, 1e-4)
        let azimuth = min(max(balance * 140, -70), 70)

        // Colour of the brightest 4% of the picture.
        let sorted = lum.enumerated().sorted { $0.element > $1.element }
        let top = sorted.prefix(max(1, lum.count / 25))
        var hi = SIMD3<Float>(0, 0, 0)
        for (i, _) in top { hi += SIMD3(img.data[i * 3], img.data[i * 3 + 1], img.data[i * 3 + 2]) }
        hi /= Float(top.count)

        return PlateLighting(
            keyAzimuth: azimuth,
            keyKelvin: kelvin(matching: hi),
            brightness: lum.reduce(0, +) / Float(lum.count),
            averageColor: average,
            highlightColor: hi
        )
    }

    /// The black-body temperature whose colour has the closest red/blue balance to `rgb`.
    static func kelvin(matching rgb: SIMD3<Float>) -> Float {
        let target = rgb / max(rgb.max(), 1e-4)
        var best: Float = 5_500, bestErr = Float.greatestFiniteMagnitude
        for k in stride(from: Float(1_800), through: 10_000, by: 100) {
            let c = blackBody(kelvin: k)
            let d = c - target
            let err = d.x * d.x + d.z * d.z * 1.5 + d.y * d.y * 0.5
            if err < bestErr { bestErr = err; best = k }
        }
        return best
    }

    /// Approximate sRGB colour of a black body (max channel = 1).
    static func blackBody(kelvin: Float) -> SIMD3<Float> {
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
        func c(_ v: Double) -> Float { Float(min(max(v, 0), 255) / 255) }
        return SIMD3(c(r), c(g), c(b))
    }
}

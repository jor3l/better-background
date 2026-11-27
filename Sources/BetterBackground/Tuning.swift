import AppKit
import SwiftUI

/// An sRGB colour that can be saved with the settings.
struct RGBColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
}

enum EnvironmentKind: String, Codable, CaseIterable, Identifiable {
    case livingRoom, studio, neon, office
    var id: String { rawValue }

    var title: String {
        switch self {
        case .livingRoom: "Living room"
        case .studio: "Dark studio"
        case .neon: "Neon den"
        case .office: "Bright office"
        }
    }
}

enum SegmentationQuality: String, Codable, CaseIterable, Identifiable {
    case fast, balanced, accurate
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CaptureResolution: String, Codable, CaseIterable, Identifiable {
    case p720, p1080
    var id: String { rawValue }
    var title: String { self == .p720 ? "1280 × 720" : "1920 × 1080" }
}

/// Every setting the playground exposes. Saved between launches and in named presets.
struct Tuning: Codable, Equatable {
    // Camera
    var resolution: CaptureResolution = .p1080
    var mirror = true
    var flipV = false

    // Person mask
    var useMask = true
    var segmentationQuality: SegmentationQuality = .balanced
    var maskThreshold: Float = 0.5
    var edgeCut: Float = 0.35           // drop triangles that stretch across big depth jumps
    var feather: Float = 1.5            // softness of the cutout edge, in camera pixels

    // Depth
    var depthScale: Float = 0.25        // metres between farthest and nearest point of the person
    var smoothing: Float = 0.6          // temporal smoothing of the surface (0 = none)
    var invertDepth = false             // flip if the model's output turns out to be depth, not disparity

    // Person look
    var relight: Float = 0.75           // 0 = camera image as is, 1 = fully relit by the scene
    var relief: Float = 2.5             // how strongly depth bends the lighting on the face

    // Camera match: the virtual camera sits where your webcam is
    var webcamFOV: Float = 68           // horizontal field of view of your webcam, degrees
    var autoDistance = true             // estimate how far you are from the face size
    var manualDistance: Float = 0.7     // metres, used when autoDistance is off
    var autoTilt = true                 // estimate the webcam's tilt from your head pose
    var invertTilt = false
    var tiltOffset: Float = 0           // degrees added to the detected (or zero) tilt
    var headHeight: Float = 1.2         // where your face sits in the room, metres
    var followFace = true               // keep your face centred in the room as you move

    // Lighting
    var keyIntensity: Float = 60_000
    var keyAzimuth: Float = 35          // degrees, 0 = straight in front
    var keyHeight: Float = 2.2
    var keyKelvin: Float = 3_800
    var keyShadows = true
    var rimOn = true
    var rimIntensity: Float = 25_000
    var rimColor = RGBColor(0.3, 0.6, 1.0)
    var fillIntensity: Float = 300      // lux, soft directional fill from the front
    var environmentLight: Float = 0     // image-based light exposure (EV)

    // Environment
    var environment: EnvironmentKind = .livingRoom
    var wallColor = RGBColor(0.78, 0.74, 0.68)
    var floorColor = RGBColor(0.42, 0.30, 0.22)
    var accentColor = RGBColor(0.75, 0.85, 1.0)
    var showProps = true
    var showDesk = false

    // View
    var sway: Float = 0.02              // automatic camera drift in metres, small parallax only
    var dragRange: Float = 0.15         // how far dragging can move the camera, metres

    /// Defaults for a given environment: colours and lighting that suit it.
    static func defaults(for kind: EnvironmentKind) -> Tuning {
        var t = Tuning()
        t.environment = kind
        switch kind {
        case .livingRoom:
            break
        case .studio:
            t.wallColor = RGBColor(0.12, 0.12, 0.14)
            t.floorColor = RGBColor(0.08, 0.08, 0.09)
            t.accentColor = RGBColor(1.0, 0.55, 0.2)
            t.keyIntensity = 90_000
            t.keyAzimuth = 45
            t.keyKelvin = 5_200
            t.rimColor = RGBColor(1.0, 0.6, 0.3)
            t.rimIntensity = 40_000
            t.fillIntensity = 80
            t.environmentLight = -2
        case .neon:
            t.wallColor = RGBColor(0.1, 0.08, 0.14)
            t.floorColor = RGBColor(0.06, 0.05, 0.08)
            t.accentColor = RGBColor(1.0, 0.2, 0.8)
            t.keyIntensity = 40_000
            t.keyAzimuth = -40
            t.keyKelvin = 7_500
            t.rimColor = RGBColor(0.1, 0.9, 1.0)
            t.rimIntensity = 60_000
            t.fillIntensity = 50
            t.environmentLight = -2.5
            t.relight = 0.85
        case .office:
            t.wallColor = RGBColor(0.92, 0.92, 0.9)
            t.floorColor = RGBColor(0.55, 0.55, 0.52)
            t.accentColor = RGBColor(0.85, 0.92, 1.0)
            t.keyIntensity = 50_000
            t.keyAzimuth = 25
            t.keyKelvin = 5_600
            t.rimOn = false
            t.fillIntensity = 600
            t.environmentLight = 0.5
        }
        return t
    }

    /// Keeps the camera, mask and depth settings, takes the look of another environment.
    func applyingEnvironment(_ kind: EnvironmentKind) -> Tuning {
        let d = Tuning.defaults(for: kind)
        var t = self
        t.environment = kind
        t.wallColor = d.wallColor
        t.floorColor = d.floorColor
        t.accentColor = d.accentColor
        t.keyIntensity = d.keyIntensity
        t.keyAzimuth = d.keyAzimuth
        t.keyKelvin = d.keyKelvin
        t.rimOn = d.rimOn
        t.rimColor = d.rimColor
        t.rimIntensity = d.rimIntensity
        t.fillIntensity = d.fillIntensity
        t.environmentLight = d.environmentLight
        t.relight = d.relight
        return t
    }
}

/// A named, saved copy of every setting.
struct SavedPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tuning: Tuning
}

/// Reads and writes settings and presets in UserDefaults.
enum SettingsStore {
    private static let tuningKey = "tuning.v2"
    private static let presetsKey = "presets.v1"
    private static let cameraKey = "camera.v1"

    static func loadTuning() -> Tuning {
        guard let data = UserDefaults.standard.data(forKey: tuningKey),
              let t = try? JSONDecoder().decode(Tuning.self, from: data) else { return Tuning() }
        return t
    }

    static func save(_ tuning: Tuning) {
        if let data = try? JSONEncoder().encode(tuning) {
            UserDefaults.standard.set(data, forKey: tuningKey)
        }
    }

    static func loadPresets() -> [SavedPreset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let p = try? JSONDecoder().decode([SavedPreset].self, from: data) else { return [] }
        return p
    }

    static func save(_ presets: [SavedPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    static var cameraID: String {
        get { UserDefaults.standard.string(forKey: cameraKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cameraKey) }
    }
}

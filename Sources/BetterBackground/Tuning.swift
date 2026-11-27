import Foundation

/// Every knob the proof of concept exposes in the side panel.
struct Tuning: Equatable {
    // Depth
    var depthScale: Float = 0.35        // metres between farthest and nearest point of the person
    var smoothing: Float = 0.6          // temporal smoothing of the surface (0 = none)
    var invertDepth = false             // flip if the model's output turns out to be depth, not disparity
    var useMask = true                  // cut the person out with Vision segmentation
    var maskThreshold: Float = 0.5
    var edgeCut: Float = 0.35           // drop triangles that stretch across big depth jumps

    // Image
    var mirror = true
    var flipV = false
    var originalLight: Float = 0.2      // how much of the camera image is shown unlit

    // Lighting
    var keyIntensity: Float = 60_000
    var keyAzimuth: Float = 35          // degrees, 0 = straight in front
    var keyKelvin: Float = 3_800
    var rimOn = true
    var rimIntensity: Float = 25_000
    var environment: Float = 0          // image-based light exposure (EV)

    // View
    var sway: Float = 0.15              // automatic camera drift in metres, shows parallax
}

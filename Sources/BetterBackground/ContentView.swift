import RealityKit
import SwiftUI

struct ContentView: View {
    @StateObject private var stage = Stage()

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RealityView { content in
                    content.add(stage.root)
                    let stage = stage
                    stage.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                        MainActor.assumeIsolated { stage.tick(event.deltaTime) }
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            stage.dragOffset = SIMD2(Float(value.translation.width) * 0.003,
                                                     Float(-value.translation.height) * 0.002)
                        }
                        .onEnded { _ in stage.dragOffset = .zero }
                )
                StatsOverlay(stats: stage.stats, status: stage.status)
                    .padding(10)
            }
            Divider()
            ControlsPanel(stage: stage)
                .frame(width: 300)
        }
        .task { stage.start() }
    }
}

struct StatsOverlay: View {
    @ObservedObject var stats: DebugStats
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.0f fps · model %.0f ms", stats.fps, stats.inferenceMs))
                .monospacedDigit()
            Text(stats.modelStatus)
            Text(status)
            if let preview = stats.depthPreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 192, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.caption)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ControlsPanel: View {
    @ObservedObject var stage: Stage

    var body: some View {
        Form {
            Section("Camera") {
                Picker("Device", selection: $stage.selectedCamera) {
                    Text("Default").tag("")
                    ForEach(stage.cameras) { Text($0.name).tag($0.id) }
                }
                Toggle("Mirror", isOn: $stage.tuning.mirror)
                Toggle("Flip image vertically", isOn: $stage.tuning.flipV)
            }
            Section("Depth") {
                slider("Depth strength", $stage.tuning.depthScale, 0...1, "%.2f m")
                slider("Smoothing", $stage.tuning.smoothing, 0...0.95, "%.2f")
                slider("Edge cut", $stage.tuning.edgeCut, 0.05...1, "%.2f")
                Toggle("Cut out person (Vision mask)", isOn: $stage.tuning.useMask)
                slider("Mask threshold", $stage.tuning.maskThreshold, 0.05...0.95, "%.2f")
                Toggle("Invert depth", isOn: $stage.tuning.invertDepth)
            }
            Section("Lighting") {
                slider("Key light", $stage.tuning.keyIntensity, 0...200_000, "%.0f lm")
                slider("Key direction", $stage.tuning.keyAzimuth, -90...90, "%.0f°")
                slider("Key colour", $stage.tuning.keyKelvin, 1_800...9_000, "%.0f K")
                Toggle("Blue rim light", isOn: $stage.tuning.rimOn)
                slider("Rim light", $stage.tuning.rimIntensity, 0...100_000, "%.0f lm")
                slider("Environment", $stage.tuning.environment, -4...4, "%.1f EV")
                slider("Original camera light", $stage.tuning.originalLight, 0...1, "%.2f")
            }
            Section("View") {
                slider("Camera sway", $stage.tuning.sway, 0...0.6, "%.2f m")
                Text("Drag the scene to move the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

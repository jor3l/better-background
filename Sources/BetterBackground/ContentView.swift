import RealityKit
import SwiftUI

/// The camera playground: the live preview on the left, every setting on the right.
struct ContentView: View {
    @StateObject private var stage = Stage()

    var body: some View {
        HSplitView {
            PreviewArea(stage: stage)
                .frame(minWidth: 560, minHeight: 400)
            SettingsSidebar(stage: stage)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        }
        .task { stage.start() }
    }
}

// MARK: - Preview

struct PreviewArea: View {
    @ObservedObject var stage: Stage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $stage.previewMode) {
                    ForEach(PreviewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                Spacer()

                Toggle("Stats", isOn: $stage.showStats)
                    .toggleStyle(.button)
                Button {
                    stage.paused.toggle()
                } label: {
                    Label(stage.paused ? "Resume" : "Pause", systemImage: stage.paused ? "play.fill" : "pause.fill")
                }
            }
            .padding(10)

            Divider()

            ZStack(alignment: .topLeading) {
                SceneView(stage: stage)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if stage.previewMode != .composite {
                    FlatPreview(preview: stage.preview, mode: stage.previewMode)
                }
                if stage.showStats {
                    StatsOverlay(stats: stage.stats)
                        .padding(10)
                }
            }
            .background(Color.black)
        }
    }
}

/// The RealityKit view. Kept in its own view so panel changes never re-create the scene.
struct SceneView: View {
    let stage: Stage

    var body: some View {
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
    }
}

struct FlatPreview: View {
    @ObservedObject var preview: PreviewImage
    let mode: PreviewMode

    var body: some View {
        ZStack {
            Color.black
            if let image = preview.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(mode == .depth ? .medium : .high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("Waiting for frames…").foregroundStyle(.secondary)
            }
        }
    }
}

struct StatsOverlay: View {
    @ObservedObject var stats: DebugStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.0f fps · model %.0f ms · person %.0f%%", stats.fps, stats.inferenceMs, stats.maskCoverage * 100))
                .monospacedDigit()
            Text(stats.modelStatus)
            Text(stats.cameraStatus)
            Text(stats.matchSummary)
            if let preview = stats.depthPreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.caption)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings

enum SettingsSection: String, CaseIterable, Identifiable {
    case environment, ai, lighting, person, camera, view, presets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .environment: "Scene"
        case .ai: "AI scene"
        case .lighting: "Light"
        case .person: "Person"
        case .camera: "Camera"
        case .view: "View"
        case .presets: "Presets"
        }
    }
    var icon: String {
        switch self {
        case .environment: "cube"
        case .ai: "wand.and.stars"
        case .lighting: "lightbulb"
        case .person: "person.crop.rectangle"
        case .camera: "camera"
        case .view: "eye"
        case .presets: "square.and.arrow.down"
        }
    }
}

struct SettingsSidebar: View {
    @ObservedObject var stage: Stage
    @State private var section: SettingsSection = .environment

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { s in
                    Button {
                        section = s
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: s.icon)
                            Text(s.title).font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(section == s ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Divider()

            Form {
                switch section {
                case .environment: EnvironmentPanel(stage: stage)
                case .ai: AIScenePanel(stage: stage, controller: stage.aiScene, models: stage.aiScene.models)
                case .lighting: LightingPanel(stage: stage)
                case .person: PersonPanel(stage: stage)
                case .camera: CameraPanel(stage: stage)
                case .view: ViewPanel(stage: stage)
                case .presets: PresetsPanel(stage: stage)
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct EnvironmentPanel: View {
    @ObservedObject var stage: Stage

    var body: some View {
        Section("Environment") {
            Picker("Scene", selection: Binding(
                get: { stage.tuning.environment },
                set: { stage.selectEnvironment($0) }
            )) {
                ForEach(EnvironmentKind.allCases) { Text($0.title).tag($0) }
            }
            Text("Picking a scene also loads its colours and lighting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Colours") {
            colorRow("Walls", \.wallColor)
            colorRow("Floor", \.floorColor)
            colorRow("Accent / windows", \.accentColor)
        }
        Section("Objects") {
            Toggle("Props", isOn: $stage.tuning.showProps)
            Toggle("Desk in front", isOn: $stage.tuning.showDesk)
        }
        Section {
            Button("Restore this scene's colours and lighting") { stage.resetLookToEnvironment() }
        }
    }

    private func colorRow(_ title: String, _ key: WritableKeyPath<Tuning, RGBColor>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { stage.tuning[keyPath: key].color },
            set: { stage.tuning[keyPath: key] = RGBColor($0) }
        ), supportsOpacity: false)
    }
}

struct LightingPanel: View {
    @ObservedObject var stage: Stage

    var body: some View {
        Section("Key light") {
            SliderRow("Intensity", $stage.tuning.keyIntensity, 0...200_000, "%.0f lm")
            SliderRow("Direction", $stage.tuning.keyAzimuth, -90...90, "%.0f°")
            SliderRow("Height", $stage.tuning.keyHeight, 0.5...3.0, "%.2f m")
            SliderRow("Colour temperature", $stage.tuning.keyKelvin, 1_800...9_000, "%.0f K")
            Toggle("Shadows", isOn: $stage.tuning.keyShadows)
        }
        Section("Rim light") {
            Toggle("On", isOn: $stage.tuning.rimOn)
            SliderRow("Intensity", $stage.tuning.rimIntensity, 0...150_000, "%.0f lm")
            ColorPicker("Colour", selection: Binding(
                get: { stage.tuning.rimColor.color },
                set: { stage.tuning.rimColor = RGBColor($0) }
            ), supportsOpacity: false)
        }
        Section("Ambient") {
            SliderRow("Front fill", $stage.tuning.fillIntensity, 0...2_000, "%.0f lx")
            SliderRow("Environment light", $stage.tuning.environmentLight, -4...4, "%.1f EV")
        }
    }
}

struct PersonPanel: View {
    @ObservedObject var stage: Stage

    var body: some View {
        Section("Cutout") {
            Toggle("Cut out person", isOn: $stage.tuning.useMask)
            Picker("Mask quality", selection: $stage.tuning.segmentationQuality) {
                ForEach(SegmentationQuality.allCases) { Text($0.title).tag($0) }
            }
            SliderRow("Mask threshold", $stage.tuning.maskThreshold, 0.05...0.95, "%.2f")
            SliderRow("Edge cut", $stage.tuning.edgeCut, 0.05...1, "%.2f")
        }
        Section("Depth") {
            SliderRow("Depth strength", $stage.tuning.depthScale, 0...1, "%.2f m")
            SliderRow("Smoothing", $stage.tuning.smoothing, 0...0.95, "%.2f")
            Toggle("Invert depth", isOn: $stage.tuning.invertDepth)
        }
        Section("Look") {
            SliderRow("Relight by scene", $stage.tuning.relight, 0...1, "%.2f")
            SliderRow("Face relief", $stage.tuning.relief, 0...6, "%.1f")
            SliderRow("Edge softness", $stage.tuning.feather, 0...5, "%.1f px")
            Text("Relight 0 shows your camera image as is; 1 lights you only with the scene's lights.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CameraPanel: View {
    @ObservedObject var stage: Stage

    var body: some View {
        Section("Device") {
            Picker("Camera", selection: $stage.selectedCamera) {
                Text("Default").tag("")
                ForEach(stage.cameras) { Text($0.name).tag($0.id) }
            }
            Button("Refresh camera list") { stage.refreshCameras() }
            Picker("Resolution", selection: $stage.tuning.resolution) {
                ForEach(CaptureResolution.allCases) { Text($0.title).tag($0) }
            }
        }
        Section("Image") {
            Toggle("Mirror", isOn: $stage.tuning.mirror)
            Toggle("Flip vertically", isOn: $stage.tuning.flipV)
        }
    }
}

struct ViewPanel: View {
    @ObservedObject var stage: Stage

    var body: some View {
        Section("Match my webcam") {
            SliderRow("Webcam field of view", $stage.tuning.webcamFOV, 40...110, "%.0f°")
            Toggle("Estimate distance from my face", isOn: $stage.tuning.autoDistance)
            if !stage.tuning.autoDistance {
                SliderRow("Distance to webcam", $stage.tuning.manualDistance, 0.3...2.5, "%.2f m")
            }
            Toggle("Estimate webcam tilt from my head", isOn: $stage.tuning.autoTilt)
            if stage.tuning.autoTilt {
                Toggle("Flip detected tilt", isOn: $stage.tuning.invertTilt)
            }
            SliderRow("Tilt adjustment", $stage.tuning.tiltOffset, -30...30, "%+.0f°")
            SliderRow("Head height in the room", $stage.tuning.headHeight, 0.8...1.8, "%.2f m")
            Toggle("Keep me centred in the room", isOn: $stage.tuning.followFace)
            Text("The virtual camera sits where your webcam is, so the room is seen from the same angle as you. If the room looks tilted the wrong way, use Flip detected tilt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Parallax") {
            SliderRow("Sway", $stage.tuning.sway, 0...0.1, "%.2f m")
            SliderRow("Drag range", $stage.tuning.dragRange, 0...0.4, "%.2f m")
            Text("Drag the preview to look around a little. Small moves keep the depth believable.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PresetsPanel: View {
    @ObservedObject var stage: Stage
    @State private var name = ""

    var body: some View {
        Section("Save current settings") {
            HStack {
                TextField("Preset name", text: $name)
                Button("Save") {
                    stage.savePreset(named: name)
                    name = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Settings are also saved automatically and restored on the next launch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Saved presets") {
            if stage.presets.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(stage.presets) { preset in
                HStack {
                    Text(preset.name)
                    Spacer()
                    Button("Load") { stage.load(preset) }
                    Button(role: .destructive) {
                        stage.delete(preset)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        Section {
            Button("Reset everything to defaults", role: .destructive) { stage.resetAll() }
        }
    }
}

struct SliderRow: View {
    let title: String
    let value: Binding<Float>
    let range: ClosedRange<Float>
    let format: String

    init(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ format: String) {
        self.title = title
        self.value = value
        self.range = range
        self.format = format
    }

    var body: some View {
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

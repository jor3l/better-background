import SwiftUI

/// Settings panel for the AI scene: model download, prompt, regenerate and look.
struct AIScenePanel: View {
    @ObservedObject var stage: Stage
    @ObservedObject var controller: AISceneController
    @ObservedObject var models: SceneModelStore
    @State private var showAdvanced = false
    @State private var showInputs = false

    var body: some View {
        Section {
            Toggle("Use an AI-generated scene", isOn: $stage.tuning.ai.enabled)
            Text("Takes a snapshot of your camera, paints you out and redraws the room from your prompt, keeping its layout and the webcam's angle. You stay live in front of it.")
                .font(.caption).foregroundStyle(.secondary)
        }

        modelSection

        if models.state == .ready {
            promptSection
            generateSection
            lookSection
            advancedSection
        }
    }

    // MARK: - Model

    @ViewBuilder private var modelSection: some View {
        Section("Model") {
            switch models.state {
            case .notInstalled:
                Text("The scene is drawn on your Mac by Stable Diffusion 1.5 with a depth ControlNet (open model, CreativeML OpenRAIL-M licence). It's downloaded once: about \(SceneModelStore.bytes(models.variant.downloadBytes)), about 5 GB on disk.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Download model") { models.download() }
                Button("Use a model folder I already have…") { models.chooseFolder() }
            case let .downloading(label, fraction, detail):
                Text(label)
                ProgressView(value: fraction)
                HStack {
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { models.cancel() }
                }
            case let .installing(message):
                HStack {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
            case .ready:
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Ready · \(models.imageSize.width) × \(models.imageSize.height)")
                    Spacer()
                    Button("Show in Finder") { models.revealInFinder() }
                        .buttonStyle(.borderless)
                }
            case let .failed(message):
                Text(message).foregroundStyle(.red).font(.caption)
                Button("Try again") { models.download() }
                Button("Use a model folder I already have…") { models.chooseFolder() }
            }
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        Section("Scene") {
            Menu("Start from a style") {
                ForEach(AIScenePromptPreset.all) { preset in
                    Button(preset.title) { stage.tuning.ai.prompt = preset.prompt }
                }
            }
            TextField("Describe the room", text: $stage.tuning.ai.prompt, axis: .vertical)
                .lineLimit(3...6)
            Text("Describe the place, not yourself. Your desk, walls and windows keep their positions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Generate

    private var generateSection: some View {
        Section("Generate") {
            HStack {
                Button {
                    stage.regenerateAIScene()
                } label: {
                    Label(controller.plate == nil ? "Generate" : "Regenerate", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(controller.status.isWorking)
                if controller.status.isWorking {
                    Button("Stop") { controller.cancel() }
                }
                Spacer()
            }
            statusRow
            Picker("Refresh", selection: $stage.tuning.ai.refresh) {
                ForEach(AISceneRefresh.allCases) { Text($0.title).tag($0) }
            }
            Toggle("New variation every time", isOn: $stage.tuning.ai.newSeedEachTime)

            if let plate = controller.plate {
                Image(decorative: plate, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .scaleEffect(x: stage.tuning.mirror ? -1 : 1, y: 1)
                HStack {
                    Button("Save image…") { controller.savePlateAs() }
                    Spacer()
                    if let d = controller.lastDuration {
                        Text(String(format: "Took %.0f s", d)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch controller.status {
        case .idle:
            EmptyView()
        case .waitingForFrame:
            Label("Taking a snapshot…", systemImage: "camera")
        case .loadingModel:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading the model (the first time takes a minute or two)…")
            }
        case let .generating(step, total):
            VStack(alignment: .leading) {
                Text("Drawing the scene · step \(step) of \(total)")
                ProgressView(value: Double(step), total: Double(max(total, 1)))
            }
        case let .failed(message):
            Text(message).foregroundStyle(.red).font(.caption)
        }
    }

    // MARK: - Look

    private var lookSection: some View {
        Section("Look") {
            SliderRow("Change from my room", $stage.tuning.ai.strength, 0.4...1, "%.2f")
            Text("Low keeps your room's colours and objects; 1 keeps only its layout.")
                .font(.caption).foregroundStyle(.secondary)
            SliderRow("Match my lighting to the scene", $stage.tuning.ai.matchLight, 0...1, "%.2f")
            if let lighting = controller.lighting {
                HStack {
                    Text("Scene light")
                    Spacer()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(.sRGB, red: Double(lighting.highlightColor.x), green: Double(lighting.highlightColor.y),
                                    blue: Double(lighting.highlightColor.z)))
                        .frame(width: 18, height: 12)
                    Text(String(format: "%.0f K, from the %@", lighting.keyKelvin,
                                abs(lighting.keyAzimuth) < 12 ? "front" : (lighting.keyAzimuth > 0 ? "right" : "left")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField("Avoid (negative prompt)", text: $stage.tuning.ai.negativePrompt, axis: .vertical)
                    .lineLimit(2...4)
                Stepper("Steps: \(stage.tuning.ai.steps)", value: $stage.tuning.ai.steps, in: 10...50, step: 5)
                SliderRow("Prompt strength", $stage.tuning.ai.guidance, 2...12, "%.1f")
                HStack {
                    Text("Seed")
                    TextField("Seed", value: $stage.tuning.ai.seed, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                    Button {
                        stage.tuning.ai.seed = Int.random(in: 0...Int(Int32.max))
                    } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.borderless)
                }
                Toggle("Show what the model was given", isOn: $showInputs)
                if showInputs, let snap = controller.lastSnapshot {
                    HStack {
                        Image(decorative: snap.paintedOut, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        Image(decorative: snap.depth, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    }
                    Text(String(format: "You covered %.0f%% of the frame. Leaving the shot for the snapshot gives the cleanest room.", snap.personCoverage * 100))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Free model memory") { controller.unloadModel() }
                Button("Delete downloaded model", role: .destructive) { models.deleteDownloadedModel() }
            }
        }
    }
}

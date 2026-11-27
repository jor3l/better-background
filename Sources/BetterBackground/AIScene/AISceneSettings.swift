import Foundation

/// How often the AI scene regenerates on its own.
enum AISceneRefresh: String, Codable, CaseIterable, Identifiable {
    case off, every30s, every2min, every10min
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Only when I ask"
        case .every30s: "Every 30 seconds"
        case .every2min: "Every 2 minutes"
        case .every10min: "Every 10 minutes"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .every30s: 30
        case .every2min: 120
        case .every10min: 600
        }
    }
}

/// A ready-made prompt, e.g. one per game or kind of call.
struct AIScenePromptPreset: Identifiable {
    let title: String
    let prompt: String
    var id: String { title }

    static let all: [AIScenePromptPreset] = [
        .init(title: "Cozy living room", prompt: "a cozy modern living room, bookshelves, warm table lamps, plants, soft evening light, photorealistic, highly detailed interior photo"),
        .init(title: "Bright office", prompt: "a bright modern office, large windows with daylight, white walls, wooden shelves, plants, clean minimal interior, photorealistic"),
        .init(title: "Gaming den", prompt: "a gaming room at night, neon purple and cyan LED strips, posters, shelves with collectibles, dark walls, cinematic lighting, photorealistic"),
        .init(title: "Old library", prompt: "an old wooden library with tall bookshelves, leather armchair, brass reading lamp, warm golden light, photorealistic"),
        .init(title: "Sci-fi bridge", prompt: "the bridge of a spaceship, glowing control panels, a large window with stars and a planet, blue ambient light, cinematic, highly detailed"),
        .init(title: "Fantasy tavern", prompt: "a medieval fantasy tavern, stone walls, wooden beams, candles and a fireplace, warm firelight, highly detailed"),
        .init(title: "Ski cabin", prompt: "a cozy alpine ski cabin, wooden walls, a window with snowy mountains, fireplace, warm light, photorealistic"),
        .init(title: "Japanese room", prompt: "a calm japanese room, shoji screens, tatami, bonsai, soft daylight through paper windows, photorealistic"),
    ]
}

/// Settings for the AI scene. Stored inside `Tuning` (so presets keep them) and decoded leniently,
/// so settings saved by older versions still load.
struct AISceneSettings: Codable, Equatable {
    var enabled = false
    var prompt = AIScenePromptPreset.all[0].prompt
    var negativePrompt = "person, people, man, woman, face, hands, body, text, watermark, logo, blurry, lowres, deformed, cartoon"
    /// How much of the camera picture is replaced (0.4 keeps its colours, 1 keeps only the room's layout).
    var strength: Float = 0.8
    var steps: Int = 25
    var guidance: Float = 7.5
    var seed: Int = 1234
    /// Pick a new seed on every regeneration instead of keeping the scene stable.
    var newSeedEachTime = false
    var refresh: AISceneRefresh = .off
    /// 0 = show the camera picture of you as is, 1 = fully relight you to match the generated room.
    var matchLight: Float = 0.6

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISceneSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? d.prompt
        negativePrompt = (try? c.decodeIfPresent(String.self, forKey: .negativePrompt)) ?? d.negativePrompt
        strength = (try? c.decodeIfPresent(Float.self, forKey: .strength)) ?? d.strength
        steps = (try? c.decodeIfPresent(Int.self, forKey: .steps)) ?? d.steps
        guidance = (try? c.decodeIfPresent(Float.self, forKey: .guidance)) ?? d.guidance
        seed = (try? c.decodeIfPresent(Int.self, forKey: .seed)) ?? d.seed
        newSeedEachTime = (try? c.decodeIfPresent(Bool.self, forKey: .newSeedEachTime)) ?? d.newSeedEachTime
        refresh = (try? c.decodeIfPresent(AISceneRefresh.self, forKey: .refresh)) ?? d.refresh
        matchLight = (try? c.decodeIfPresent(Float.self, forKey: .matchLight)) ?? d.matchLight
    }
}

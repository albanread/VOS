import Foundation

enum ABCJingleAuthoringMode: String, Codable, CaseIterable, Hashable {
    case promptOnly
    case abcOnly
    case promptAndABC
}

enum ABCJingleCueRole: String, Codable, CaseIterable, Hashable, CustomStringConvertible {
    case intro
    case transition
    case bumper
    case outro
    case emphasisSting

    var description: String {
        switch self {
        case .intro: return "Intro"
        case .transition: return "Transition"
        case .bumper: return "Bumper"
        case .outro: return "Outro"
        case .emphasisSting: return "Emphasis Sting"
        }
    }
}

enum ABCJingleSpeechSafety: String, Codable, CaseIterable, Hashable {
    case safe
    case review
    case risky
}

struct ABCJinglePromptSpec: Codable, Hashable {
    var promptText: String
    var cueRole: ABCJingleCueRole
    var targetDurationSeconds: Double
    var styleTags: [String]
    var includePercussion: Bool
    var instrumentationNotes: String

    init(
        promptText: String = "",
        cueRole: ABCJingleCueRole = .transition,
        targetDurationSeconds: Double = 2.0,
        styleTags: [String] = [],
        includePercussion: Bool = false,
        instrumentationNotes: String = ""
    ) {
        self.promptText = promptText
        self.cueRole = cueRole
        self.targetDurationSeconds = targetDurationSeconds
        self.styleTags = styleTags
        self.includePercussion = includePercussion
        self.instrumentationNotes = instrumentationNotes
    }
}

struct ABCJingleCard: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var category: String
    var tags: [String]
    var authoringMode: ABCJingleAuthoringMode
    var promptSpec: ABCJinglePromptSpec
    var abcSource: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastValidatedAt: Date?
    var cachedMIDIPath: String?
    var speechSafety: ABCJingleSpeechSafety

    init(
        id: UUID = UUID(),
        name: String,
        category: String = "General",
        tags: [String] = [],
        authoringMode: ABCJingleAuthoringMode = .promptAndABC,
        promptSpec: ABCJinglePromptSpec = ABCJinglePromptSpec(),
        abcSource: String = "",
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastValidatedAt: Date? = nil,
        cachedMIDIPath: String? = nil,
        speechSafety: ABCJingleSpeechSafety = .review
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.tags = tags
        self.authoringMode = authoringMode
        self.promptSpec = promptSpec
        self.abcSource = abcSource
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastValidatedAt = lastValidatedAt
        self.cachedMIDIPath = cachedMIDIPath
        self.speechSafety = speechSafety
    }

    var hasPromptAuthoring: Bool {
        authoringMode == .promptOnly || authoringMode == .promptAndABC
    }

    var hasEditableABC: Bool {
        authoringMode == .abcOnly || authoringMode == .promptAndABC
    }

    func updatingValidationState(date: Date = Date(), speechSafety: ABCJingleSpeechSafety? = nil, cachedMIDIPath: String? = nil) -> ABCJingleCard {
        var copy = self
        copy.updatedAt = date
        copy.lastValidatedAt = date
        if let speechSafety {
            copy.speechSafety = speechSafety
        }
        if let cachedMIDIPath {
            copy.cachedMIDIPath = cachedMIDIPath
        }
        return copy
    }
}

struct ABCJinglePreset: Identifiable, Hashable {
    var id: String
    var name: String
    var cueRole: ABCJingleCueRole
    var summary: String
    var defaultPromptSpec: ABCJinglePromptSpec

    static let builtIn: [ABCJinglePreset] = [
        ABCJinglePreset(
            id: "podcast_intro",
            name: "Podcast Intro",
            cueRole: .intro,
            summary: "Short branded opener with restrained momentum.",
            defaultPromptSpec: ABCJinglePromptSpec(
                promptText: "Create a short spoken-word-safe podcast intro with a clear cadence ending.",
                cueRole: .intro,
                targetDurationSeconds: 3.0,
                styleTags: ["spoken-word", "clear", "friendly"],
                includePercussion: false,
                instrumentationNotes: "Use light mallet or pluck tones, avoid harsh brass or dense pads."
            )
        ),
        ABCJinglePreset(
            id: "soft_transition",
            name: "Soft Transition",
            cueRole: .transition,
            summary: "Gentle transition cue between segments.",
            defaultPromptSpec: ABCJinglePromptSpec(
                promptText: "Create a soft transition cue for a podcast chapter change.",
                cueRole: .transition,
                targetDurationSeconds: 1.75,
                styleTags: ["soft", "transition", "editorial"],
                includePercussion: false,
                instrumentationNotes: "Keep the tail short and avoid strong low-end content."
            )
        ),
        ABCJinglePreset(
            id: "news_sting",
            name: "News Sting",
            cueRole: .bumper,
            summary: "Compact, confident bumper with light percussion.",
            defaultPromptSpec: ABCJinglePromptSpec(
                promptText: "Create a compact news-style bumper with light, speech-safe percussion.",
                cueRole: .bumper,
                targetDurationSeconds: 2.0,
                styleTags: ["news", "confident", "clean"],
                includePercussion: true,
                instrumentationNotes: "Use restrained ticks or soft hits, not dense drums."
            )
        ),
        ABCJinglePreset(
            id: "uplift_tag",
            name: "Uplift Tag",
            cueRole: .outro,
            summary: "Positive closing tag for endings and call-to-action moments.",
            defaultPromptSpec: ABCJinglePromptSpec(
                promptText: "Create a brief uplifting outro tag with a clean ending.",
                cueRole: .outro,
                targetDurationSeconds: 2.25,
                styleTags: ["uplifting", "ending", "clean"],
                includePercussion: false,
                instrumentationNotes: "Favor bell, pluck, or electric piano colors with a clear cadence."
            )
        )
    ]
}

struct ABCJingleCardStore: Codable {
    var selectedJingleCardID: UUID?
    var cards: [ABCJingleCard]

    static let `default` = ABCJingleCardStore(
        selectedJingleCardID: nil,
        cards: ABCJinglePreset.builtIn.map { preset in
            ABCJingleCard(
                name: preset.name,
                category: "Presets",
                tags: preset.defaultPromptSpec.styleTags,
                authoringMode: .promptOnly,
                promptSpec: preset.defaultPromptSpec,
                abcSource: "",
                isEnabled: true,
                speechSafety: .review
            )
        }
    )
}
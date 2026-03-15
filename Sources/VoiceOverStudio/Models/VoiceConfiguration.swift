import Foundation

struct VoiceConfiguration: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var baseVoiceID: String
    var anchor: VoiceAnchor
    var timbre: VoiceTimbre
    var prosody: VoiceProsody
    var pacing: VoicePacing
    var emotionalContour: VoiceEmotion
    var deliveryStrength: VoiceDeliveryStrength
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        baseVoiceID: String,
        anchor: VoiceAnchor,
        timbre: VoiceTimbre,
        prosody: VoiceProsody,
        pacing: VoicePacing,
        emotionalContour: VoiceEmotion,
        deliveryStrength: VoiceDeliveryStrength,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseVoiceID = baseVoiceID
        self.anchor = anchor
        self.timbre = timbre
        self.prosody = prosody
        self.pacing = pacing
        self.emotionalContour = emotionalContour
        self.deliveryStrength = deliveryStrength
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var summaryText: String {
        [Self.baseVoiceName(for: baseVoiceID), timbre.label, pacing.label, emotionalContour.label]
            .joined(separator: " • ")
    }

    var promptText: String {
        """
        Start from a \(Self.baseVoiceDescriptor(for: baseVoiceID)). Use a \(anchor.promptText), \(timbre.promptText), \(prosody.promptText), \(pacing.promptText), \(emotionalContour.promptText), with \(deliveryStrength.promptText). Maintain one stable speaker identity for the full utterance. Keep articulation, accent, vocal texture, and energy consistent from start to finish. Follow punctuation in the script as phrasing guidance and avoid drifting into a different character.
        """
    }

    func duplicated(named duplicateName: String? = nil) -> VoiceConfiguration {
        VoiceConfiguration(
            name: duplicateName ?? "\(name) Copy",
            baseVoiceID: baseVoiceID,
            anchor: anchor,
            timbre: timbre,
            prosody: prosody,
            pacing: pacing,
            emotionalContour: emotionalContour,
            deliveryStrength: deliveryStrength,
            isBuiltIn: false
        )
    }

    static func builtInDefault(for id: String) -> VoiceConfiguration? {
        builtInDefaults.first(where: { $0.id == id })
    }

    static func baseVoiceName(for id: String) -> String {
        builtInDefault(for: id)?.name ?? "Custom Base Voice"
    }

    static func baseVoiceDescriptor(for id: String) -> String {
        switch id {
        case "narrator_clear":
            return "clear male narrator base"
        case "narrator_warm":
            return "warm female narrator base"
        case "character_bright":
            return "bright expressive female base"
        case "character_deep":
            return "deep expressive male base"
        case "documentary":
            return "measured documentary narrator base"
        default:
            return "stable narration base"
        }
    }

    static let builtInDefaults: [VoiceConfiguration] = [
        VoiceConfiguration(
            id: "narrator_clear",
            name: "Narrator Male Clear",
            baseVoiceID: "narrator_clear",
            anchor: .adultMan,
            timbre: .crisp,
            prosody: .measured,
            pacing: .steady,
            emotionalContour: .calm,
            deliveryStrength: .subtle,
            isBuiltIn: true
        ),
        VoiceConfiguration(
            id: "narrator_warm",
            name: "Narrator Female Warm",
            baseVoiceID: "narrator_warm",
            anchor: .adultWoman,
            timbre: .warm,
            prosody: .fluid,
            pacing: .steady,
            emotionalContour: .warm,
            deliveryStrength: .moderate,
            isBuiltIn: true
        ),
        VoiceConfiguration(
            id: "character_bright",
            name: "Character Bright Female",
            baseVoiceID: "character_bright",
            anchor: .adultWoman,
            timbre: .bright,
            prosody: .rhythmic,
            pacing: .brisk,
            emotionalContour: .playful,
            deliveryStrength: .strong,
            isBuiltIn: true
        ),
        VoiceConfiguration(
            id: "character_deep",
            name: "Character Deep Male",
            baseVoiceID: "character_deep",
            anchor: .adultMan,
            timbre: .deep,
            prosody: .measured,
            pacing: .deliberate,
            emotionalContour: .tense,
            deliveryStrength: .strong,
            isBuiltIn: true
        ),
        VoiceConfiguration(
            id: "documentary",
            name: "Documentary Male",
            baseVoiceID: "documentary",
            anchor: .neutralNarrator,
            timbre: .deep,
            prosody: .measured,
            pacing: .deliberate,
            emotionalContour: .calm,
            deliveryStrength: .subtle,
            isBuiltIn: true
        ),
    ]
}

struct VoiceConfigurationStore: Codable {
    var selectedVoiceConfigurationID: String?
    var configurations: [VoiceConfiguration]

    static let `default` = VoiceConfigurationStore(
        selectedVoiceConfigurationID: VoiceConfiguration.builtInDefaults.first?.id,
        configurations: VoiceConfiguration.builtInDefaults
    )
}

enum VoiceAnchor: String, Codable, CaseIterable, Hashable, CustomStringConvertible {
    case neutralNarrator
    case adultWoman
    case adultMan
    case middleAgedWoman
    case middleAgedMan

    var label: String {
        switch self {
        case .neutralNarrator: return "Neutral Narrator"
        case .adultWoman: return "Adult Woman"
        case .adultMan: return "Adult Man"
        case .middleAgedWoman: return "Middle-Aged Woman"
        case .middleAgedMan: return "Middle-Aged Man"
        }
    }

    var promptText: String {
        switch self {
        case .neutralNarrator: return "neutral narrator voice"
        case .adultWoman: return "adult woman voice"
        case .adultMan: return "adult man voice"
        case .middleAgedWoman: return "middle-aged woman voice"
        case .middleAgedMan: return "middle-aged man voice"
        }
    }

    var description: String { label }
}

enum VoiceTimbre: String, Codable, CaseIterable, Hashable, CustomStringConvertible {
    case warm
    case deep
    case bright
    case breathy
    case raspy
    case crisp
    case gravelly
    case smooth

    var label: String { rawValue.capitalized }
    var promptText: String { "\(rawValue) timbre" }
    var description: String { label }
}

enum VoiceProsody: String, Codable, CaseIterable, Hashable, CustomStringConvertible {
    case conversational
    case rhythmic
    case fluid
    case monotone
    case staccato
    case measured

    var label: String { rawValue.capitalized }
    var promptText: String { "\(rawValue) prosody" }
    var description: String { label }
}

enum VoicePacing: String, Codable, CaseIterable, Hashable, CustomStringConvertible {
    case brisk
    case steady
    case relaxed
    case deliberate
    case pausesBetweenPhrases

    var label: String {
        switch self {
        case .pausesBetweenPhrases: return "Pauses Between Phrases"
        default: return rawValue.capitalized
        }
    }

    var promptText: String {
        switch self {
        case .pausesBetweenPhrases: return "gentle pauses between phrases"
        default: return "\(rawValue) pacing"
        }
    }

    var description: String { label }
}

enum VoiceEmotion: String, Codable, CaseIterable, Hashable, CustomStringConvertible {
    case warm
    case calm
    case tense
    case melancholic
    case enthusiastic
    case playful
    case flat

    var label: String { rawValue.capitalized }
    var promptText: String { "\(rawValue) emotional tone" }
    var description: String { label }
}

enum VoiceDeliveryStrength: String, Codable, CaseIterable, Hashable, CustomStringConvertible {
    case subtle
    case moderate
    case strong

    var label: String { rawValue.capitalized }

    var promptText: String {
        switch self {
        case .subtle: return "subtle expressiveness"
        case .moderate: return "moderate expressiveness"
        case .strong: return "strong expressiveness"
        }
    }

    var description: String { label }
}

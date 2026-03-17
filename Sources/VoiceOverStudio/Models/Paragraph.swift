//
//  Paragraph.swift
//  VoiceOverStudio
//

import Foundation

struct Paragraph: Identifiable, Codable {
    var id = UUID()
    var text: String
    var voiceID: String = "narrator_clear"
    var voiceInstructions: String = ""
    var gapDuration: Double = 0.5 // Seconds of silence after this paragraph
    var speed: SpeedPreset = .normal

    enum SpeedPreset: String, Codable, CaseIterable {
        case slow = "slow"
        case normal = "normal"
        case fast = "fast"

        var label: String {
            switch self {
            case .slow: return "Slow"
            case .normal: return "Normal"
            case .fast: return "Fast"
            }
        }

        var rate: Float {
            switch self {
            case .slow: return 0.9
            case .normal: return 1.0
            case .fast: return 1.12
            }
        }
    }
    var pitch: PitchPreset = .normal

    enum PitchPreset: String, Codable, CaseIterable {
        case deeper = "deeper"
        case normal = "normal"
        case brighter = "brighter"

        var label: String {
            switch self {
            case .deeper: return "Deeper"
            case .normal: return "Normal"
            case .brighter: return "Brighter"
            }
        }

        var semitones: Float {
            switch self {
            case .deeper: return -2.0
            case .normal: return 0.0
            case .brighter: return 2.0
            }
        }
    }

    var audioPath: String? // Path to generated audio file
    var isGenerating: Bool = false // transient UI state, excluded from Codable
    var outputFilename: String = ""

    enum CodingKeys: String, CodingKey {
        case id, text, voiceID, voiceSid, voiceInstructions, gapDuration, speed, pitch, audioPath, outputFilename
    }

    init(
        id: UUID = UUID(),
        text: String,
        voiceID: String = "narrator_clear",
        voiceInstructions: String = "",
        gapDuration: Double = 0.5,
        speed: SpeedPreset = .normal,
        pitch: PitchPreset = .normal,
        audioPath: String? = nil,
        isGenerating: Bool = false,
        outputFilename: String = ""
    ) {
        self.id = id
        self.text = text
        self.voiceID = voiceID
        self.voiceInstructions = voiceInstructions
        self.gapDuration = gapDuration
        self.speed = speed
        self.pitch = pitch
        self.audioPath = audioPath
        self.isGenerating = isGenerating
        self.outputFilename = outputFilename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        if let decodedVoiceID = try container.decodeIfPresent(String.self, forKey: .voiceID), !decodedVoiceID.isEmpty {
            voiceID = decodedVoiceID
        } else {
            let legacyVoiceSID = try container.decodeIfPresent(Int32.self, forKey: .voiceSid) ?? 0
            voiceID = Self.migrateLegacyVoiceID(from: legacyVoiceSID)
        }
        voiceInstructions = try container.decodeIfPresent(String.self, forKey: .voiceInstructions) ?? ""
        gapDuration = try container.decodeIfPresent(Double.self, forKey: .gapDuration) ?? 0.5
        if let preset = try? container.decodeIfPresent(SpeedPreset.self, forKey: .speed) {
            speed = preset
        } else if let numericSpeed = try? container.decodeIfPresent(Float.self, forKey: .speed) {
            if numericSpeed <= 0.95 { speed = .slow }
            else if numericSpeed >= 1.06 { speed = .fast }
            else { speed = .normal }
        } else {
            speed = .normal
        }
        pitch = try container.decodeIfPresent(PitchPreset.self, forKey: .pitch) ?? .normal
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        outputFilename = try container.decodeIfPresent(String.self, forKey: .outputFilename) ?? ""
        isGenerating = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(voiceID, forKey: .voiceID)
        try container.encode(voiceInstructions, forKey: .voiceInstructions)
        try container.encode(gapDuration, forKey: .gapDuration)
        try container.encode(speed, forKey: .speed)
        try container.encode(pitch, forKey: .pitch)
        try container.encodeIfPresent(audioPath, forKey: .audioPath)
        try container.encode(outputFilename, forKey: .outputFilename)
    }

    private static func migrateLegacyVoiceID(from sid: Int32) -> String {
        switch sid {
        case 4:
            return "narrator_warm"
        case 1:
            return "narrator_clear"
        case 61:
            return "character_bright"
        case 83:
            return "character_deep"
        default:
            return "narrator_clear"
        }
    }
}

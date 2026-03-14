//
//  Paragraph.swift
//  VoiceOverStudio
//

import Foundation

struct Paragraph: Identifiable, Codable {
    var id = UUID()
    var text: String
    var voiceID: String = "narrator_clear"
    var gapDuration: Double = 0.5 // Seconds of silence after this paragraph
    var speed: Float = 1.0
    var audioPath: String? // Path to generated audio file
    var isGenerating: Bool = false // transient UI state, excluded from Codable
    var outputFilename: String = ""

    enum CodingKeys: String, CodingKey {
        case id, text, voiceID, voiceSid, gapDuration, speed, audioPath, outputFilename
    }

    init(
        id: UUID = UUID(),
        text: String,
        voiceID: String = "narrator_clear",
        gapDuration: Double = 0.5,
        speed: Float = 1.0,
        audioPath: String? = nil,
        isGenerating: Bool = false,
        outputFilename: String = ""
    ) {
        self.id = id
        self.text = text
        self.voiceID = voiceID
        self.gapDuration = gapDuration
        self.speed = speed
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
        gapDuration = try container.decodeIfPresent(Double.self, forKey: .gapDuration) ?? 0.5
        speed = try container.decodeIfPresent(Float.self, forKey: .speed) ?? 1.0
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        outputFilename = try container.decodeIfPresent(String.self, forKey: .outputFilename) ?? ""
        isGenerating = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(voiceID, forKey: .voiceID)
        try container.encode(gapDuration, forKey: .gapDuration)
        try container.encode(speed, forKey: .speed)
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

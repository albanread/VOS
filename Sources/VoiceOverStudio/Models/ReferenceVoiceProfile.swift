import Foundation

struct ReferenceVoiceProfile: Codable, Sendable {
    static let voiceID = "reference_voice"

    var name: String = "Reference Voice"
    var transcript: String
    var audioPath: String
    var createdAt: Date = Date()
}
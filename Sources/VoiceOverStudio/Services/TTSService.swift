//
//  TTSService.swift
//  VoiceOverStudio
//

import Foundation
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS

private struct UncheckedSendableModel: @unchecked Sendable {
    let value: SpeechGenerationModel
}

@MainActor
class TTSService: ObservableObject {
    static let defaultModelRepo = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
    static let preferredReferenceVoiceModelRepo = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
    nonisolated private static let consistentVoiceTemperature: Float = 0.25
    nonisolated private static let consistentVoiceTopP: Float = 0.75
    nonisolated private static let referenceVoiceMinimumPeak: Float = 0.12
    nonisolated private static let referenceVoiceTargetPeak: Float = 0.72
    nonisolated private static let referenceVoiceMaxGain: Float = 24.0
    nonisolated static let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/vos2026/huggingface-hub", isDirectory: true)

    private var model: SpeechGenerationModel?
    private var loadedModelRepo: String?
    private var speakerOptions: [VoiceOption] = []
    private let hubCache: HubCache
    private let hubClient: HubClient

    init(cacheDirectory: URL = TTSService.cacheDirectory) {
        hubCache = HubCache(cacheDirectory: cacheDirectory)
        hubClient = HubClient(cache: hubCache)
    }

    func shutdown() {
        model = nil
        loadedModelRepo = nil
        speakerOptions.removeAll()
    }

    static func prefersVoiceDesignForReferenceVoice(modelRepo: String) -> Bool {
        modelRepo.localizedCaseInsensitiveContains("voicedesign")
    }

    func isModelCached(modelRepo: String, revision: String = "main") -> Bool {
        guard let repoID = Repo.ID(rawValue: modelRepo) else {
            return false
        }

        if hubCache.cachedFilePath(repo: repoID, kind: .model, revision: revision, filename: "config.json") != nil {
            return true
        }

        guard let commitHash = hubCache.resolveRevision(repo: repoID, kind: .model, ref: revision),
              let snapshotDirectory = try? hubCache.snapshotPath(repo: repoID, kind: .model, commitHash: commitHash),
              FileManager.default.fileExists(atPath: snapshotDirectory.path)
        else {
            return false
        }

        if let enumerator = FileManager.default.enumerator(
            at: snapshotDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "config.json" || fileURL.pathExtension == "json" || fileURL.pathExtension == "safetensors" {
                    return true
                }
            }
        }

        return false
    }

    func downloadModel(
        modelRepo: String,
        revision: String = "main",
        progressHandler: (@MainActor @Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: modelRepo) else {
            throw TTSModelError.invalidRepositoryID(modelRepo)
        }

        try FileManager.default.createDirectory(at: hubCache.cacheDirectory, withIntermediateDirectories: true)
        return try await hubClient.downloadSnapshot(
            of: repoID,
            kind: .model,
            revision: revision,
            matching: [],
            progressHandler: progressHandler
        )
    }

    func initializeTTS(modelRepo: String) async throws {
        if loadedModelRepo == modelRepo, model != nil {
            return
        }

        model = nil
        loadedModelRepo = nil
        speakerOptions = Self.defaultVoiceOptions

        let loadedModel = try await TTS.loadModel(modelRepo: modelRepo, modelType: "qwen3_tts", cache: hubCache)
        model = loadedModel
        loadedModelRepo = modelRepo
    }

    func generateAudio(
        text: String,
        outputFile: String,
        voiceID: String,
        voiceConfiguration: VoiceConfiguration? = nil,
        referenceVoiceProfile: ReferenceVoiceProfile? = nil,
        speed: Float = 1.0,
        pitchSemitones: Float = 0.0,
        callback _: ((Float) -> Void)? = nil
    ) async -> Bool {
        guard let loadedModel = model else {
            debugLog("DEBUG:: [TTS] Qwen model not initialized")
            return false
        }

        debugLog("DEBUG:: ─────────────────────────────────────")
        debugLog("DEBUG:: [TTS] generateAudio called")
        debugLog("DEBUG:: [TTS]   voice ID              : \(voiceID)")
        debugLog("DEBUG:: [TTS]   text (first 80)       : \(text.prefix(80))")
        debugLog("DEBUG:: [TTS]   prompt summary        : \(voiceConfiguration?.summaryText ?? "reference voice")")
        debugLog("DEBUG:: [TTS]   outputFile            : \(outputFile)")

        let modelBox = UncheckedSendableModel(value: loadedModel)
        let usesReferenceVoice = voiceID == ReferenceVoiceProfile.voiceID
        let voicePrompt = usesReferenceVoice
            ? Self.composeReferenceVoicePrompt()
            : Self.composeVoicePrompt(configuration: voiceConfiguration ?? VoiceConfiguration.builtInDefault(for: voiceID))
        let referenceVoiceURL = referenceVoiceProfile.map { URL(fileURLWithPath: $0.audioPath) }
        let referenceTranscript = referenceVoiceProfile?.transcript
        let clampedSpeed = max(0.9, min(speed, 1.12))

        let result = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                var parameters = modelBox.value.defaultGenerationParameters
                if let maxTokens = parameters.maxTokens {
                    parameters.maxTokens = max(maxTokens, 1024)
                }
                if usesReferenceVoice {
                    parameters.repetitionPenalty = parameters.repetitionPenalty ?? 1.05
                } else {
                    parameters.temperature = Self.consistentVoiceTemperature
                    parameters.topP = Self.consistentVoiceTopP
                    parameters.repetitionPenalty = max(parameters.repetitionPenalty ?? 1.05, 1.1)
                }

                let refAudio: MLXArray?
                if let referenceVoiceURL {
                    (_, refAudio) = try loadAudioArray(from: referenceVoiceURL, sampleRate: modelBox.value.sampleRate)
                } else {
                    refAudio = nil
                }

                let audio = try await modelBox.value.generate(
                    text: text,
                    voice: voicePrompt,
                    refAudio: refAudio,
                    refText: referenceTranscript,
                    language: usesReferenceVoice ? nil : "English",
                    generationParameters: parameters
                )

                let rawSamples = audio.squeezed().asArray(Float.self)
                let samples = usesReferenceVoice
                    ? Self.applyReferenceVoiceMakeupGainIfNeeded(rawSamples)
                    : rawSamples
                guard !samples.isEmpty else {
                    debugLog("DEBUG:: [TTS] Empty audio generated")
                    return false
                }

                try AudioUtils.writeWavFile(
                    samples: samples,
                    sampleRate: Double(modelBox.value.sampleRate),
                    fileURL: URL(fileURLWithPath: outputFile)
                )
                debugLog("DEBUG:: [TTS]   wrote \(samples.count) samples → \(outputFile)")

                if clampedSpeed != 1.0 || pitchSemitones != 0.0 {
                    try AudioPostProcessor.applyTempoAndPitch(
                        rate: clampedSpeed,
                        semitones: pitchSemitones,
                        fileURL: URL(fileURLWithPath: outputFile)
                    )
                    debugLog("DEBUG:: [TTS]   applied tempo/pitch: rate=\(clampedSpeed), pitch=\(pitchSemitones) semitones")
                }

                try AudioPostProcessor.normalizeSpeechLevel(
                    fileURL: URL(fileURLWithPath: outputFile)
                )
                debugLog("DEBUG:: [TTS]   normalized speech level")

                return true
            } catch {
                debugLog("DEBUG:: [TTS] Generation failed: \(error.localizedDescription)")
                return false
            }
        }.value

        return result
    }

    var sampleRate: Int {
        model?.sampleRate ?? 24000
    }

    var numSpeakers: Int {
        speakerOptions.count
    }

    func getAvailableVoices() -> [Dictionary<String, Any>] {
        speakerOptions.map { ["id": $0.id, "name": $0.name, "prompt": $0.prompt] }
    }

    var voiceOptionsList: [VoiceOption] {
        speakerOptions.isEmpty ? Self.defaultVoiceOptions : speakerOptions
    }

    var cacheDirectoryPath: String {
        hubCache.cacheDirectory.path
    }

    private static let defaultVoiceOptions: [VoiceOption] = VoiceConfiguration.builtInDefaults.map {
        VoiceOption(id: $0.id, name: $0.name, prompt: $0.promptText)
    }

    private static func composeVoicePrompt(configuration: VoiceConfiguration?) -> String? {
        configuration?.promptText
    }

    private static func composeReferenceVoicePrompt() -> String? {
        "Match the enrolled reference speaker faithfully with stable pacing, clear articulation, and minimal drift from the source identity."
    }

    nonisolated private static func applyReferenceVoiceMakeupGainIfNeeded(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        let peak = samples.reduce(Float.zero) { currentMax, sample in
            max(currentMax, abs(sample))
        }

        guard peak > 0.0001, peak < referenceVoiceMinimumPeak else {
            return samples
        }

        let gain = min(referenceVoiceTargetPeak / peak, referenceVoiceMaxGain)
        return samples.map { sample in
            let scaled = sample * gain
            return max(-0.98, min(0.98, scaled))
        }
    }
}

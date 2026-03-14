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
        debugLog("DEBUG:: [TTS]   outputFile            : \(outputFile)")

        let modelBox = UncheckedSendableModel(value: loadedModel)
        let voicePrompt = speakerOptions.first(where: { $0.id == voiceID })?.prompt
        let clampedSpeed = max(0.5, min(speed, 2.0))

        let result = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                var parameters = modelBox.value.defaultGenerationParameters
                if let maxTokens = parameters.maxTokens {
                    parameters.maxTokens = max(maxTokens, 1024)
                }

                let audio = try await modelBox.value.generate(
                    text: text,
                    voice: voicePrompt,
                    refAudio: nil,
                    refText: nil,
                    language: "English",
                    generationParameters: parameters
                )

                let samples = audio.squeezed().asArray(Float.self)
                guard !samples.isEmpty else {
                    debugLog("DEBUG:: [TTS] Empty audio generated")
                    return false
                }

                try AudioUtils.writeWavFile(
                    samples: samples,
                    sampleRate: Double(modelBox.value.sampleRate) * Double(clampedSpeed),
                    fileURL: URL(fileURLWithPath: outputFile)
                )
                debugLog("DEBUG:: [TTS]   wrote \(samples.count) samples → \(outputFile)")

                if pitchSemitones != 0.0 {
                    try AudioPostProcessor.applyPitch(
                        semitones: pitchSemitones,
                        fileURL: URL(fileURLWithPath: outputFile)
                    )
                    debugLog("DEBUG:: [TTS]   applied pitch shift: \(pitchSemitones) semitones")
                }

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

    private static let defaultVoiceOptions: [VoiceOption] = [
        VoiceOption(id: "narrator_clear", name: "Narrator Clear", prompt: "A calm professional narrator with a neutral English voice."),
        VoiceOption(id: "narrator_warm", name: "Narrator Warm", prompt: "A warm female narrator with confident pacing and natural expression."),
        VoiceOption(id: "character_bright", name: "Character Bright", prompt: "A bright energetic young character voice with crisp diction."),
        VoiceOption(id: "character_deep", name: "Character Deep", prompt: "A deep expressive male character voice with dramatic tone."),
        VoiceOption(id: "documentary", name: "Documentary", prompt: "A measured documentary voice with polished articulation and subtle gravitas."),
    ]
}

import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTS

actor ReferenceVoiceEnhancementService {
    static let defaultModelRepo = MossFormer2SEModel.defaultRepo

    private var loadedModelRepo: String?
    private var loadedModel: MossFormer2SEModel?

    func enhanceRecording(
        at inputURL: URL,
        outputURL: URL,
        modelRepo: String = defaultModelRepo
    ) async throws {
        let model = try await loadModel(modelRepo: modelRepo)
        let (_, audio) = try loadAudioArray(from: inputURL, sampleRate: model.sampleRate)
        let monoAudio = audio.ndim > 1 ? audio.mean(axis: -1) : audio
        let enhanced = try model.enhance(monoAudio)
        eval(enhanced)

        let samples = enhanced.asArray(Float.self)
        guard !samples.isEmpty else {
            throw NSError(
                domain: "ReferenceVoiceEnhancementService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Speech cleanup produced an empty audio result."]
            )
        }

        try AudioUtils.writeWavFile(
            samples: samples,
            sampleRate: Double(model.sampleRate),
            fileURL: outputURL
        )
    }

    private func loadModel(modelRepo: String) async throws -> MossFormer2SEModel {
        if let loadedModel, loadedModelRepo == modelRepo {
            return loadedModel
        }

        let model = try await MossFormer2SEModel.fromPretrained(modelRepo)
        loadedModel = model
        loadedModelRepo = modelRepo
        return model
    }
}
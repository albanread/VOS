import Foundation

public struct OfflineTtsVitsModelConfig {
    public var model: String
    public var lexicon: String
    public var tokens: String
    public var dataDir: String
    public var noiseScale: Double
    public var noiseScaleW: Double
    public var lengthScale: Double
    public init(model: String, lexicon: String, tokens: String, dataDir: String, noiseScale: Double, noiseScaleW: Double, lengthScale: Double) {
        self.model = model
        self.lexicon = lexicon
        self.tokens = tokens
        self.dataDir = dataDir
        self.noiseScale = noiseScale
        self.noiseScaleW = noiseScaleW
        self.lengthScale = lengthScale
    }
}

public struct OfflineTtsConfig {
    public var vits: OfflineTtsVitsModelConfig
    public var numThreads: Int32
    public var debug: Bool
    public var provider: String
    public var modelType: String
    public init(vits: OfflineTtsVitsModelConfig, numThreads: Int32, debug: Bool, provider: String, modelType: String) {
        self.vits = vits
        self.numThreads = numThreads
        self.debug = debug
        self.provider = provider
        self.modelType = modelType
    }
}

public final class OfflineTtsGeneratedAudio {
    private let data: Data
    public init(data: Data = Data()) {
        self.data = data
    }
    public func save(filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("Stub save failed: \(error)")
            return false
        }
    }
}

public final class OfflineTts {
    public init(config: OfflineTtsConfig) throws {
        // Stub: assume config ok
    }
    public func generate(text: String, sid: Int32, speed: Float) -> OfflineTtsGeneratedAudio {
        // Stub: return empty audio
        return OfflineTtsGeneratedAudio()
    }
}

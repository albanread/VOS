//
//  ProjectViewModel.swift
//  VoiceOverStudio
//

import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Darwin

struct VoiceOption: Identifiable, Codable {
    let id: String
    let name: String
    let sid: Int32
}

private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

@MainActor
class ProjectViewModel: ObservableObject {
    @Published var paragraphs: [Paragraph] = []
    @Published var isProcessing = false
    @Published var statusMessage = "Ready. Please configure model paths in Settings."
    @Published var isTTSReady = false
    @Published var isLLMReady = false
    @Published var isUpdatingModels = false
    @Published var modelUpdateProgress: Double = 0.0
    @Published var modelUpdateNarrative: String = "Idle"
    
    // Services
    private let ttsService = TTSService()
    private let llmService = LLMService()
    private let modelUpdater = ModelUpdaterService()

    private let llmDefaultFilename = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    
    // Model Paths (Saved in UserDefaults or just defined here)
    @AppStorage("modelPathLLM") var modelPathLLM: String = ""
    // TTS Defaults (User needs to point to real files)
    @AppStorage("modelPathTTS_vits") var modelPathTTS_vits: String = ""
    @AppStorage("modelPathTTS_tokens") var modelPathTTS_tokens: String = ""
    @AppStorage("modelPathTTS_dataDir") var modelPathTTS_dataDir: String = ""
    @AppStorage("modelDownloadDirectory") var modelDownloadDirectory: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/vos2026/downloads").path
    @AppStorage("modelUpdateURLLLM") var modelUpdateURLLLM: String = "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true"
    @AppStorage("modelUpdateURLTTSPackage") var modelUpdateURLTTSPackage: String = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-vctk.tar.bz2"
    @AppStorage("modelUpdateURLTTSModel") var modelUpdateURLTTSModel: String = ""
    @AppStorage("modelUpdateURLTTSTokens") var modelUpdateURLTTSTokens: String = ""
    @AppStorage("modelPathTTS_lexicon") var modelPathTTS_lexicon: String = ""
    @AppStorage("modelComputeTier") var modelComputeTierRaw: String = ComputeTier.small.rawValue
    @AppStorage("defaultGap") var defaultGap: Double = 0.5
    @AppStorage("exportFormat") var exportFormatRaw: String = ExportFormat.m4a.rawValue

    // Voice options mapped to speaker IDs (Dynamic)
    @Published var voiceOptions: [VoiceOption] = []
    
    // Tagging
    let genderOptions = ["", "M", "F"]
    let accentOptions = ["", "English", "Scottish", "Irish", "American", "Indian"]
    let regionOptions = ["", "North", "South", "East", "West"]

    enum ExportFormat: String, CaseIterable, Codable {
        case m4a
        case wav
    }

    enum ComputeTier: String, CaseIterable, Codable, Identifiable {
        case small
        case medium
        case high

        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: return "Small (M1 / 8-16GB)"
            case .medium: return "Medium (M1 Pro/Max, M2/M3 Pro)"
            case .high: return "High (M2 Ultra / M3 Ultra)"
            }
        }
    }

    struct ModelRecommendation {
        let llmName: String
        let llmURL: String
        let ttsPackageName: String
        let ttsPackageURL: String
        let rationale: String
    }

    var modelComputeTier: ComputeTier {
        get { ComputeTier(rawValue: modelComputeTierRaw) ?? .small }
        set { modelComputeTierRaw = newValue.rawValue }
    }

    var currentRecommendation: ModelRecommendation {
        switch modelComputeTier {
        case .small:
            return ModelRecommendation(
                llmName: "Llama-3.2-1B-Instruct Q4_K_M (~0.8GB)",
                llmURL: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true",
                ttsPackageName: "vits-vctk (109 speakers, named)",
                ttsPackageURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-vctk.tar.bz2",
                rationale: "Keeps LLM lightweight, and uses VCTK so users get 109 labeled voices with genders/accents."
            )
        case .medium:
            return ModelRecommendation(
                llmName: "Llama-3.2-3B-Instruct Q4_K_M (~2.0GB)",
                llmURL: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true",
                ttsPackageName: "vits-vctk (109 speakers, named)",
                ttsPackageURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-vctk.tar.bz2",
                rationale: "Better LLM plus VCTK voices with gender/accent metadata and a manageable list size."
            )
        case .high:
            return ModelRecommendation(
                llmName: "Meta-Llama-3.1-8B-Instruct Q4_K_M (~4.9GB)",
                llmURL: "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf?download=true",
                ttsPackageName: "vits-vctk (109 speakers, richer voice variety)",
                ttsPackageURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-vctk.tar.bz2",
                rationale: "Uses available memory/compute for better language suggestions and clearer 109 labeled voices."
            )
        }
    }

    func autoDetectModelTier() {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let chip = chipName().lowercased()

        let detected: ComputeTier
        if chip.contains("ultra") || memoryGB >= 64 {
            detected = .high
        } else if chip.contains("pro") || chip.contains("max") || memoryGB >= 24 {
            detected = .medium
        } else {
            detected = .small
        }

        modelComputeTier = detected
        statusMessage = "Detected \(detected.title) from \(chipName()) with \(Int(memoryGB.rounded()))GB RAM."
    }

    private func chipName() -> String {
        var size: size_t = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "Apple Silicon"
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "Apple Silicon"
        }
        return String(cString: buffer)
    }

    // Model download URLs (informational; opens in browser)
    private let llmDownloadURL = URL(string: "https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct-GGUF")
    private let ttsDownloadURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases")
    
    // Audio Player
    private var audioPlayer: AVAudioPlayer?

    private var rootModelsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/vos2026", isDirectory: true)
    }

    private var llmModelsURL: URL {
        rootModelsURL.appendingPathComponent("llm", isDirectory: true)
    }

    private var ttsModelsURL: URL {
        rootModelsURL.appendingPathComponent("tts", isDirectory: true)
    }

    private var downloadsURL: URL {
        rootModelsURL.appendingPathComponent("downloads", isDirectory: true)
    }

    private var documentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    }

    var managedModelsRootDisplay: String {
        rootModelsURL.path
    }

    func shouldHideSettingsPaneOnLaunch() -> Bool {
        requiredModelArtifactsPresent()
    }
    
    init() {
        prepareDefaultModelFoldersAndPaths()
        if paragraphs.isEmpty {
            addParagraph()
        }
        if requiredModelArtifactsPresent() {
            initializeEngines()
        } else {
            statusMessage = "Ready. Models missing — open Settings to download or configure."
        }
    }

    private func prepareDefaultModelFoldersAndPaths() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootModelsURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: llmModelsURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: ttsModelsURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: downloadsURL, withIntermediateDirectories: true)

        // Always use managed folders; do not keep arbitrary remembered directories.
        modelDownloadDirectory = downloadsURL.path

        // Reset to managed defaults each launch, then override with discovered files if present.
        modelPathLLM = llmModelsURL.appendingPathComponent(llmDefaultFilename).path
        modelPathTTS_vits = ttsModelsURL.appendingPathComponent("model.onnx").path
        modelPathTTS_tokens = ttsModelsURL.appendingPathComponent("tokens.txt").path
        modelPathTTS_dataDir = ""
        modelPathTTS_lexicon = ""

        if let discoveredLLM = firstFile(in: llmModelsURL, matchingExtension: "gguf") {
            modelPathLLM = discoveredLLM.path
        }
        // Prefer non-int8 ONNX model
        if let discoveredTTS = firstNonInt8OnnxFile(in: ttsModelsURL)
                               ?? firstFile(in: ttsModelsURL, matchingExtension: "onnx") {
            modelPathTTS_vits = discoveredTTS.path
        }
        if let discoveredTokens = firstNamedFile(in: ttsModelsURL, filename: "tokens.txt") {
            modelPathTTS_tokens = discoveredTokens.path
        }
        if let discoveredDataDir = firstNamedDirectory(in: ttsModelsURL, dirname: "espeak-ng-data") {
            modelPathTTS_dataDir = discoveredDataDir.path
        }
        if let discoveredLexicon = firstNamedFile(in: ttsModelsURL, filename: "lexicon.txt") {
            modelPathTTS_lexicon = discoveredLexicon.path
        }
    }

    private func firstNonInt8OnnxFile(in folder: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator
            where url.pathExtension.lowercased() == "onnx" && !url.lastPathComponent.contains(".int8.") {
            return url
        }
        return nil
    }

    private func firstFile(in folder: URL, matchingExtension ext: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == ext.lowercased() {
            return url
        }
        return nil
    }

    private func firstNamedFile(in folder: URL, filename: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == filename {
            return url
        }
        return nil
    }

    private func firstNamedDirectory(in folder: URL, dirname: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == dirname {
            return url
        }
        return nil
    }

    private func requiredModelArtifactsPresent() -> Bool {
        let corePaths = [modelPathLLM, modelPathTTS_vits, modelPathTTS_tokens]
        guard !corePaths.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }
        guard corePaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }
        // Model also needs either espeak-ng-data OR a lexicon file
        let hasDataDir = !modelPathTTS_dataDir.isEmpty && FileManager.default.fileExists(atPath: modelPathTTS_dataDir)
        let hasLexicon = !modelPathTTS_lexicon.isEmpty && FileManager.default.fileExists(atPath: modelPathTTS_lexicon)
        return hasDataDir || hasLexicon
    }

    /// Check if the recommended LLM file is already present and fresh enough to skip re-download.
    private func hasFreshRecommendedLLM(maxAgeDays: Double = 7) -> Bool {
        guard !modelPathLLM.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: modelPathLLM) else { return false }

        let recommendedName = URL(string: modelUpdateURLLLM)?.lastPathComponent ?? ""
        if !recommendedName.isEmpty, !modelPathLLM.hasSuffix(recommendedName) {
            return false
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPathLLM),
           let modDate = attrs[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(modDate) / 86_400.0
            if age <= maxAgeDays {
                return true
            }
        }
        return false
    }

    /// Helper to set allowed content types using file extensions, falling back to empty if none resolve.
    private func setAllowedContentTypes(_ panel: NSSavePanel, extensions: [String]) {
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
    }
    
    func shutdown() async {
        await llmService.shutdown()
        ttsService.shutdown()
    }
    
    func initializeEngines() {
        Task {
            guard !isProcessing else { return }

            isProcessing = true
            statusMessage = "Engine starting..."
            isTTSReady = false
            isLLMReady = false
            
            do {
                if !modelPathTTS_vits.isEmpty && !modelPathTTS_tokens.isEmpty {
                    try await ttsService.initializeTTS(modelPath: modelPathTTS_vits, tokensPath: modelPathTTS_tokens, dataDir: modelPathTTS_dataDir, lexicon: modelPathTTS_lexicon)
                    isTTSReady = true
                    
                    // Refresh voice options — use direct accessor to avoid [String:Any] cast issues
                    let newOptions = ttsService.voiceOptionsList
                    debugLog("DEBUG:: [VM] Loaded \(newOptions.count) voice options")
                    for opt in newOptions.prefix(10) {
                        debugLog("DEBUG:: [VM]   voiceOptions entry: sid=\(opt.sid) name='\(opt.name)' id='\(opt.id)'")
                    }
                    // Since we are already on MainActor
                    self.voiceOptions = newOptions

                    // Nothing to remap: paragraphs store voiceSid (Int32) directly.
                }
                
                if !modelPathLLM.isEmpty {
                    try await llmService.loadModel(path: modelPathLLM)
                    isLLMReady = true
                }

                if isTTSReady || isLLMReady {
                    statusMessage = "Engine started."
                } else {
                    statusMessage = "Engine start skipped: model paths missing."
                }
            } catch {
                statusMessage = "Initialization Error: \(error.localizedDescription)"
            }
            
            isProcessing = false
        }
    }
    
    func addParagraph() {
        var p = Paragraph(text: "New paragraph text here.", voiceSid: voiceOptions.first?.sid ?? 0)
        if p.outputFilename.isEmpty {
            p.outputFilename = "para_\(p.id.uuidString.prefix(8)).wav"
        }
        p.gapDuration = defaultGap
        paragraphs.append(p)
    }

    func pickLLMModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        setAllowedContentTypes(panel, extensions: ["gguf"])
        if panel.runModal() == .OK, let url = panel.url {
            modelPathLLM = url.path
        }
    }

    func pickTTSModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        setAllowedContentTypes(panel, extensions: ["onnx"])
        if panel.runModal() == .OK, let url = panel.url {
            modelPathTTS_vits = url.path
        }
    }

    func setVoiceGender(sid: Int32, gender: String) {
        var tag = VoiceTagService.shared.getTag(for: sid) ?? UserVoiceTag()
        tag.gender = gender.isEmpty ? nil : gender
        VoiceTagService.shared.setTag(for: sid, tag: tag)
        objectWillChange.send()
    }

    func setVoiceAccent(sid: Int32, accent: String) {
        var tag = VoiceTagService.shared.getTag(for: sid) ?? UserVoiceTag()
        tag.accent = accent.isEmpty ? nil : accent
        VoiceTagService.shared.setTag(for: sid, tag: tag)
        objectWillChange.send()
    }

    func setVoiceRegion(sid: Int32, region: String) {
        var tag = VoiceTagService.shared.getTag(for: sid) ?? UserVoiceTag()
        tag.region = region.isEmpty ? nil : region
        VoiceTagService.shared.setTag(for: sid, tag: tag)
        objectWillChange.send()
    }

    func setVoiceQuality(sid: Int32, quality: Int) {
        var tag = VoiceTagService.shared.getTag(for: sid) ?? UserVoiceTag()
        tag.quality = quality
        VoiceTagService.shared.setTag(for: sid, tag: tag)
        objectWillChange.send()
    }

    func getVoiceTag(sid: Int32) -> UserVoiceTag? {
        VoiceTagService.shared.getTag(for: sid)
    }

    func pickTTSTokensFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        setAllowedContentTypes(panel, extensions: ["txt"])
        if panel.runModal() == .OK, let url = panel.url {
            modelPathTTS_tokens = url.path
        }
    }

    func pickTTSDataDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            modelPathTTS_dataDir = url.path
        }
    }

    func openLLMDownloadPage() {
        guard let url = llmDownloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openTTSDownloadPage() {
        guard let url = ttsDownloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func pickModelDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            modelDownloadDirectory = url.path
        }
    }

    func applyRecommendedModelPreset() {
        let preset = currentRecommendation
        modelUpdateURLLLM = preset.llmURL
        modelUpdateURLTTSPackage = preset.ttsPackageURL
        statusMessage = "Applied \(modelComputeTier.title) model preset."
    }

    func updateLatestLLMModel() async {
        isUpdatingModels = true
        isProcessing = true
        modelUpdateProgress = 0.0
        modelUpdateNarrative = "Preparing LLM update..."
        defer {
            isUpdatingModels = false
            isProcessing = false
            modelUpdateProgress = 1.0
        }

        modelUpdateNarrative = "Downloading LLM model..."
        _ = await updateModelFromURL(
            urlString: modelUpdateURLLLM,
            label: "LLM model",
            destinationDir: llmModelsURL,
            preferredFilename: nil
        ) { downloadedPath in
            self.modelPathLLM = downloadedPath
        }
        modelUpdateNarrative = "LLM update finished."
    }

    func updateLatestTTSModel() async {
        isUpdatingModels = true
        isProcessing = true
        modelUpdateProgress = 0.0
        modelUpdateNarrative = "Preparing TTS model update..."
        defer {
            isUpdatingModels = false
            isProcessing = false
            modelUpdateProgress = 1.0
        }

        modelUpdateNarrative = "Downloading TTS model..."
        _ = await updateModelFromURL(
            urlString: modelUpdateURLTTSModel,
            label: "TTS model",
            destinationDir: ttsModelsURL,
            preferredFilename: nil
        ) { downloadedPath in
            self.modelPathTTS_vits = downloadedPath
        }
        modelUpdateNarrative = "TTS model update finished."
    }

    func updateLatestTTSPackage() async {
        isUpdatingModels = true
        isProcessing = true
        modelUpdateProgress = 0.0
        modelUpdateNarrative = "Preparing TTS package update..."
        defer {
            isUpdatingModels = false
            isProcessing = false
            modelUpdateProgress = 1.0
        }

        let trimmed = modelUpdateURLTTSPackage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Set the TTS package URL first."
            return
        }
        guard let sourceURL = URL(string: trimmed) else {
            statusMessage = "Invalid TTS package URL."
            return
        }

        let destinationDir = ttsModelsURL
        do {
            statusMessage = "Downloading TTS package..."
            modelUpdateNarrative = "Downloading TTS package archive..."
            modelUpdateProgress = 0.2
            let archiveURL = try await modelUpdater.downloadFile(from: sourceURL, into: destinationDir, preferredFilename: nil)
            modelUpdateNarrative = "Extracting TTS package..."
            modelUpdateProgress = 0.6
            let extractedRoot = try modelUpdater.extractTarBz2(archiveURL: archiveURL, into: destinationDir)
            modelUpdateNarrative = "Indexing TTS files..."
            modelUpdateProgress = 0.85
            let files = try modelUpdater.findTTSFiles(in: extractedRoot)

            modelPathTTS_vits = files.model.path
            modelPathTTS_tokens = files.tokens.path
            modelPathTTS_dataDir = files.dataDir?.path ?? ""
            modelPathTTS_lexicon = files.lexicon?.path ?? ""
            statusMessage = "Updated TTS package: \(extractedRoot.lastPathComponent)"
            modelUpdateNarrative = "TTS package update finished."
        } catch {
            statusMessage = "TTS package update failed: \(error.localizedDescription)"
            modelUpdateNarrative = "TTS package update failed."
        }
    }

    func updateLatestTTSTokens() async {
        isUpdatingModels = true
        isProcessing = true
        modelUpdateProgress = 0.0
        modelUpdateNarrative = "Preparing TTS tokens update..."
        defer {
            isUpdatingModels = false
            isProcessing = false
            modelUpdateProgress = 1.0
        }

        modelUpdateNarrative = "Downloading TTS tokens..."
        _ = await updateModelFromURL(
            urlString: modelUpdateURLTTSTokens,
            label: "TTS tokens",
            destinationDir: ttsModelsURL,
            preferredFilename: "tokens.txt"
        ) { downloadedPath in
            self.modelPathTTS_tokens = downloadedPath
        }
        modelUpdateNarrative = "TTS tokens update finished."
    }

    func autoSetup() async {
        isUpdatingModels = true
        isProcessing = true
        modelUpdateProgress = 0.0
        modelUpdateNarrative = "Starting Auto Setup..."
        statusMessage = "Starting Auto Setup..."
        
        defer {
            isUpdatingModels = false
            isProcessing = false
        }

        // 1. Apply Recommended Preset (updates URL strings based on tier)
        applyRecommendedModelPreset()
        modelUpdateNarrative = "Applied recommended settings for \(modelComputeTier.title)."
        try? await Task.sleep(nanoseconds: 500_000_000) // Brief pause for UX

        // 2. Download LLM
        modelUpdateNarrative = "Checking LLM model..."
        modelUpdateProgress = 0.1
        let llmSuccess: Bool
        if hasFreshRecommendedLLM() {
            llmSuccess = true
            statusMessage = "LLM already present; skipping download."
            modelUpdateNarrative = "LLM present; skipping download."
        } else {
            llmSuccess = await updateModelFromURL(
                urlString: modelUpdateURLLLM,
                label: "LLM model",
                destinationDir: llmModelsURL,
                preferredFilename: nil
            ) { downloadedPath in
                self.modelPathLLM = downloadedPath
            }
            modelUpdateNarrative = llmSuccess ? "LLM Ready." : "LLM Setup Failed."
        }
        modelUpdateProgress = 0.4

        // 3. Download & Extract TTS Package
        modelUpdateNarrative = "Checking TTS package..."
        var ttsSuccess = false
        if let sourceURL = URL(string: modelUpdateURLTTSPackage) {
            do {
                modelUpdateNarrative = "Downloading TTS package..."
                let archiveURL = try await modelUpdater.downloadFile(from: sourceURL, into: ttsModelsURL, preferredFilename: nil)
                
                modelUpdateNarrative = "Extracting TTS package..."
                modelUpdateProgress = 0.6
                let extractedRoot = try modelUpdater.extractTarBz2(archiveURL: archiveURL, into: ttsModelsURL)
                
                modelUpdateNarrative = "Verifying TTS files..."
                let files = try modelUpdater.findTTSFiles(in: extractedRoot)
                
                modelPathTTS_vits = files.model.path
                modelPathTTS_tokens = files.tokens.path
                modelPathTTS_dataDir = files.dataDir?.path ?? ""
                modelPathTTS_lexicon = files.lexicon?.path ?? ""
                ttsSuccess = true
                modelUpdateNarrative = "TTS Package Ready."
            } catch {
                modelUpdateNarrative = "TTS Setup Failed: \(error.localizedDescription)"
                print("TTS AutoSetup Error: \(error)")
            }
        }
        modelUpdateProgress = 0.8

        // 4. Initialize Engines
        if llmSuccess && ttsSuccess {
            modelUpdateNarrative = "Initializing Engines..."
            initializeEngines()
            modelUpdateProgress = 1.0
            modelUpdateNarrative = "Auto Setup Complete! You are ready to create."
            statusMessage = "System Ready."
            
            // Wait a moment then clear the narrative so it doesn't look like it's still working
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            modelUpdateNarrative = "Idle"
        } else {
            modelUpdateNarrative = "Setup finished with errors. Please check your internet connection."
            statusMessage = "Setup Failed."
        }
    }

    private func updateModelFromURL(
        urlString: String,
        label: String,
        destinationDir: URL,
        preferredFilename: String?,
        onSuccess: (String) -> Void
    ) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Set the \(label) URL first."
            return false
        }

        guard let sourceURL = URL(string: trimmed) else {
            statusMessage = "Invalid \(label) URL."
            return false
        }

        do {
            statusMessage = "Downloading \(label)..."
            let localURL = try await modelUpdater.downloadFile(
                from: sourceURL,
                into: destinationDir,
                preferredFilename: preferredFilename
            )
            onSuccess(localURL.path)
            statusMessage = "Updated \(label): \(localURL.lastPathComponent)"
            return true
        } catch {
            statusMessage = "\(label) update failed: \(error.localizedDescription)"
            return false
        }
    }
    
    func removeParagraph(at index: Int) {
        paragraphs.remove(at: index)
    }

    func removeParagraph(_ id: UUID) {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        paragraphs.remove(at: index)
    }

    func moveParagraphs(from source: IndexSet, to destination: Int) {
        paragraphs.move(fromOffsets: source, toOffset: destination)
    }

    func duplicateParagraph(_ id: UUID) {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        var copy = paragraphs[index]
        copy.id = UUID()
        copy.audioPath = nil
        copy.isGenerating = false
        copy.outputFilename = "para_\(copy.id.uuidString.prefix(8)).wav"
        paragraphs.insert(copy, at: index + 1)
    }

    func generateAllAudio() async {
        guard isTTSReady else {
            statusMessage = "Initialize TTS before generating."
            return
        }
        isProcessing = true
        let ids = paragraphs.map { $0.id }
        for (i, id) in ids.enumerated() {
            statusMessage = "Generating \(i + 1) of \(ids.count)…"
            await generateAudio(for: id)
        }
        statusMessage = "All \(ids.count) paragraphs generated."
        isProcessing = false
    }

    func saveFullRecording() {
        Task {
            statusMessage = "Generating all audio before export..."
            await generateAllAudio()
            await exportFullSequence()
        }
    }
    
    func generateAudio(for id: UUID) async {
        guard isTTSReady else {
            statusMessage = "Initialize TTS before generating."
            return
        }
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        
        // Auto-initialize if needed logic could go here
        
        paragraphs[index].isGenerating = true
        paragraphs[index].audioPath = nil
        isProcessing = true
        statusMessage = "Generating audio for paragraph \(index + 1)..."
        
        let text = paragraphs[index].text
        let sid = paragraphs[index].voiceSid
        let pickerLabel = voiceOptions.first(where: { $0.sid == sid })?.name ?? "(sid not found in voiceOptions!)"
        debugLog("DEBUG:: ═════════════════════════════════════")
        debugLog("DEBUG:: [VM] Generate paragraph \(index + 1)")
        debugLog("DEBUG:: [VM]   voiceSid in paragraph : \(sid)")
        debugLog("DEBUG:: [VM]   picker label for sid  : \(pickerLabel)")
        debugLog("DEBUG:: [VM]   voiceOptions count    : \(voiceOptions.count)")
        debugLog("DEBUG:: [VM]   text (first 80)       : \(text.prefix(80))")
        let speed = paragraphs[index].speed
        let filename = paragraphs[index].outputFilename.isEmpty ? "para_\(id.uuidString).wav" : paragraphs[index].outputFilename
        let outputPath = documentsURL.appendingPathComponent(filename).path

        let success = await ttsService.generateAudio(text: text, outputFile: outputPath, sid: sid, speed: speed)
        
        if success {
            paragraphs[index].audioPath = outputPath
            statusMessage = "Audio generated for Paragraph \(index + 1)."
        } else {
            statusMessage = "Failed to generate audio for Paragraph \(index + 1)."
        }
        
        paragraphs[index].isGenerating = false
        isProcessing = false
    }

    // Transcript save/load
    func saveTranscript() {
        let panel = NSSavePanel()
        panel.directoryURL = documentsURL
        setAllowedContentTypes(panel, extensions: ["json"])
        panel.nameFieldStringValue = "VoiceOverTranscript.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try JSONEncoder().encode(paragraphs)
                try data.write(to: url)
                statusMessage = "Transcript saved to \(url.lastPathComponent)"
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    func loadTranscript() {
        let panel = NSOpenPanel()
        panel.directoryURL = documentsURL
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        setAllowedContentTypes(panel, extensions: ["json"])
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let loaded = try JSONDecoder().decode([Paragraph].self, from: data)
                paragraphs = loaded.map { para in
                    var p = para
                    if p.outputFilename.isEmpty {
                        p.outputFilename = "para_\(p.id.uuidString.prefix(8)).wav"
                    }
                    return p
                }
                statusMessage = "Transcript loaded (\(loaded.count) paragraphs)."
            } catch {
                statusMessage = "Load failed: \(error.localizedDescription)"
            }
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func playAudio(for id: UUID) {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }),
              let path = paragraphs[index].audioPath else { return }
        
        let url = URL(fileURLWithPath: path)
        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Playback error: \(error)")
            statusMessage = "Playback Error: \(error.localizedDescription)"
        }
    }
    
    func improveText(for id: UUID) async {
        guard isLLMReady else {
            statusMessage = "Initialize LLM before improving text."
            return
        }
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        
        paragraphs[index].isGenerating = true
        isProcessing = true
        statusMessage = "Optimising text for TTS..."
        
        let originalText = paragraphs[index].text
        let improved = await llmService.improveText(inputText: originalText)

        // Prefer the LLM result when valid; otherwise keep the original.
        let candidate = (!improved.isEmpty && !improved.hasPrefix("Error:")) ? improved : originalText
        let spokenReady = TextPreprocessor.preprocess(candidate)
        paragraphs[index].text = spokenReady
        
        paragraphs[index].isGenerating = false
        isProcessing = false
        statusMessage = "Text optimised for TTS."
    }

    func rephraseText(for id: UUID) async {
        guard isLLMReady else {
            statusMessage = "Initialize LLM before rephrasing text."
            return
        }
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        
        paragraphs[index].isGenerating = true
        isProcessing = true
        statusMessage = "Rephrasing text for clarity..."
        
        let originalText = paragraphs[index].text
        let rephrased = await llmService.rephraseText(inputText: originalText)
        
        if !rephrased.isEmpty && !rephrased.hasPrefix("Error:") {
            paragraphs[index].text = rephrased
        }
        
        paragraphs[index].isGenerating = false
        isProcessing = false
        statusMessage = "Text rephrased for spoken clarity."
    }
    
    private func parseLLMResponse(_ text: String) -> [Paragraph] {
        // Regex to find: [Voice Name]: Text...
        // Matches: [Narrator F], [Narrator M], [Character 1], [Character 2]
        // This regex looks for `[` followed by the name, `]`, optional colon, then content until the next `[` or end of string.
        let pattern = #"\[(Narrator [FM]|Character [12])\]:?\s*(.*?)(?=\s*\[(?:Narrator [FM]|Character [12])\]|$)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        
        let nsString = text as NSString
        let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        
        var generatedParagraphs: [Paragraph] = []
        
        for match in results {
            let voiceRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            
            let voiceName = nsString.substring(with: voiceRange)
            let content = nsString.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Map role name directly to a VCTK sid (from the ground-truth table)
            let voiceSid: Int32
            switch voiceName {
            case "Narrator F":  voiceSid = 4   // p229, F, S.England
            case "Narrator M":  voiceSid = 1   // p226, M, Surrey
            case "Character 1": voiceSid = 61  // p294, F, San Francisco
            case "Character 2": voiceSid = 83  // p330, M, California
            default:            voiceSid = voiceOptions.first?.sid ?? 0
            }
            
            if !content.isEmpty {
                generatedParagraphs.append(Paragraph(text: content, voiceSid: voiceSid))
            }
        }
        
        return generatedParagraphs
    }
    
    func exportFullSequence() async {
        statusMessage = "Exporting full sequence..."
        
        // Collect paragraph/audio pairs preserving gap association
        let audioItems = paragraphs.compactMap { p -> (Paragraph, URL)? in
            guard let path = p.audioPath else { return nil }
            return (p, URL(fileURLWithPath: path))
        }
        
        guard !audioItems.isEmpty else {
            statusMessage = "No audio generated to export."
            return
        }
        
        // Create Composition
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            statusMessage = "Failed to create audio track."
            return
        }
        
        var currentTime = CMTime.zero
        
        for item in audioItems {
            let asset = AVURLAsset(url: item.1)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let assetTrack = tracks.first else { continue }
                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                try track.insertTimeRange(timeRange, of: assetTrack, at: currentTime)

                currentTime = CMTimeAdd(currentTime, duration)

                // Add gap
                let gapSeconds = item.0.gapDuration
                if gapSeconds > 0 {
                    let gapDuration = CMTime(seconds: gapSeconds, preferredTimescale: 600)
                    track.insertEmptyTimeRange(CMTimeRange(start: currentTime, duration: gapDuration))
                    currentTime = CMTimeAdd(currentTime, gapDuration)
                }
            } catch {
                print("Composition error: \(error)")
            }
        }
        
        // Ask user for destination and format
        let panel = NSSavePanel()
        panel.directoryURL = documentsURL
        let format = ExportFormat(rawValue: exportFormatRaw) ?? .m4a
        switch format {
        case .m4a:
            setAllowedContentTypes(panel, extensions: ["m4a"])
            panel.nameFieldStringValue = "FullVoiceOver.m4a"
        case .wav:
            setAllowedContentTypes(panel, extensions: ["wav"])
            panel.nameFieldStringValue = "FullVoiceOver.wav"
        }
        if panel.runModal() != .OK { return }
        guard let destinationURL = panel.url else { return }

        let presetName = (format == .wav) ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: presetName) else { return }
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = (format == .wav) ? .wav : .m4a
        exportSession.exportAsynchronously { [session = UncheckedSendable(value: exportSession), destinationURL] in
            Task { @MainActor in
                let exportSession = session.value
                if exportSession.status == .completed {
                    self.statusMessage = "Exported: \(destinationURL.lastPathComponent)"
                } else {
                    self.statusMessage = "Export failed: \(exportSession.error?.localizedDescription ?? "Unknown error")"
                }
            }
        }
    }
}

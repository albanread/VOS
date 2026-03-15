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
    let prompt: String
}

private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

@MainActor
class ProjectViewModel: ObservableObject {
    static let defaultReferenceVoiceScript = """
On Tuesday morning, Maya counted four blue lanterns near the station and said the air felt calm and clear. She smiled, took one slow breath, and asked Leo to bring the map before the train arrived.
"""

    @Published var paragraphs: [Paragraph] = []
    @Published var isProcessing = false
    @Published var statusMessage = "Ready. Configure or download local models in Settings."
    @Published var isTTSReady = false
    @Published var isLLMReady = false
    @Published var isUpdatingModels = false
    @Published var modelUpdateProgress: Double = 0.0
    @Published var modelUpdateNarrative: String = "Idle"
    @Published var referenceVoiceProfile: ReferenceVoiceProfile?
    @Published var isReferenceVoiceSheetPresented = false
    @Published var referenceVoiceScript: String = ProjectViewModel.defaultReferenceVoiceScript
    @Published var isGeneratingReferenceVoiceScript = false
    @Published var isRecordingReferenceVoice = false
    @Published var referenceVoiceEnrollmentStatus: String = "No reference voice enrolled."
    @Published var isPreparingReferenceVoiceModel = false
    @Published var voiceConfigurations: [VoiceConfiguration] = []
    @Published var selectedVoiceConfigurationID: String?
    @Published var isVoiceConfigurationPanePresented = false
    @Published var voiceConfigurationEditingParagraphID: UUID?
    
    // Services
    private let ttsService = TTSService()
    private let llmService = LLMService()
    private let modelUpdater = ModelUpdaterService()
    private let referenceVoiceRecorder = ReferenceVoiceRecorder()

    private let llmDefaultFilename = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    
    // Model settings persisted in AppStorage.
    @AppStorage("modelPathLLM") var modelPathLLM: String = ""
    @AppStorage("ttsModelRepo") var ttsModelRepo: String = TTSService.defaultModelRepo
    @AppStorage("modelDownloadDirectory") var modelDownloadDirectory: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/vos2026/downloads").path
    @AppStorage("modelUpdateURLLLM") var modelUpdateURLLLM: String = "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true"
    @AppStorage("modelComputeTier") var modelComputeTierRaw: String = ComputeTier.small.rawValue
    @AppStorage("defaultGap") var defaultGap: Double = 0.5
    @AppStorage("exportFormat") var exportFormatRaw: String = ExportFormat.m4a.rawValue

    // Voice presets exposed by the current Qwen TTS service.
    @Published var voiceOptions: [VoiceOption] = []

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
        let ttsName: String
        let ttsModelRepo: String
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
                ttsName: "Qwen3-TTS 0.6B Base 8bit",
                ttsModelRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
                rationale: "Fits smaller Apple Silicon machines while keeping local MLX speech generation responsive."
            )
        case .medium:
            return ModelRecommendation(
                llmName: "Llama-3.2-3B-Instruct Q4_K_M (~2.0GB)",
                llmURL: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true",
                ttsName: "Qwen3-TTS 1.7B VoiceDesign 8bit",
                ttsModelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
                rationale: "Balances better LLM guidance with a stronger Qwen TTS model for richer prompt-driven voices."
            )
        case .high:
            return ModelRecommendation(
                llmName: "Meta-Llama-3.1-8B-Instruct Q4_K_M (~4.9GB)",
                llmURL: "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf?download=true",
                ttsName: "Qwen3-TTS 1.7B VoiceDesign bf16",
                ttsModelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16",
                rationale: "Targets higher-memory Macs where the larger VoiceDesign model can run locally without trading off quality."
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
    private let ttsDownloadURL = URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")
    
    // Audio Player
    private var audioPlayer: AVAudioPlayer?

    private var rootModelsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/vos2026", isDirectory: true)
    }

    private var llmModelsURL: URL {
        rootModelsURL.appendingPathComponent("llm", isDirectory: true)
    }

    private var downloadsURL: URL {
        rootModelsURL.appendingPathComponent("downloads", isDirectory: true)
    }

    private var documentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    }

    private var referenceVoiceDirectoryURL: URL {
        rootModelsURL.appendingPathComponent("reference-voice", isDirectory: true)
    }

    private var referenceVoiceProfileURL: URL {
        referenceVoiceDirectoryURL.appendingPathComponent("profile.json", isDirectory: false)
    }

    private var referenceVoiceRecordingURL: URL {
        referenceVoiceDirectoryURL.appendingPathComponent("reference-voice.wav", isDirectory: false)
    }

    private var voiceConfigurationStoreURL: URL {
        rootModelsURL.appendingPathComponent("voice-configurations.json", isDirectory: false)
    }

    var managedModelsRootDisplay: String {
        rootModelsURL.path
    }

    var ttsCacheDisplay: String {
        ttsService.cacheDirectoryPath
    }

    func shouldHideSettingsPaneOnLaunch() -> Bool {
        requiredModelArtifactsPresent()
    }

    var activeVoiceConfigurationIndex: Int? {
        guard let selectedVoiceConfigurationID else { return nil }
        return voiceConfigurations.firstIndex(where: { $0.id == selectedVoiceConfigurationID })
    }

    var isEditingReferenceVoiceConfiguration: Bool {
        guard let voiceConfigurationEditingParagraphID,
              let paragraph = paragraphs.first(where: { $0.id == voiceConfigurationEditingParagraphID })
        else {
            return false
        }
        return paragraph.voiceID == ReferenceVoiceProfile.voiceID
    }

    var baseVoiceOptions: [VoiceOption] {
        VoiceConfiguration.builtInDefaults.map {
            VoiceOption(id: $0.id, name: $0.name, prompt: $0.promptText)
        }
    }
    
    init() {
        prepareDefaultModelFoldersAndPaths()
        loadVoiceConfigurationStore()
        loadReferenceVoiceProfile()
        refreshVoiceOptions()
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
        try? fm.createDirectory(at: downloadsURL, withIntermediateDirectories: true)

        // Always use managed folders; do not keep arbitrary remembered directories.
        modelDownloadDirectory = downloadsURL.path

        // Reset to managed defaults each launch, then override with discovered files if present.
        modelPathLLM = llmModelsURL.appendingPathComponent(llmDefaultFilename).path
        if ttsModelRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ttsModelRepo = TTSService.defaultModelRepo
        }

        if let discoveredLLM = firstFile(in: llmModelsURL, matchingExtension: "gguf") {
            modelPathLLM = discoveredLLM.path
        }
    }

    func persistVoiceConfigurationStore() {
        let store = VoiceConfigurationStore(
            selectedVoiceConfigurationID: selectedVoiceConfigurationID,
            configurations: voiceConfigurations
        )

        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: voiceConfigurationStoreURL, options: .atomic)
        } catch {
            debugLog("DEBUG:: [VM] Failed to persist voice configuration store: \(error.localizedDescription)")
        }
    }

    private func loadVoiceConfigurationStore() {
        guard let data = try? Data(contentsOf: voiceConfigurationStoreURL),
              let store = try? JSONDecoder().decode(VoiceConfigurationStore.self, from: data),
              !store.configurations.isEmpty
        else {
            voiceConfigurations = VoiceConfiguration.builtInDefaults
            selectedVoiceConfigurationID = voiceConfigurations.first?.id
            persistVoiceConfigurationStore()
            return
        }

        voiceConfigurations = store.configurations
        selectedVoiceConfigurationID = store.selectedVoiceConfigurationID ?? store.configurations.first?.id
        if selectedVoiceConfigurationID == nil {
            selectedVoiceConfigurationID = voiceConfigurations.first?.id
        }
    }

    func openVoiceConfiguration(for paragraphID: UUID) {
        guard let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return }
        voiceConfigurationEditingParagraphID = paragraphID
        if paragraph.voiceID == ReferenceVoiceProfile.voiceID {
            selectedVoiceConfigurationID = nil
        } else {
            selectedVoiceConfigurationID = resolvedVoiceConfiguration(for: paragraph.voiceID)?.id ?? voiceConfigurations.first?.id
        }
        isVoiceConfigurationPanePresented = true
        persistVoiceConfigurationStore()
    }

    func closeVoiceConfigurationPane() {
        isVoiceConfigurationPanePresented = false
        persistVoiceConfigurationStore()
    }

    func handleVoiceSelectionChange(for paragraphID: UUID, voiceID: String) {
        if let index = paragraphs.firstIndex(where: { $0.id == paragraphID }) {
            paragraphs[index].voiceID = voiceID
        }

        if voiceConfigurationEditingParagraphID == paragraphID {
            selectedVoiceConfigurationID = (voiceID == ReferenceVoiceProfile.voiceID) ? nil : voiceID
        }
        persistVoiceConfigurationStore()
    }

    func duplicateSelectedVoiceConfiguration() {
        guard let activeVoiceConfigurationIndex else { return }
        let duplicate = voiceConfigurations[activeVoiceConfigurationIndex].duplicated()
        voiceConfigurations.append(duplicate)
        selectedVoiceConfigurationID = duplicate.id

        if let paragraphID = voiceConfigurationEditingParagraphID,
           let paragraphIndex = paragraphs.firstIndex(where: { $0.id == paragraphID })
        {
            paragraphs[paragraphIndex].voiceID = duplicate.id
        }

        refreshVoiceOptions()
        persistVoiceConfigurationStore()
    }

    func resolvedVoiceConfiguration(for voiceID: String) -> VoiceConfiguration? {
        voiceConfigurations.first(where: { $0.id == voiceID })
            ?? VoiceConfiguration.builtInDefault(for: voiceID)
    }

    func voiceSummary(for voiceID: String) -> String {
        if voiceID == ReferenceVoiceProfile.voiceID {
            return "Uses the enrolled reference recording and transcript."
        }

        return resolvedVoiceConfiguration(for: voiceID)?.summaryText
            ?? "Select a saved voice configuration."
    }

    func voicePromptPreview(for voiceID: String) -> String {
        if voiceID == ReferenceVoiceProfile.voiceID {
            return "Reference Voice uses the enrolled sample plus transcript matching for stable cloning."
        }

        return resolvedVoiceConfiguration(for: voiceID)?.promptText
            ?? "No structured voice prompt available."
    }

    private func defaultVoiceConfigurationID() -> String {
        if let selectedVoiceConfigurationID,
           voiceConfigurations.contains(where: { $0.id == selectedVoiceConfigurationID }) {
            return selectedVoiceConfigurationID
        }
        return voiceConfigurations.first?.id ?? "narrator_clear"
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

    private func requiredModelArtifactsPresent() -> Bool {
        let llmPath = modelPathLLM.trimmingCharacters(in: .whitespacesAndNewlines)
        let qwenRepo = ttsModelRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !llmPath.isEmpty, !qwenRepo.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: llmPath) && ttsService.isModelCached(modelRepo: qwenRepo)
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
            await initializeEngines(managesProcessingState: true)
        }
    }

    private func initializeEngines(managesProcessingState: Bool) async {
        if managesProcessingState, isProcessing {
            return
        }

        if managesProcessingState {
            isProcessing = true
        }
        defer {
            if managesProcessingState {
                isProcessing = false
            }
        }

        statusMessage = "Engine starting..."
        isTTSReady = false
        isLLMReady = false

        do {
            try MLXMetalLibraryBootstrap.stageIfNeeded()

            if !ttsModelRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await ttsService.initializeTTS(modelRepo: ttsModelRepo)
                isTTSReady = true
                let newOptions = computedVoiceOptions()
                debugLog("DEBUG:: [VM] Loaded \(newOptions.count) Qwen voice presets")
                voiceOptions = newOptions
                remapParagraphVoicesIfNeeded()
            }

            if !modelPathLLM.isEmpty {
                try await llmService.loadModel(path: modelPathLLM)
                isLLMReady = true
            }

            if isTTSReady || isLLMReady {
                statusMessage = "Engine started."
            } else {
                statusMessage = "Engine start skipped: configure a Qwen repo or GGUF model first."
            }
        } catch {
            statusMessage = "Initialization Error: \(error.localizedDescription)"
        }
    }

    func downloadTTSModel() async {
        let repo = ttsModelRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else {
            statusMessage = "Set the Qwen TTS model repo first."
            return
        }

        isUpdatingModels = true
        isProcessing = true
        modelUpdateProgress = 0.0
        modelUpdateNarrative = "Preparing Qwen model download..."
        defer {
            isUpdatingModels = false
            isProcessing = false
        }

        do {
            _ = try await ttsService.downloadModel(modelRepo: repo) { progress in
                self.modelUpdateProgress = max(0.0, min(progress.fractionCompleted, 1.0))
                let percent = Int((progress.fractionCompleted * 100.0).rounded())
                self.modelUpdateNarrative = "Downloading Qwen TTS model... \(percent)%"
            }
            modelUpdateProgress = 0.92
            modelUpdateNarrative = "Loading downloaded Qwen model..."
            try await ttsService.initializeTTS(modelRepo: repo)
            isTTSReady = true
            voiceOptions = computedVoiceOptions()
            remapParagraphVoicesIfNeeded()
            modelUpdateProgress = 1.0
            modelUpdateNarrative = "Qwen model downloaded and ready."
            statusMessage = "Qwen model ready."
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            modelUpdateNarrative = "Idle"
        } catch {
            modelUpdateNarrative = "Qwen download failed."
            statusMessage = "Qwen model download failed: \(error.localizedDescription)"
        }
    }
    
    func addParagraph() {
        var p = Paragraph(text: "New paragraph text here.", voiceID: defaultVoiceConfigurationID())
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

    func openLLMDownloadPage() {
        guard let url = llmDownloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openTTSDownloadPage() {
        guard let url = ttsDownloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openReferenceVoiceEnrollment() {
        isReferenceVoiceSheetPresented = true
        if referenceVoiceScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            referenceVoiceScript = Self.defaultReferenceVoiceScript
        }
        if referenceVoiceProfile == nil {
            referenceVoiceEnrollmentStatus = "Record in a quiet room. Best results use the VoiceDesign Qwen model with about 8 to 12 seconds of clean speech."
        }
        Task {
            await prepareReferenceVoiceModelIfNeeded()
        }
    }

    var preferredReferenceVoiceModelRepo: String {
        TTSService.preferredReferenceVoiceModelRepo
    }

    var isPreferredReferenceVoiceModelSelected: Bool {
        ttsModelRepo.trimmingCharacters(in: .whitespacesAndNewlines) == preferredReferenceVoiceModelRepo
    }

    var isPreferredReferenceVoiceModelCached: Bool {
        ttsService.isModelCached(modelRepo: preferredReferenceVoiceModelRepo)
    }

    func prepareReferenceVoiceModelIfNeeded(forceDownload: Bool = false) async {
        if isPreparingReferenceVoiceModel || isUpdatingModels {
            return
        }

        let preferredRepo = preferredReferenceVoiceModelRepo
        let shouldDownload = forceDownload || !ttsService.isModelCached(modelRepo: preferredRepo)

        isPreparingReferenceVoiceModel = true
        isUpdatingModels = true
        isProcessing = true
        modelUpdateProgress = 0.0
        defer {
            isPreparingReferenceVoiceModel = false
            isUpdatingModels = false
            isProcessing = false
        }

        do {
            ttsModelRepo = preferredRepo

            if shouldDownload {
                modelUpdateNarrative = "Preparing VoiceDesign model for Reference Voice..."
                referenceVoiceEnrollmentStatus = "Downloading the VoiceDesign model needed for Reference Voice..."
                _ = try await ttsService.downloadModel(modelRepo: preferredRepo) { progress in
                    self.modelUpdateProgress = max(0.0, min(progress.fractionCompleted, 1.0))
                    let percent = Int((progress.fractionCompleted * 100.0).rounded())
                    self.modelUpdateNarrative = "Downloading VoiceDesign model... \(percent)%"
                    self.referenceVoiceEnrollmentStatus = "Downloading VoiceDesign model for Reference Voice... \(percent)%"
                }
            } else {
                modelUpdateProgress = 0.85
                modelUpdateNarrative = "VoiceDesign model already cached. Loading it for Reference Voice..."
                referenceVoiceEnrollmentStatus = "Loading VoiceDesign model for Reference Voice..."
            }

            modelUpdateProgress = max(modelUpdateProgress, 0.92)
            modelUpdateNarrative = "Loading VoiceDesign model..."
            try await ttsService.initializeTTS(modelRepo: preferredRepo)
            isTTSReady = true
            voiceOptions = computedVoiceOptions()
            remapParagraphVoicesIfNeeded()

            modelUpdateProgress = 1.0
            modelUpdateNarrative = "VoiceDesign model ready."
            referenceVoiceEnrollmentStatus = "VoiceDesign model ready. You can record and save a Reference Voice now."
            statusMessage = "Reference Voice model ready."
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            modelUpdateNarrative = "Idle"
        } catch {
            modelUpdateNarrative = "VoiceDesign model setup failed."
            referenceVoiceEnrollmentStatus = "Failed to prepare the VoiceDesign model: \(error.localizedDescription)"
            statusMessage = "Reference Voice model setup failed: \(error.localizedDescription)"
        }
    }

    func generateReferenceVoiceScript() async {
        isGeneratingReferenceVoiceScript = true
        defer { isGeneratingReferenceVoiceScript = false }

        let generated = await llmService.generateReferenceVoiceScript().trimmingCharacters(in: .whitespacesAndNewlines)
        if generated.isEmpty || generated.hasPrefix("Error:") {
            referenceVoiceScript = Self.defaultReferenceVoiceScript
            referenceVoiceEnrollmentStatus = "Using fallback script. Initialize the LLM for AI-generated reference text."
        } else {
            referenceVoiceScript = generated
            referenceVoiceEnrollmentStatus = "Generated a short reference script for roughly 10 seconds of speech."
        }
    }

    func startReferenceVoiceRecording() async {
        do {
            try await referenceVoiceRecorder.startRecording(to: referenceVoiceRecordingURL)
            isRecordingReferenceVoice = true
            referenceVoiceEnrollmentStatus = "Recording… read the short script once in your natural voice. Aim for about 10 seconds."
        } catch {
            referenceVoiceEnrollmentStatus = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func stopReferenceVoiceRecording() {
        referenceVoiceRecorder.stopRecording()
        isRecordingReferenceVoice = false
        referenceVoiceEnrollmentStatus = "Recording stopped. Save to trim silence and enroll this as your Reference Voice."
    }

    func saveReferenceVoiceProfile() {
        let transcript = referenceVoiceScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            referenceVoiceEnrollmentStatus = "Add or generate a reference script first."
            return
        }
        guard FileManager.default.fileExists(atPath: referenceVoiceRecordingURL.path) else {
            referenceVoiceEnrollmentStatus = "Record a reference sample before saving."
            return
        }

        let summary: ReferenceVoiceRecorder.RecordingSummary
        do {
            summary = try referenceVoiceRecorder.finalizeRecording(
                at: referenceVoiceRecordingURL,
                targetSampleRate: ttsService.sampleRate
            )
        } catch {
            referenceVoiceEnrollmentStatus = error.localizedDescription
            statusMessage = error.localizedDescription
            return
        }

        let profile = ReferenceVoiceProfile(
            transcript: transcript,
            audioPath: referenceVoiceRecordingURL.path
        )

        do {
            try FileManager.default.createDirectory(at: referenceVoiceDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(profile)
            try data.write(to: referenceVoiceProfileURL)
            referenceVoiceProfile = profile
            refreshVoiceOptions()
            let durationText = String(format: "%.1f", summary.durationSeconds)
            let guidance = TTSService.prefersVoiceDesignForReferenceVoice(modelRepo: ttsModelRepo)
                ? ""
                : " Switch Qwen to a VoiceDesign repo for better cloning quality."
            let silenceNote = summary.trimmedSilence ? " Leading/trailing silence removed." : ""
            referenceVoiceEnrollmentStatus = "Reference Voice saved (\(durationText)s cleaned sample).\(silenceNote)\(guidance)"
            statusMessage = "Reference Voice enrolled."
        } catch {
            referenceVoiceEnrollmentStatus = "Failed to save reference voice: \(error.localizedDescription)"
        }
    }

    func deleteReferenceVoiceProfile() {
        stopReferenceVoiceRecording()
        try? FileManager.default.removeItem(at: referenceVoiceProfileURL)
        try? FileManager.default.removeItem(at: referenceVoiceRecordingURL)
        referenceVoiceProfile = nil
        refreshVoiceOptions()
        referenceVoiceEnrollmentStatus = "Reference voice removed."
        statusMessage = "Reference Voice removed."
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
        ttsModelRepo = preset.ttsModelRepo
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

        // 3. Apply the recommended Qwen model repo.
        modelUpdateNarrative = "Downloading Qwen TTS model..."
        ttsModelRepo = currentRecommendation.ttsModelRepo
        let ttsSuccess: Bool
        do {
            _ = try await ttsService.downloadModel(modelRepo: ttsModelRepo) { progress in
                let baseProgress = 0.4
                let scaledProgress = baseProgress + (progress.fractionCompleted * 0.4)
                self.modelUpdateProgress = max(baseProgress, min(scaledProgress, 0.8))
                let percent = Int((progress.fractionCompleted * 100.0).rounded())
                self.modelUpdateNarrative = "Downloading Qwen TTS model... \(percent)%"
            }
            ttsSuccess = true
            modelUpdateNarrative = "Qwen model ready."
        } catch {
            ttsSuccess = false
            modelUpdateNarrative = "Qwen setup failed: \(error.localizedDescription)"
            statusMessage = "Qwen setup failed: \(error.localizedDescription)"
        }
        modelUpdateProgress = 0.8

        // 4. Initialize Engines
        if llmSuccess && ttsSuccess {
            modelUpdateNarrative = "Initializing Engines..."
            await initializeEngines(managesProcessingState: false)
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
        let voiceID = paragraphs[index].voiceID
        let voiceConfiguration = resolvedVoiceConfiguration(for: voiceID)
        let referenceVoice = (voiceID == ReferenceVoiceProfile.voiceID) ? referenceVoiceProfile : nil
        let trimmedRepo = ttsModelRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let pickerLabel = voiceOptions.first(where: { $0.id == voiceID })?.name ?? "(voice not found in presets)"
        debugLog("DEBUG:: ═════════════════════════════════════")
        debugLog("DEBUG:: [VM] Generate paragraph \(index + 1)")
        debugLog("DEBUG:: [VM]   voice ID             : \(voiceID)")
        debugLog("DEBUG:: [VM]   picker label         : \(pickerLabel)")
        debugLog("DEBUG:: [VM]   voiceOptions count    : \(voiceOptions.count)")
        debugLog("DEBUG:: [VM]   voice prompt summary  : \(voiceConfiguration?.summaryText ?? "reference voice")")
        debugLog("DEBUG:: [VM]   text (first 80)       : \(text.prefix(80))")
        let speed = paragraphs[index].speed.rate
        let pitchSemitones = paragraphs[index].pitch.semitones
        let filename = paragraphs[index].outputFilename.isEmpty ? "para_\(id.uuidString).wav" : paragraphs[index].outputFilename
        let outputPath = documentsURL.appendingPathComponent(filename).path

        if voiceID == ReferenceVoiceProfile.voiceID, referenceVoice == nil {
            statusMessage = "Enroll a Reference Voice before using that speaker preset."
            paragraphs[index].isGenerating = false
            isProcessing = false
            return
        }

        if voiceID == ReferenceVoiceProfile.voiceID,
           !TTSService.prefersVoiceDesignForReferenceVoice(modelRepo: trimmedRepo)
        {
            let preferredRepo = TTSService.preferredReferenceVoiceModelRepo
            if ttsService.isModelCached(modelRepo: preferredRepo) {
                statusMessage = "Switching to VoiceDesign model for Reference Voice..."
                do {
                    ttsModelRepo = preferredRepo
                    try await ttsService.initializeTTS(modelRepo: preferredRepo)
                    isTTSReady = true
                    voiceOptions = computedVoiceOptions()
                    remapParagraphVoicesIfNeeded()
                } catch {
                    statusMessage = "Reference Voice needs the VoiceDesign model: \(error.localizedDescription)"
                    paragraphs[index].isGenerating = false
                    isProcessing = false
                    return
                }
            } else {
                statusMessage = "Reference Voice works best with a VoiceDesign Qwen repo. Download \(preferredRepo) in Settings first."
                paragraphs[index].isGenerating = false
                isProcessing = false
                return
            }
        }

        let success = await ttsService.generateAudio(
            text: text,
            outputFile: outputPath,
            voiceID: voiceID,
            voiceConfiguration: voiceConfiguration,
            referenceVoiceProfile: referenceVoice,
            speed: speed,
            pitchSemitones: pitchSemitones
        )
        
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
                remapParagraphVoicesIfNeeded()
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
            
            let voiceID: String
            switch voiceName {
            case "Narrator F":
                voiceID = "narrator_warm"
            case "Narrator M":
                voiceID = "narrator_clear"
            case "Character 1":
                voiceID = "character_bright"
            case "Character 2":
                voiceID = "character_deep"
            default:
                voiceID = voiceOptions.first?.id ?? "narrator_clear"
            }
            
            if !content.isEmpty {
                generatedParagraphs.append(Paragraph(text: content, voiceID: voiceID))
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
        let outputFileType: AVFileType = (format == .wav) ? .wav : .m4a

        do {
            try await exportSession.export(to: destinationURL, as: outputFileType)
            statusMessage = "Exported: \(destinationURL.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func remapParagraphVoicesIfNeeded() {
        let validVoiceIDs = Set(voiceOptions.map(\ .id))
        let defaultVoiceID = defaultVoiceConfigurationID()
        paragraphs = paragraphs.map { paragraph in
            guard validVoiceIDs.contains(paragraph.voiceID) else {
                var updated = paragraph
                updated.voiceID = defaultVoiceID
                return updated
            }
            return paragraph
        }
    }

    private func loadReferenceVoiceProfile() {
        guard let data = try? Data(contentsOf: referenceVoiceProfileURL),
              let profile = try? JSONDecoder().decode(ReferenceVoiceProfile.self, from: data),
              FileManager.default.fileExists(atPath: profile.audioPath)
        else {
            referenceVoiceProfile = nil
            referenceVoiceEnrollmentStatus = "No reference voice enrolled."
            return
        }

        referenceVoiceProfile = profile
        referenceVoiceScript = profile.transcript
        referenceVoiceEnrollmentStatus = "Reference Voice is ready."
    }

    private func computedVoiceOptions() -> [VoiceOption] {
        var options = voiceConfigurations.map {
            VoiceOption(id: $0.id, name: $0.name, prompt: $0.promptText)
        }
        if referenceVoiceProfile != nil {
            options.append(
                VoiceOption(
                    id: ReferenceVoiceProfile.voiceID,
                    name: "Reference Voice",
                    prompt: "Match the enrolled reference recording as closely as possible."
                )
            )
        }
        return options
    }

    func refreshVoiceOptions() {
        voiceOptions = computedVoiceOptions()
        remapParagraphVoicesIfNeeded()
    }
}

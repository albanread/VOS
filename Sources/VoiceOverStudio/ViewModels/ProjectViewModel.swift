//
//  ProjectViewModel.swift
//  VoiceOverStudio
//

import Foundation
import SwiftUI
import AVFoundation
import AppKit
import Combine
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
    @Published var isCleaningReferenceVoice = false
    @Published var referenceVoiceEnrollmentStatus: String = "No reference voice enrolled."
    @Published var isPreparingReferenceVoiceModel = false
    @Published var voiceConfigurations: [VoiceConfiguration] = []
    @Published var jingleCards: [ABCJingleCard] = []
    @Published var jingleTimelineItems: [ABCJingleTimelineItem] = []
    @Published var selectedJingleCardID: UUID?
    @Published var isJingleLibrarySheetPresented = false
    @Published var selectedVoiceConfigurationID: String?
    @Published var isVoiceConfigurationPanePresented = false
    @Published var voiceConfigurationEditingParagraphID: UUID?
    @Published var isVideoTimelineSheetPresented = false
    @Published var videoPath: String?
    @Published var videoOriginalAudioVolume: Double = 0.0
    @Published var isVideoExporting = false

    // Services
    let projectStore = ProjectStore()
    private let ttsService = TTSService()
    private let llmService = LLMService()
    private let modelUpdater = ModelUpdaterService()
    private let referenceVoiceRecorder = ReferenceVoiceRecorder()
    private let referenceVoiceEnhancementService = ReferenceVoiceEnhancementService()
    let abcJingleService = ABCJingleService()
    let videoController = VideoTimelineController()

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
            case .small: return "Small (8-16GB, M1-M3 base)"
            case .medium: return "Medium (M4 or newer, 16GB+; any Pro/Max)"
            case .high: return "High (Ultra, 48GB+)"
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
                ttsName: "Qwen3-TTS 1.7B Base 8bit",
                ttsModelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
                rationale: "One model for both preset voices and Reference Voice cloning — the 1.7B Base carries the speaker encoder, so no model switching mid-project."
            )
        case .high:
            return ModelRecommendation(
                llmName: "Meta-Llama-3.1-8B-Instruct Q4_K_M (~4.9GB)",
                llmURL: "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf?download=true",
                ttsName: "Qwen3-TTS 1.7B Base bf16",
                ttsModelRepo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
                rationale: "Full-precision 1.7B Base for the best cloning fidelity on high-memory Macs, with no quantization drift."
            )
        }
    }

    /// Chip generation parsed from the brand string ("Apple M4 Max" -> 4).
    /// Newer base chips have the bandwidth to run the 1.7B TTS model even at
    /// 16GB, where M1-M3 base machines stay on the 0.6B.
    private func chipGeneration() -> Int {
        let name = chipName()
        guard let pattern = try? NSRegularExpression(pattern: "M(\\d+)"),
              let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let group = Range(match.range(at: 1), in: name),
              let generation = Int(name[group])
        else { return 1 }
        return generation
    }

    func autoDetectModelTier() {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let chip = chipName().lowercased()
        let generation = chipGeneration()

        let detected: ComputeTier
        if chip.contains("ultra") || memoryGB >= 48 {
            detected = .high
        } else if chip.contains("pro") || chip.contains("max") || memoryGB >= 24 || (generation >= 4 && memoryGB >= 16) {
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
    private var midiPreviewPlayer: AVMIDIPlayer?

    private var rootModelsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/vos2026", isDirectory: true)
    }

    private var llmModelsURL: URL {
        rootModelsURL.appendingPathComponent("llm", isDirectory: true)
    }

    private var downloadsURL: URL {
        rootModelsURL.appendingPathComponent("downloads", isDirectory: true)
    }

    var documentsURL: URL {
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

    private var jingleCardStoreURL: URL {
        rootModelsURL.appendingPathComponent("jingle-cards.json", isDirectory: false)
    }

    private var jingleTimelineStoreURL: URL {
        rootModelsURL.appendingPathComponent("jingle-timeline.json", isDirectory: false)
    }

    private var cancellables = Set<AnyCancellable>()

    static func sanitizedFolderName(from name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled Video" : String(cleaned.prefix(80))
    }

    /// Per-video working folders: ~/Documents/voiceover/<video name>/ holds
    /// that video's paragraph WAV cache; the database is the source of truth.
    @Published private(set) var videoWorkspaceURL: URL?

    /// Duration of the attached video, loaded from the file itself — available
    /// without opening the timeline sheet, so re-timing works from the
    /// transcript view too.
    @Published private(set) var videoTimelineDuration: Double = 0

    func refreshVideoTimelineDuration() async {
        guard let path = videoPath, FileManager.default.fileExists(atPath: path) else {
            videoTimelineDuration = 0
            return
        }
        if let seconds = try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration).seconds, seconds.isFinite, seconds > 0 {
            videoTimelineDuration = seconds
        }
    }

    /// A fresh workspace folder (numbered on name collisions); reopening an
    /// existing clip reuses the folder recorded in the database.
    func makeWorkspace(for videoURL: URL) -> URL {
        try? FileManager.default.createDirectory(at: videoWorkspacesRootURL, withIntermediateDirectories: true)
        let base = Self.sanitizedFolderName(from: videoURL.deletingPathExtension().lastPathComponent)
        var candidate = videoWorkspacesRootURL.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = videoWorkspacesRootURL.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        // Hand out a folder that exists — TTS writes into it immediately.
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private var videoWorkspacesRootURL: URL {
        documentsURL.appendingPathComponent("voiceover", isDirectory: true)
    }

    // MARK: - Project & clip state

    @Published var isNewProjectSheetPresented = false
    @Published var isOpenProjectSheetPresented = false
    @Published var isClipManagerSheetPresented = false
    @Published private(set) var recentProjects: [ProjectListing] = []

    var activeProjectID: Int64? { currentProjectID }

    @Published var projectName: String = "Untitled Project"

    /// Rename the current project from UI edits. Empty or unchanged names are
    /// ignored — never written back, so no observer feedback is possible.
    func renameCurrentProject(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != projectName else { return }
        projectName = trimmed
        if let id = currentProjectID {
            projectStore?.renameProject(id: id, name: trimmed)
        }
    }
    @Published private(set) var clipSummaries: [ClipSummary] = []

    private var currentProjectID: Int64?
    var currentClipID: Int64?
    /// Playhead target consumed by the timeline sheet when it opens.
    var pendingTimelineSeek: Double?

    var activeClip: ClipSummary? {
        guard let currentClipID else { return nil }
        return clipSummaries.first { $0.id == currentClipID }
    }

    var hasVideoClip: Bool {
        activeClip?.isTranscript == false
    }

    private func ensureProject() -> Int64? {
        if let currentProjectID {
            return currentProjectID
        }
        let id = projectStore?.newProject(name: projectName) ?? 0
        currentProjectID = id
        return id
    }

    private func refreshClipSummaries() {
        guard let projectID = currentProjectID else {
            clipSummaries = []
            return
        }
        clipSummaries = projectStore?.clips(inProject: projectID) ?? []
    }

    /// Every save lands here: the active clip (video or voice-only
    /// transcript) is written transactionally with its voice blobs, so the
    /// transcript editor and the timeline always share one truth.
    func persistVideoProject() {
        canonicalizeClipOrder()
        guard let projectID = ensureProject() else { return }
        let clipPath = videoPath ?? ""
        if clipPath.isEmpty {
            currentClipID = projectStore?.upsertClip(projectID: projectID, record: ClipRecord(
                clipID: currentClipID,
                videoPath: "",
                workspacePath: nil,
                originalAudioVolume: videoOriginalAudioVolume,
                paragraphs: paragraphs,
                isSlideshow: false,
                sourcePDFPath: nil
            ))
        } else {
            let workspace = videoWorkspaceURL ?? makeWorkspace(for: URL(fileURLWithPath: clipPath))
            videoWorkspaceURL = workspace
            currentClipID = projectStore?.upsertClip(projectID: projectID, record: ClipRecord(
                clipID: currentClipID,
                videoPath: clipPath,
                workspacePath: workspace.path,
                originalAudioVolume: videoOriginalAudioVolume,
                paragraphs: paragraphs,
                isSlideshow: isSlideshowClip,
                sourcePDFPath: slideshowPDFPath
            ))
        }
        projectStore?.setActive(projectID: projectID, clipID: currentClipID)
        refreshClipSummaries()
    }

    private func applyClipRecord(_ record: ClipRecord) {
        paragraphs = record.paragraphs.map { paragraph in
            var copy = paragraph
            if copy.outputFilename.isEmpty {
                copy.outputFilename = "clip_\(copy.id.uuidString).wav"
            }
            copy.isGenerating = false
            return copy
        }
        videoOriginalAudioVolume = min(max(record.originalAudioVolume, 0), 1)
        videoWorkspaceURL = record.workspacePath.map { URL(fileURLWithPath: $0) }
        paragraphAudioDurations = record.voiceDurations
        paragraphAudioTextDigests = record.voiceTextDigests
        isSlideshowClip = record.isSlideshow
        slideshowPDFPath = record.isSlideshow ? record.sourcePDFPath : nil
        remapParagraphVoicesIfNeeded()
        normalizeJingleTimelineItems()
        paragraphs.removeAll {
            $0.text == Self.starterParagraphText && $0.startTime == nil && $0.audioPath == nil
        }
        if record.videoPath.isEmpty {
            // Voice-only clip: sequential timeline, nothing to tidy by anchor.
        } else if record.isSlideshow {
            // Segment stubs are legitimately empty until the agent writes
            // their summaries, and their positions are computed — never
            // hand-placed — so the placeholder/dedupe tidy-ups must not run.
            canonicalizeClipOrder()
        } else {
            dedupeVideoTimeline()
            purgeEmptyPlaceholders()
            canonicalizeClipOrder()
        }
    }

    /// Start time is the authority for order on a video clip: the paragraph
    /// array — and therefore the transcript view and every stored position —
    /// always follows it. Clip ids stay stable for audio identity; only
    /// ordering defers to the timeline. Unanchored strays keep their relative
    /// order at the end.
    func canonicalizeClipOrder() {
        guard hasVideoClip else { return }
        let before = paragraphs.map(\.id)
        let anchored = paragraphs.filter { $0.startTime != nil }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        let unanchored = paragraphs.filter { $0.startTime == nil }
        paragraphs = anchored + unanchored
        if paragraphs.map(\.id) != before {
            debugLog("DEBUG:: [VM] Clip order canonicalized by start time (\(anchored.count) anchored clips)")
        }
    }

    /// Integrity checks for the active clip: ordering, text-to-audio
    /// bindings, missing files, and timeline overlaps. Returns a readable
    /// report; empty string means everything passed.
    func verifyTimelineIntegrity() -> String {
        var problems: [String] = []

        let anchored = paragraphs.filter { $0.startTime != nil }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        if anchored.map(\.id) != paragraphs.filter { $0.startTime != nil }.map(\.id) {
            problems.append("clip order does not follow start times (run a reload to canonicalize)")
        }

        var looseBindings = 0
        var missingFiles = 0
        for paragraph in paragraphs {
            guard let path = paragraph.audioPath else { continue }
            let expected = "clip_\(paragraph.id.uuidString)"
            if !path.contains(expected) && !path.contains("para_") {
                looseBindings += 1
                debugLog("DEBUG:: [VM] Binding mismatch: \(path) does not belong to \(paragraph.id)")
            }
            if !FileManager.default.fileExists(atPath: path) {
                missingFiles += 1
            }
        }
        if looseBindings > 0 { problems.append("\(looseBindings) clip(s) reference audio from a different clip") }
        if missingFiles > 0 { problems.append("\(missingFiles) clip(s) reference missing audio files") }

        var overlaps = 0
        var floor: Double?
        for paragraph in anchored {
            let end = (paragraph.startTime ?? 0) + max(audioDuration(forParagraphID: paragraph.id), 0.5)
            if let floorValue = floor, (paragraph.startTime ?? 0) < floorValue - 0.01 {
                overlaps += 1
            }
            floor = max(floor ?? 0, end + 0.5)
        }
        if overlaps > 0 { problems.append("\(overlaps) clip(s) overlap an earlier voice") }

        return problems.isEmpty ? "" : problems.joined(separator: "; ")
    }

    /// Launch restore: the current project and its active clip.
    private func loadPersistedProject() {
        guard let store = projectStore else { return }
        currentProjectID = store.currentProjectID
        if let projectID = currentProjectID, let summary = store.project(id: projectID) {
            projectName = summary.name
        }
        refreshClipSummaries()
        if let clipID = store.currentClipID, let record = store.loadClip(clipID: clipID) {
            currentClipID = clipID
            if record.videoPath.isEmpty {
                videoPath = nil
            } else {
                videoPath = record.videoPath
            }
            applyClipRecord(record)
        }
        Task { await refreshVideoTimelineDuration() }
        refreshRecentProjects()
    }

    /// Switch to another clip of this project (from the clip switcher).
    func switchToClip(_ clipID: Int64) {
        guard clipID != currentClipID,
              let store = projectStore,
              let record = store.loadClip(clipID: clipID)
        else { return }
        // File the outgoing clip before switching.
        persistVideoProject()
        currentClipID = clipID
        if record.videoPath.isEmpty {
            videoPath = nil
            videoWorkspaceURL = nil
            videoController.unload()
        } else {
            videoPath = record.videoPath
            Task {
                await videoController.load(url: URL(fileURLWithPath: record.videoPath))
                await refreshVideoPreview()
            }
        }
        applyClipRecord(record)
        projectStore?.setActive(projectID: currentProjectID, clipID: clipID)
        refreshClipSummaries()
        statusMessage = record.videoPath.isEmpty
            ? "Switched to the voice-only transcript."
            : "Switched to clip \(URL(fileURLWithPath: record.videoPath).lastPathComponent)."
    }

    func refreshRecentProjects() {
        recentProjects = Array((projectStore?.listProjects() ?? []).prefix(8))
    }

    /// Every project, newest first — the Open Project dialog.
    func recentProjectListings() -> [ProjectListing] {
        projectStore?.listProjects() ?? []
    }

    /// The current project's clips with statistics — the clip manager.
    func clipManagerListings() -> [ClipListing] {
        guard let projectID = currentProjectID else { return [] }
        return projectStore?.clipListings(projectID: projectID) ?? []
    }

    func openClipManager() {
        isClipManagerSheetPresented = true
    }

    /// Remove a video clip from the project (narrations and stored voice
    /// cascade with it). Removing the active clip switches to the project's
    /// voice-only transcript first. The transcript clip itself stays.
    func removeClip(_ clipID: Int64) {
        guard let store = projectStore, let projectID = currentProjectID else { return }
        guard let listing = store.clipListings(projectID: projectID).first(where: { $0.id == clipID }),
              !listing.isTranscript
        else {
            statusMessage = "The voice-only transcript stays with the project."
            return
        }

        persistVideoProject()
        if clipID == currentClipID {
            if let transcriptID = store.findClipID(projectID: projectID, videoPath: ""),
               let record = store.loadClip(clipID: transcriptID) {
                currentClipID = transcriptID
                videoPath = nil
                videoWorkspaceURL = nil
                videoTimelineDuration = 0
                videoController.unload()
                applyClipRecord(record)
            } else {
                currentClipID = nil
                videoPath = nil
                videoWorkspaceURL = nil
                videoTimelineDuration = 0
                videoController.unload()
                paragraphs = []
                paragraphAudioDurations = [:]
                addStarterParagraphIfEmpty()
                persistVideoProject()
            }
            store.setActive(projectID: projectID, clipID: currentClipID)
        }
        store.deleteClip(id: clipID)
        refreshClipSummaries()
        refreshRecentProjects()
        statusMessage = "Removed clip \"\(listing.displayName)\" from the project."
    }

    /// Open another project: file the current one, restore the target and
    /// its most relevant clip (its active clip, else the first video clip).
    func openProject(_ projectID: Int64) {
        guard let store = projectStore else { return }
        if projectID == currentProjectID {
            // Opening what is already open is acknowledged, never silent.
            store.touchProject(id: projectID)
            refreshRecentProjects()
            statusMessage = "Project \"\(projectName)\" is already open."
            return
        }
        persistVideoProject()
        currentProjectID = projectID
        if let summary = store.project(id: projectID) {
            projectName = summary.name
        }
        store.touchProject(id: projectID)

        let clipsInProject = store.clips(inProject: projectID)
        var clipID = store.currentClipID
        if let candidate = clipID, !clipsInProject.contains(where: { $0.id == candidate }) {
            clipID = nil
        }
        if clipID == nil {
            clipID = clipsInProject.first(where: { !$0.isTranscript })?.id ?? clipsInProject.first?.id
        }

        if let cid = clipID, let record = store.loadClip(clipID: cid) {
            currentClipID = cid
            if record.videoPath.isEmpty {
                videoPath = nil
                videoWorkspaceURL = nil
                videoController.unload()
            } else {
                videoPath = record.videoPath
            }
            applyClipRecord(record)
            if videoPath != nil {
                Task {
                    await videoController.load(url: URL(fileURLWithPath: record.videoPath))
                    await refreshVideoPreview()
                }
            }
        } else {
            currentClipID = nil
            videoPath = nil
            videoWorkspaceURL = nil
            videoController.unload()
            paragraphs = []
            paragraphAudioDurations = [:]
            addStarterParagraphIfEmpty()
        }
        store.setActive(projectID: projectID, clipID: currentClipID)
        refreshClipSummaries()
        refreshRecentProjects()
        statusMessage = "Opened project \"\(projectName)\"."
    }

    /// Start a fresh project; the old one stays in the database.
    func startNewProject(named name: String) {
        persistVideoProject()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = projectStore?.newProject(name: trimmed.isEmpty ? "Untitled Project" : trimmed) ?? 0
        currentProjectID = id
        currentClipID = nil
        projectName = trimmed.isEmpty ? "Untitled Project" : trimmed
        videoPath = nil
        videoWorkspaceURL = nil
        videoController.unload()
        paragraphs = []
        paragraphAudioDurations = [:]
        addStarterParagraphIfEmpty()
        refreshClipSummaries()
        refreshRecentProjects()
        statusMessage = "New project \"\(projectName)\". Attach a video or write a voice-only transcript."
    }

    // MARK: - Unified timeline (every voice is over a timeline)

    /// Start of a paragraph on its clip's timeline: anchored when a video
    /// clip is active, otherwise stacked sequentially (voice-only podcasts
    /// run end to end with their gaps).
    func timelineStart(forParagraphID id: UUID) -> Double? {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return nil }
        if hasVideoClip, let anchored = paragraphs[index].startTime {
            return anchored
        }
        var cursor = 0.0
        for paragraph in paragraphs[..<index] {
            cursor += audioDuration(forParagraphID: paragraph.id) + max(0, paragraph.gapDuration)
        }
        return cursor
    }

    func timelineEnd(forParagraphID id: UUID) -> Double? {
        guard let start = timelineStart(forParagraphID: id) else { return nil }
        return start + audioDuration(forParagraphID: id)
    }

    /// The largest free span on the active clip's timeline where a new voice
    /// clip could be inserted. Voice-only clips always have room.
    func largestFreeTimelineGap() -> Double? {
        guard hasVideoClip, videoTimelineDuration > 0 else {
            return nil // voice-only: unbounded
        }
        let spans = videoVoiceSpans.sorted { $0.start < $1.start }
        var best = 0.0
        var cursor = 0.0
        for span in spans {
            if span.start > cursor {
                best = max(best, span.start - cursor)
            }
            cursor = max(cursor, span.end)
        }
        best = max(best, videoTimelineDuration - cursor)
        return best
    }

    /// Whether a new clip can be inserted into the active clip's timeline.
    /// Video clips are finite, so insertion needs a real gap; voice-only
    /// timelines are open-ended.
    func canInsertNewVoiceClip() -> Bool {
        if !hasVideoClip { return true }
        guard let gap = largestFreeTimelineGap() else { return true }
        return gap >= 1.0
    }

    var insertionBlockedMessage: String? {
        guard hasVideoClip, !canInsertNewVoiceClip() else { return nil }
        return "The video timeline is full — every moment is voiced. Move or remove a clip first."
    }

    /// Autosave the attached video's project whenever its paragraphs change,
    /// coalescing bursts of edits (typing, anchoring, generation) by a second.
    private func startVideoProjectAutosave() {
        $paragraphs
            .dropFirst(2)
            .debounce(for: .seconds(1.0), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.persistVideoProject()
            }
            .store(in: &cancellables)
    }

    var jingleCacheDirectoryURL: URL {
        rootModelsURL.appendingPathComponent("jingles", isDirectory: true)
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

    var activeJingleCardIndex: Int? {
        guard let selectedJingleCardID else { return nil }
        return jingleCards.firstIndex(where: { $0.id == selectedJingleCardID })
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
        ScriptingRegistry.registerModel(self)
        prepareDefaultModelFoldersAndPaths()
        loadVoiceConfigurationStore()
        loadJingleCardStore()
        loadJingleTimelineStore()
        loadReferenceVoiceProfile()
        projectStore?.migrateNarrationVoicesToReferenceVoice(enrolled: referenceVoiceProfile != nil)
        loadPersistedProject()
        refreshVoiceOptions()
        remapParagraphVoicesIfNeeded()
        startVideoProjectAutosave()
        if paragraphs.isEmpty {
            addStarterParagraphIfEmpty()
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

    func persistJingleCardStore() {
        let store = ABCJingleCardStore(
            selectedJingleCardID: selectedJingleCardID,
            cards: jingleCards
        )

        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: jingleCardStoreURL, options: .atomic)
        } catch {
            debugLog("DEBUG:: [VM] Failed to persist jingle card store: \(error.localizedDescription)")
        }
    }

    func persistJingleTimelineStore() {
        let store = ABCJingleTimelineStore(items: jingleTimelineItems)

        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: jingleTimelineStoreURL, options: .atomic)
        } catch {
            debugLog("DEBUG:: [VM] Failed to persist jingle timeline store: \(error.localizedDescription)")
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

    private func loadJingleCardStore() {
        guard let data = try? Data(contentsOf: jingleCardStoreURL),
              let store = try? JSONDecoder().decode(ABCJingleCardStore.self, from: data),
              !store.cards.isEmpty
        else {
            jingleCards = ABCJingleCardStore.default.cards
            selectedJingleCardID = jingleCards.first?.id
            persistJingleCardStore()
            return
        }

        jingleCards = store.cards
        selectedJingleCardID = store.selectedJingleCardID ?? store.cards.first?.id
        if selectedJingleCardID == nil {
            selectedJingleCardID = jingleCards.first?.id
        }
    }

    private func loadJingleTimelineStore() {
        guard let data = try? Data(contentsOf: jingleTimelineStoreURL),
              let store = try? JSONDecoder().decode(ABCJingleTimelineStore.self, from: data)
        else {
            jingleTimelineItems = ABCJingleTimelineStore.default.items
            persistJingleTimelineStore()
            return
        }

        jingleTimelineItems = store.items
        normalizeJingleTimelineItems()
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

    func selectJingleCard(_ id: UUID?) {
        selectedJingleCardID = id
        persistJingleCardStore()
    }

    func openJingleLibrary() {
        if selectedJingleCardID == nil {
            selectedJingleCardID = jingleCards.first?.id
        }
        isJingleLibrarySheetPresented = true
    }

    func addJingleCard(from preset: ABCJinglePreset? = nil) {
        let chosenPreset = preset ?? ABCJinglePreset.builtIn.first
        let card: ABCJingleCard
        if let chosenPreset {
            card = ABCJingleCard(
                name: chosenPreset.name,
                category: "Presets",
                tags: chosenPreset.defaultPromptSpec.styleTags,
                authoringMode: .promptOnly,
                promptSpec: chosenPreset.defaultPromptSpec,
                abcSource: "",
                isEnabled: true,
                speechSafety: .review
            )
        } else {
            card = ABCJingleCard(name: "New Jingle")
        }

        jingleCards.append(card)
        selectedJingleCardID = card.id
        persistJingleCardStore()
    }

    func duplicateJingleCard(_ id: UUID) {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else { return }
        var copy = jingleCards[index]
        copy.id = UUID()
        copy.name += " Copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.lastValidatedAt = nil
        copy.cachedMIDIPath = nil
        jingleCards.insert(copy, at: index + 1)
        selectedJingleCardID = copy.id
        persistJingleCardStore()
    }

    func removeJingleCard(_ id: UUID) {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else { return }
        jingleCards.remove(at: index)
        jingleTimelineItems.removeAll { $0.jingleCardID == id }
        if selectedJingleCardID == id {
            selectedJingleCardID = jingleCards.first?.id
        }
        persistJingleCardStore()
        persistJingleTimelineStore()
    }

    func addJingleCardToTimeline(_ jingleCardID: UUID, afterParagraphID: UUID?) {
        guard jingleCards.contains(where: { $0.id == jingleCardID }) else { return }
        jingleTimelineItems.append(ABCJingleTimelineItem(jingleCardID: jingleCardID, afterParagraphID: afterParagraphID))
        persistJingleTimelineStore()
        statusMessage = "Added jingle to timeline."
    }

    func openTimelineJingle(_ itemID: UUID) {
        guard let item = jingleTimelineItems.first(where: { $0.id == itemID }) else { return }
        selectedJingleCardID = item.jingleCardID
        isJingleLibrarySheetPresented = true
    }

    func removeTimelineJingle(_ itemID: UUID) {
        jingleTimelineItems.removeAll { $0.id == itemID }
        persistJingleTimelineStore()
    }

    func jingleTimelineItems(after paragraphID: UUID?) -> [ABCJingleTimelineItem] {
        jingleTimelineItems
            .filter { $0.afterParagraphID == paragraphID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func timelineStartText(for itemID: UUID) -> String {
        let seconds = timelineStartSeconds(for: itemID)
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    func timelineJingleDurationText(for jingleCardID: UUID) -> String {
        let duration = jingleCards.first(where: { $0.id == jingleCardID })?.promptSpec.targetDurationSeconds ?? 0
        return String(format: "%.1fs", duration)
    }

    func updateJingleCard(_ card: ABCJingleCard) {
        guard let index = jingleCards.firstIndex(where: { $0.id == card.id }) else { return }
        var updated = card
        updated.updatedAt = Date()
        jingleCards[index] = updated
        persistJingleCardStore()
    }

    func validateJingleCard(_ id: UUID) {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else { return }
        do {
            let result = try abcJingleService.validate(card: jingleCards[index])
            let safety = abcJingleService.suggestedSpeechSafety(for: result.analysis)
            jingleCards[index] = jingleCards[index].updatingValidationState(speechSafety: safety)
            let warningCount = result.analysis.warnings.count
            statusMessage = warningCount == 0
                ? "Validated jingle \(jingleCards[index].name)."
                : "Validated jingle \(jingleCards[index].name) with \(warningCount) warning(s)."
            persistJingleCardStore()
        } catch {
            statusMessage = "Jingle validation failed: \(error.localizedDescription)"
        }
    }

    func exportJingleCardMIDI(_ id: UUID) {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else { return }
        let filename = "jingle-\(id.uuidString).mid"
        let outputURL = jingleCacheDirectoryURL.appendingPathComponent(filename, isDirectory: false)

        do {
            let result = try abcJingleService.exportMIDI(abcSource: jingleCards[index].abcSource, to: outputURL)
            try writeJingleMIDIDiagnostics(result: result, midiURL: outputURL)
            let safety = abcJingleService.suggestedSpeechSafety(for: result.analysis)
            jingleCards[index] = jingleCards[index].updatingValidationState(speechSafety: safety, cachedMIDIPath: outputURL.path)
            statusMessage = "Exported MIDI for jingle \(jingleCards[index].name)."
            persistJingleCardStore()
        } catch {
            statusMessage = "Jingle MIDI export failed: \(error.localizedDescription)"
        }
    }

    func generateTemplateJingle(for id: UUID) {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else { return }

        let generated = abcJingleService.generateDeterministicABC(for: jingleCards[index])

        do {
            let validation = try abcJingleService.validate(abcSource: generated)
            let safety = abcJingleService.suggestedSpeechSafety(for: validation.analysis)
            var updated = jingleCards[index]
            updated.abcSource = generated
            if updated.authoringMode == .promptOnly {
                updated.authoringMode = .promptAndABC
            }
            updated.updatedAt = Date()
            updated.cachedMIDIPath = nil
            updated.lastValidatedAt = Date()
            updated.speechSafety = safety
            jingleCards[index] = updated
            persistJingleCardStore()
            statusMessage = "Generated a deterministic jingle template for \(updated.name)."
        } catch {
            statusMessage = "Template jingle generation failed validation: \(error.localizedDescription)"
        }
    }

    func playJingleCardPreview(_ id: UUID) {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else { return }
        let filename = "jingle-preview-\(id.uuidString)-\(UUID().uuidString).mid"
        let outputURL = jingleCacheDirectoryURL.appendingPathComponent(filename, isDirectory: false)

        do {
            let result = try abcJingleService.exportMIDI(abcSource: jingleCards[index].abcSource, to: outputURL)
            try writeJingleMIDIDiagnostics(result: result, midiURL: outputURL)
            let safety = abcJingleService.suggestedSpeechSafety(for: result.analysis)
            jingleCards[index] = jingleCards[index].updatingValidationState(speechSafety: safety, cachedMIDIPath: outputURL.path)

            guard let soundBankURL = defaultMIDISoundBankURL() else {
                statusMessage = "No system MIDI soundbank was found for jingle preview."
                persistJingleCardStore()
                return
            }

            midiPreviewPlayer?.stop()
            midiPreviewPlayer = try AVMIDIPlayer(contentsOf: outputURL, soundBankURL: soundBankURL)
            midiPreviewPlayer?.prepareToPlay()
            midiPreviewPlayer?.play {
                Task { @MainActor in
                    self.statusMessage = "Jingle preview finished."
                }
            }

            statusMessage = "Previewing jingle \(jingleCards[index].name)."
            persistJingleCardStore()
        } catch {
            statusMessage = "Jingle preview failed: \(error.localizedDescription)"
        }
    }

    func writeJingleMIDIDiagnostics(result: ABCJingleRenderResult, midiURL: URL) throws {
        let reportURL = midiURL.deletingPathExtension().appendingPathExtension("debug.txt")
        let report = abcJingleService.diagnosticReport(for: result)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Video timeline

    func openVideoTimeline() {
        isVideoTimelineSheetPresented = true
        Task { await prepareVideoPreview() }
    }

    /// Toolbar jump: open the timeline of the active video clip, or the
    /// project's first video clip when the transcript is active.
    func openTimelineFromToolbar() {
        if hasVideoClip {
            openVideoTimeline()
        } else if let videoClip = clipSummaries.first(where: { !$0.isTranscript }) {
            switchToClip(videoClip.id)
            openVideoTimeline()
        }
    }

    /// Open the timeline and (for video clips) land the playhead on a
    /// specific paragraph's start.
    func openTimeline(at seconds: Double?) {
        pendingTimelineSeek = seconds
        openVideoTimeline()
    }

    /// Loads (or clears) the attached video and rebuilds preview playback.
    /// Voice-only clips get a podcast-style audio timeline instead.
    func prepareVideoPreview() async {
        if let path = videoPath, FileManager.default.fileExists(atPath: path) {
            await videoController.load(url: URL(fileURLWithPath: path))
        } else {
            if videoPath != nil {
                videoPath = nil
                projectStore?.setActive(projectID: currentProjectID, clipID: nil)
            }
            await presentVoiceOnlyPreview()
        }
        await refreshVideoPreview()
        await refreshParagraphAudioDurations()
    }

    /// The sequential voice timeline: each paragraph at its computed slot
    /// (ungenerated ones as estimated silence), so what you see is what
    /// plays.
    func presentVoiceOnlyPreview() async {
        let entries: [(audioURL: URL?, length: Double, gapAfter: Double)] = paragraphs.map { paragraph in
            let path = paragraph.audioPath
            return (
                audioURL: path.map { URL(fileURLWithPath: $0) },
                length: audioDuration(forParagraphID: paragraph.id),
                gapAfter: max(0, paragraph.gapDuration)
            )
        }
        guard let built = await VideoTimelineService.makeVoiceOnlyComposition(entries: entries) else {
            videoController.unload()
            return
        }
        videoController.presentVoiceOnly(
            item: AVPlayerItem(asset: built.composition),
            duration: built.duration
        )
    }

    func refreshVideoPreview() async {
        if hasVideoClip, videoPath != nil {
            await videoController.rebuildPreview(
                clips: videoAnchoredClips(),
                originalAudioVolume: Float(videoOriginalAudioVolume)
            )
        } else if !paragraphs.isEmpty {
            await presentVoiceOnlyPreview()
        }
    }

    func attachVideo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        setAllowedContentTypes(panel, extensions: ["mov", "mp4", "m4v"])
        if panel.runModal() == .OK, let url = panel.url {
            Task { _ = await attachVideoFile(at: url) }
        }
    }

    /// Shared attach path for the open panel, drag-and-drop, and Apple Events.
    /// Returns false (and sets a status message) when the file is unreadable.
    @discardableResult
    func attachVideoFile(at url: URL) async -> Bool {
        let previousVideoPath = videoPath
        let previousWorkspace = videoWorkspaceURL
        await videoController.load(url: url)
        guard videoController.isLoaded else {
            statusMessage = videoController.loadError ?? "Could not read video: \(url.lastPathComponent)"
            return false
        }

        // File the outgoing working set before switching away from it —
        // whether it belonged to another video or to the voice-only clip.
        if previousVideoPath != url.path {
            persistVideoProject()
        }

        let projectID = ensureProject()
        videoPath = url.path

        // Attaching a video inside a project adds (or reopens) a clip.
        if previousVideoPath != url.path {
            if let clipID = projectStore?.findClipID(projectID: projectID ?? 0, videoPath: url.path),
               let record = projectStore?.loadClip(clipID: clipID) {
                currentClipID = clipID
                applyClipRecord(record)
                statusMessage = "Clip reopened: \(url.lastPathComponent) — \(paragraphs.count) voice-over\(paragraphs.count == 1 ? "" : "s")."
            } else {
                // Fresh clip: keep the writing, drop timings that belonged to
                // a different clip's timeline.
                currentClipID = nil
                videoWorkspaceURL = makeWorkspace(for: url)
                for index in paragraphs.indices {
                    paragraphs[index].startTime = nil
                }
                statusMessage = "Clip added: \(url.lastPathComponent). Working folder: \(videoWorkspaceURL?.path ?? "")."
            }
            projectStore?.setActive(projectID: projectID, clipID: currentClipID)
            refreshClipSummaries()
        } else {
            statusMessage = "Video attached: \(url.lastPathComponent)"
        }

        await refreshVideoTimelineDuration()
        await refreshVideoPreview()
        return true
    }

    /// Drag-and-drop entry point from the sheet or the main window.
    func attachVideoDropped(_ url: URL) async {
        guard VideoTimelineService.isMovieURL(url) else {
            statusMessage = "Unsupported file: \(url.lastPathComponent). Drop a .mov, .mp4, or .m4v video."
            return
        }
        if await attachVideoFile(at: url) {
            openVideoTimeline()
        }
    }

    /// "Detach" now means: switch back to the project's voice-only clip.
    /// The video clip stays in the project and in the database.
    func detachVideo() {
        guard let projectID = currentProjectID else { return }
        persistVideoProject()
        videoTimelineDuration = 0
        if let transcriptClip = projectStore?.findClipID(projectID: projectID, videoPath: ""),
           let record = projectStore?.loadClip(clipID: transcriptClip) {
            currentClipID = transcriptClip
            videoPath = nil
            videoWorkspaceURL = nil
            videoController.unload()
            applyClipRecord(record)
        } else {
            // No voice-only clip yet: the current working set becomes it.
            videoPath = nil
            currentClipID = nil
            videoWorkspaceURL = nil
            videoController.unload()
            for index in paragraphs.indices {
                paragraphs[index].startTime = nil
                paragraphs[index].isRecorded = false
            }
            persistVideoProject()
        }
        projectStore?.setActive(projectID: projectID, clipID: currentClipID)
        refreshClipSummaries()
        statusMessage = "Switched to the voice-only transcript. The video clip stays in this project."
    }

    func commitVideoVolume() {
        persistVideoProject()
        Task { await refreshVideoPreview() }
    }

    // MARK: - Slideshow (PDF → narrated slide video)

    /// True when the active clip's "video" is a baked PDF slideshow.
    @Published private(set) var isSlideshowClip = false
    @Published private(set) var slideshowPDFPath: String?

    /// Import a PDF as a new slideshow clip: trim page margins, split portrait
    /// pages into upper/lower viewports, create one empty narration stub per
    /// segment, and bake the initial stills movie so the clip behaves like a
    /// video attachment from the first moment. Returns a readable report.
    @discardableResult
    func importSlideshow(pdfURL: URL) async throws -> String {
        let fileName = pdfURL.deletingPathExtension().lastPathComponent
        let layout = try PDFSlideshowService.buildLayout(pdfURL: pdfURL)
        let segments = layout.segments.map {
            SlideshowSegmentRecord(number: $0.number, page: $0.page, crop: $0.crop, scrollsIn: $0.scrollsIn, skipped: false)
        }

        // File the outgoing working set before switching away from it.
        persistVideoProject()
        guard let projectID = ensureProject(), let store = projectStore else {
            throw NSError(
                domain: "ProjectViewModel",
                code: -50,
                userInfo: [NSLocalizedDescriptionKey: "No project is available to hold the slideshow."]
            )
        }

        // Re-importing the same PDF reopens its clip instead of duplicating.
        if let existing = store.findClipIDByPDF(projectID: projectID, pdfPath: pdfURL.path) {
            switchToClip(existing)
            if !(videoPath.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
                await refreshSlideshow(rebake: true)
            }
            statusMessage = "Slideshow reopened: \(fileName) (\(segments.count) segments)."
            return statusMessage
        }

        let workspace = makeWorkspace(for: pdfURL)
        let assetsDirectory = workspace.appendingPathComponent("slideshow", isDirectory: true)
        try PDFSlideshowService.dumpSegmentAssets(segments: segments, pdfURL: pdfURL, into: assetsDirectory)
        let movieURL = workspace.appendingPathComponent(
            "\(Self.sanitizedFolderName(from: fileName)).mov",
            isDirectory: false
        )

        // Fresh clip: set the identifying state first — persistVideoProject
        // reads it when it writes the clip row.
        currentClipID = nil
        isSlideshowClip = true
        slideshowPDFPath = pdfURL.path
        videoPath = movieURL.path
        videoWorkspaceURL = workspace
        videoOriginalAudioVolume = 0
        paragraphs = layout.segments.map { segment in
            var paragraph = Paragraph(
                text: "",
                voiceID: defaultVoiceIDForNewClips(),
                gapDuration: defaultGap,
                segmentNumber: segment.number
            )
            paragraph.outputFilename = "clip_\(paragraph.id.uuidString).wav"
            return paragraph
        }

        // Initial timing: empty stubs → every segment holds the minimum dwell.
        let plan = recomputeSlideshowTiming(segments: segments)
        persistVideoProject()
        if let clipID = currentClipID {
            store.replaceSlideshowSegments(clipID: clipID, segments: segments)
        }

        try await PDFSlideshowService.bake(
            pdfURL: pdfURL,
            segments: segments,
            timing: plan.byNumber,
            to: movieURL
        )
        await prepareVideoPreview()
        await refreshVideoTimelineDuration()
        refreshClipSummaries()
        statusMessage = "Slideshow added: \(fileName) — \(segments.count) segments from \(layout.pageCount) pages."
        return statusMessage
    }

    /// Menu entry: pick a PDF and turn it into a slideshow clip.
    func importSlideshowViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        setAllowedContentTypes(panel, extensions: ["pdf"])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isProcessing = true
            do {
                _ = try await importSlideshow(pdfURL: url)
                openVideoTimeline()
            } catch {
                statusMessage = "Slideshow import failed: \(error.localizedDescription)"
            }
            isProcessing = false
        }
    }

    struct SlideshowTimingPlan {
        var byNumber: [Int: PDFSlideshowService.SegmentTiming] = [:]
        var totalDuration: Double = 0
    }

    /// Rebuild the segment layout from the PDF with the current splitter
    /// (content-aware breaks at whitespace), keeping narrations, voices and
    /// skip flags. Blank halves can disappear, so segment numbers may shift:
    /// narrations and skips re-link to the new segment covering the same
    /// page region (largest crop overlap), and orphans stay in the transcript
    /// unanchored. Re-bakes at the end.
    @discardableResult
    func reSplitSlideshow() async throws -> String {
        guard isSlideshowClip, let clipID = currentClipID, let store = projectStore,
              let pdfPath = slideshowPDFPath,
              FileManager.default.fileExists(atPath: pdfPath)
        else {
            throw NSError(
                domain: "ProjectViewModel",
                code: -55,
                userInfo: [NSLocalizedDescriptionKey: "The active clip is not a slideshow with a readable PDF."]
            )
        }
        let layout = try PDFSlideshowService.buildLayout(pdfURL: URL(fileURLWithPath: pdfPath))
        let previous = store.loadSlideshowSegments(clipID: clipID)

        // old number -> new number, by page + largest crop overlap.
        var renumbered: [Int: Int] = [:]
        for old in previous {
            var best: (number: Int, overlap: CGFloat)?
            for segment in layout.segments where segment.page == old.page {
                let intersection = segment.crop.intersection(old.crop)
                let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                if overlap > (best?.overlap ?? 0) {
                    best = (segment.number, overlap)
                }
            }
            if let best, best.overlap > 0 {
                renumbered[old.number] = best.number
            }
        }
        var takenTargets = Set<Int>()
        // Prefer the old segment with the LARGER overlap when two olds map to
        // one new (a blank half disappeared): keep order stable by old number.
        let sortedOlds = renumbered.keys.sorted()
        var finalRenumbered: [Int: Int] = [:]
        for oldNumber in sortedOlds {
            let target = renumbered[oldNumber]!
            if takenTargets.contains(target) { continue }
            takenTargets.insert(target)
            finalRenumbered[oldNumber] = target
        }

        // Carry skip flags by overlap too.
        var skippedByNewNumber: [Int: Bool] = [:]
        for old in previous {
            if old.skipped, let target = finalRenumbered[old.number] {
                skippedByNewNumber[target] = true
            }
        }

        let records = layout.segments.map {
            SlideshowSegmentRecord(
                number: $0.number,
                page: $0.page,
                crop: $0.crop,
                scrollsIn: $0.scrollsIn,
                skipped: skippedByNewNumber[$0.number] ?? false
            )
        }
        store.replaceSlideshowSegments(clipID: clipID, segments: records)

        // Re-link narration stubs to their new segment numbers; orphans (their
        // region is no longer a segment) leave the clip, and any segment left
        // without a stub gets a fresh one so narrate/generate can always
        // reach it.
        var relinked = 0
        var orphaned = 0
        for index in paragraphs.indices {
            guard let oldNumber = paragraphs[index].segmentNumber else { continue }
            if let newNumber = finalRenumbered[oldNumber] {
                paragraphs[index].segmentNumber = newNumber
                relinked += 1
            } else {
                paragraphs[index].segmentNumber = nil
                paragraphs[index].startTime = nil
                orphaned += 1
            }
        }
        paragraphs.removeAll { $0.segmentNumber == nil }
        let knownNumbers = Set(paragraphs.compactMap(\.segmentNumber))
        for record in records where !knownNumbers.contains(record.number) {
            var paragraph = Paragraph(
                text: "",
                voiceID: defaultVoiceIDForNewClips(),
                gapDuration: defaultGap,
                segmentNumber: record.number
            )
            paragraph.outputFilename = "clip_\(paragraph.id.uuidString).wav"
            paragraphs.append(paragraph)
        }

        if let workspace = videoWorkspaceURL {
            try? PDFSlideshowService.dumpSegmentAssets(
                segments: records,
                pdfURL: URL(fileURLWithPath: pdfPath),
                into: workspace.appendingPathComponent("slideshow", isDirectory: true)
            )
        }
        await refreshSlideshow(rebake: true)
        statusMessage = "Slideshow re-split: \(records.count) segments, \(relinked) narrations re-linked"
            + (orphaned > 0 ? ", \(orphaned) orphaned (region no longer a segment)" : "")
            + ", movie re-baked."
        return statusMessage
    }

    /// Segment spans from voice durations: measured takes when they exist,
    /// text estimates in between, minimum dwell while a stub is still empty.
    /// Mutates paragraph anchors (narration starts after the pan lands) and
    /// unanchors the stubs of skipped segments.
    @discardableResult
    func recomputeSlideshowTiming(segments: [SlideshowSegmentRecord]) -> SlideshowTimingPlan {
        var plan = SlideshowTimingPlan()
        var cursor = 0.0
        let includedNumbers = Set(segments.filter { !$0.skipped }.map(\.number))

        for segment in segments where includedNumbers.contains(segment.number) {
            let pan = segment.scrollsIn ? PDFSlideshowService.panSeconds : 0
            let narrationStart = cursor + pan + PDFSlideshowService.leadSeconds
            let voiceLength: Double
            if let index = paragraphs.firstIndex(where: { $0.segmentNumber == segment.number }) {
                voiceLength = audioDuration(forParagraphID: paragraphs[index].id)
                paragraphs[index].startTime = narrationStart
            } else {
                voiceLength = 0
            }
            let span = max(
                pan + PDFSlideshowService.leadSeconds + voiceLength + PDFSlideshowService.tailSeconds,
                PDFSlideshowService.minimumDwellSeconds
            )
            plan.byNumber[segment.number] = PDFSlideshowService.SegmentTiming(
                start: cursor,
                span: span,
                panSeconds: pan,
                narrationStart: narrationStart
            )
            cursor += span
        }

        for index in paragraphs.indices {
            if let number = paragraphs[index].segmentNumber, !includedNumbers.contains(number) {
                paragraphs[index].startTime = nil
            }
        }
        plan.totalDuration = cursor
        return plan
    }

    /// Recompute segment spans and (when `rebake`) rewrite the stills movie,
    /// then rebuild preview. Narration text edits recompute only — spans are
    /// estimates until the voices exist; generation and skip changes rebake.
    func refreshSlideshow(rebake: Bool) async {
        guard isSlideshowClip, let clipID = currentClipID, let store = projectStore else { return }
        guard let pdfPath = slideshowPDFPath, FileManager.default.fileExists(atPath: pdfPath) else {
            statusMessage = "The slideshow's PDF is no longer available: \(slideshowPDFPath ?? "?")"
            return
        }
        let segments = store.loadSlideshowSegments(clipID: clipID)
        guard !segments.isEmpty else { return }

        let plan = recomputeSlideshowTiming(segments: segments)
        canonicalizeClipOrder()
        persistVideoProject()
        videoTimelineDuration = plan.totalDuration

        guard rebake, let moviePath = videoPath else {
            await refreshVideoPreview()
            return
        }
        do {
            try await PDFSlideshowService.bake(
                pdfURL: URL(fileURLWithPath: pdfPath),
                segments: segments,
                timing: plan.byNumber,
                to: URL(fileURLWithPath: moviePath),
                progress: { [weak self] done, total in
                    Task { @MainActor in
                        self?.statusMessage = "Baking slideshow segment \(done) of \(total)…"
                    }
                }
            )
            await prepareVideoPreview()
            await refreshVideoTimelineDuration()
            statusMessage = "Slideshow baked — \(Paragraph.timecode(plan.totalDuration)) across \(segments.filter { !$0.skipped }.count) segments."
        } catch {
            statusMessage = "Slideshow bake failed: \(error.localizedDescription)"
        }
    }

    /// Paragraphs that have both a video anchor and generated audio, sorted by
    /// anchor time — exactly what export and preview mix into the video.
    func videoAnchoredClips() -> [VideoTimelineService.Clip] {
        guard videoPath != nil else { return [] }
        return paragraphs.compactMap { paragraph in
            guard let audioPath = paragraph.audioPath,
                  let start = paragraph.startTime else { return nil }
            return VideoTimelineService.Clip(audioURL: URL(fileURLWithPath: audioPath), startSeconds: start)
        }
        .sorted { $0.startSeconds < $1.startSeconds }
    }

    /// Every anchored paragraph as an occupied span of the voice track,
    /// whether its audio is generated (measured length) or not (estimate).
    struct VideoVoiceSpan {
        let id: UUID
        let start: Double
        let end: Double
    }

    var videoVoiceSpans: [VideoVoiceSpan] {
        paragraphs.compactMap { paragraph in
            guard let start = paragraph.startTime else { return nil }
            let length = max(audioDuration(forParagraphID: paragraph.id), 0.5)
            return VideoVoiceSpan(id: paragraph.id, start: start, end: start + length)
        }
        .sorted { $0.start < $1.start }
    }

    /// The first moment at or after `earliest` where no voice clip is
    /// sounding — where a new clip can be laid down without overlapping.
    func nextFreeVoiceSlot(after earliest: Double) -> Double {
        guard hasVideoClip else { return earliest }
        var target = max(0, earliest)
        for span in videoVoiceSpans {
            if target >= span.start && target < span.end {
                target = span.end
            }
        }
        if videoTimelineDuration > 0 {
            return min(target, videoTimelineDuration)
        }
        return target
    }

    /// Push clips that sit too close together apart: anything overlapping the
    /// previous clip (plus a small breathing gap) moves later. Recorded clips
    /// never move, so a growing take in front of one stays flagged instead.
    func autoGapVoiceClips(minimumGap: Double = 0.5) {
        // Slideshow spans are computed from voice durations; the free-placement
        // tidy-up would fight that math.
        guard !isSlideshowClip else { return }
        // Re-timing only needs clip durations (in the store), not the player;
        // clamp to the video length when it is known.
        let total = videoTimelineDuration > 0 ? videoTimelineDuration : Double.greatestFiniteMagnitude
        let ordered = paragraphs
            .filter { $0.startTime != nil }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }

        var floor: Double?
        for paragraph in ordered {
            var start = paragraph.startTime ?? 0
            if let floorValue = floor, !paragraph.isRecorded, start < floorValue {
                start = min(floorValue, total)
            }
            let length = max(audioDuration(forParagraphID: paragraph.id), 0.5)
            floor = start + length + minimumGap
            if start != (paragraph.startTime ?? 0),
               let index = paragraphs.firstIndex(where: { $0.id == paragraph.id }) {
                paragraphs[index].startTime = start
            }
        }
    }

    /// Live position update while a clip is dragged (no preview rebuild).
    func moveParagraphClip(_ id: UUID, to seconds: Double) {
        guard !isSlideshowClip,
              videoController.isLoaded,
              let index = paragraphs.firstIndex(where: { $0.id == id }),
              paragraphs[index].startTime != nil,
              !paragraphs[index].isRecorded
        else { return }
        paragraphs[index].startTime = max(0, min(seconds, videoController.duration))
    }

    /// Finish a clip drag: separate anything now too close and rebuild the
    /// preview once.
    func settleParagraphClip(_ id: UUID) {
        autoGapVoiceClips()
        Task { await refreshVideoPreview() }
    }

    /// Let a recorded clip be changed again. Re-run spacing right away: while
    /// it was locked, neighbours could not be pushed apart around it.
    func unlockParagraph(_ id: UUID) {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }),
              paragraphs[index].isRecorded
        else { return }
        paragraphs[index].isRecorded = false
        autoGapVoiceClips()
        Task { await refreshVideoPreview() }
        statusMessage = "Clip \(index + 1) unlocked — it can be moved and changed again; too-close clips were re-spaced."
    }

    /// Anchor a paragraph at `seconds` into the attached video. Returns the
    /// clamped time that was set, or nil when no usable video is loaded.
    @discardableResult
    func setParagraphStart(_ id: UUID, at seconds: Double) -> Double? {
        if isSlideshowClip {
            statusMessage = "Slideshow voice positions are computed from their summaries — edit the text instead."
            return nil
        }
        guard videoController.isLoaded else {
            statusMessage = "Attach a video before anchoring paragraphs."
            return nil
        }
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return nil }
        if paragraphs[index].isRecorded {
            statusMessage = "Clip \(index + 1) is recorded to the video — unlock it before moving it."
            return nil
        }
        let clamped = max(0, min(seconds, videoController.duration))
        paragraphs[index].startTime = clamped
        autoGapVoiceClips()
        statusMessage = "Paragraph \(index + 1) anchored at \(Paragraph.timecode(paragraphs[index].startTime ?? clamped))."
        Task { await refreshVideoPreview() }
        return clamped
    }

    /// Measured WAV durations per paragraph, refreshed after generation and
    /// when a project loads. The voice track draws clips from these; text
    /// without audio yet shows an estimate.
    @Published var paragraphAudioDurations: [UUID: Double] = [:]

    /// Digest of the text each existing take was generated from. A mismatch
    /// with the paragraph's current text means the take is stale and
    /// "generate missing" will redo it.
    @Published var paragraphAudioTextDigests: [UUID: String] = [:]

    /// A paragraph needs (re)generation when it has no usable take, or when
    /// the take on file was generated from different text.
    func needsAudioRefresh(_ paragraph: Paragraph) -> Bool {
        guard let path = paragraph.audioPath,
              FileManager.default.fileExists(atPath: path)
        else { return true }
        return paragraphAudioTextDigests[paragraph.id] != ProjectStore.textDigest(paragraph.text)
    }

    /// Rough speaking length for ungenerated text: ~2.6 words per second at
    /// normal speed, adjusted by the paragraph's speed preset.
    static func estimatedSpeechDuration(for text: String, speedRate: Float) -> Double {
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        guard words > 0 else { return 1.0 }
        let rate = max(0.5, speedRate)
        return max(0.8, words / (2.6 * Double(rate)) + 0.3)
    }

    /// The voice clip's length on the track: the measured audio duration when
    /// the WAV exists, otherwise the text estimate.
    func audioDuration(forParagraphID id: UUID) -> Double {
        guard let paragraph = paragraphs.first(where: { $0.id == id }) else { return 0 }
        if let measured = paragraphAudioDurations[id] {
            return measured
        }
        return Self.estimatedSpeechDuration(for: paragraph.text, speedRate: paragraph.speed.rate)
    }

    func hasMeasuredAudioDuration(_ id: UUID) -> Bool {
        paragraphAudioDurations[id] != nil
    }

    func measureAudioDuration(for id: UUID) async {
        guard let paragraph = paragraphs.first(where: { $0.id == id }),
              let path = paragraph.audioPath,
              FileManager.default.fileExists(atPath: path)
        else { return }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
            paragraphAudioDurations[id] = seconds
        }
    }

    func refreshParagraphAudioDurations() async {
        for paragraph in paragraphs where paragraph.audioPath != nil {
            await measureAudioDuration(for: paragraph.id)
        }
    }

    /// Create a new, empty voice clip at the next free segment at or after
    /// the playhead — the in-timeline writing flow. Reuses an existing empty
    /// clip already sitting at that spot instead of stacking a duplicate, and
    /// drops the untouched starter paragraph so it never shows up as a ghost.
    @discardableResult
    func createParagraphAtPlayhead() -> UUID? {
        // A slideshow narrates exactly one summary per segment; new free clips
        // would have no viewport to belong to.
        if isSlideshowClip {
            statusMessage = "Slideshow clips narrate one summary per segment — edit the existing entries."
            return nil
        }
        // Voice-only clips append sequentially — the timeline places them.
        guard hasVideoClip else {
            if let blocked = insertionBlockedMessage {
                statusMessage = blocked
                return nil
            }
            paragraphs.removeAll { paragraph in
                paragraph.text == Self.starterParagraphText
                    && paragraph.startTime == nil
                    && paragraph.audioPath == nil
                    && !paragraph.isGenerating
            }
            var paragraph = Paragraph(text: "", voiceID: defaultVoiceIDForNewClips())
            paragraph.outputFilename = "clip_\(paragraph.id.uuidString).wav"
            paragraph.gapDuration = defaultGap
            paragraphs.append(paragraph)
            Task { await refreshVideoPreview() }
            return paragraph.id
        }

        guard videoController.isLoaded else {
            statusMessage = "Attach a video before adding text."
            return nil
        }

        // Drop the pristine default paragraph ("New paragraph text here.")
        // once real clips exist for this video.
        paragraphs.removeAll { paragraph in
            paragraph.text == Self.starterParagraphText
                && paragraph.startTime == nil
                && paragraph.audioPath == nil
                && !paragraph.isGenerating
        }

        // New clips always go to the right: past the red bar AND past the end
        // of the last clip on the track, then into free space. The explicit
        // max over every anchored start is a belt-and-braces invariant —
        // creation must never place a clip before an existing one.
        let lastClipEnd = videoVoiceSpans.last?.end ?? 0
        let latestStart = paragraphs.compactMap(\.startTime).max() ?? 0
        let earliest = max(videoController.playbackTime, lastClipEnd + 0.5, latestStart + 0.5)
        let target = nextFreeVoiceSlot(after: (earliest * 10).rounded() / 10)
        assert(target >= latestStart, "clip creation would reorder the timeline")

        // An empty, ungenerated clip already parked at the target IS the new
        // clip — reuse it rather than overlapping a duplicate.
        if let existing = paragraphs.first(where: { paragraph in
            guard paragraph.startTime != nil, paragraph.audioPath == nil,
                  paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return abs((paragraph.startTime ?? 0) - target) < 0.15
        }) {
            videoController.seek(to: existing.startTime ?? target)
            statusMessage = "Reused the empty clip at \(Paragraph.timecode(target)) — type its narration."
            return existing.id
        }

        var paragraph = Paragraph(text: "", voiceID: defaultVoiceIDForNewClips())
        if paragraph.outputFilename.isEmpty {
            paragraph.outputFilename = "para_\(paragraph.id.uuidString.prefix(8)).wav"
        }
        paragraph.gapDuration = defaultGap
        paragraph.startTime = target
        paragraphs.append(paragraph)
        statusMessage = "New clip at \(Paragraph.timecode(target)) — type its narration, then press + to continue."
        Task { await refreshVideoPreview() }
        return paragraph.id
    }

    /// Empty anchored clips with no audio are writing placeholders: drop them
    /// once they are no longer the clip being written, so abandoned "+" presses
    /// never linger on the track.
    func purgeEmptyPlaceholders(keeping keptID: UUID? = nil) {
        // Slideshow stubs are empty by design until the agent writes them.
        guard !isSlideshowClip else { return }
        paragraphs.removeAll { paragraph in
            paragraph.id != keptID
                && paragraph.startTime != nil
                && paragraph.audioPath == nil
                && paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !paragraph.isGenerating
        }
    }

    /// Remove anchored, empty, ungenerated clips that collide with another
    /// anchored clip — leftovers from overlap-era edits that would otherwise
    /// show as confusing overlapping tracks.
    func dedupeVideoTimeline() {
        guard !isSlideshowClip else { return }
        let anchored = paragraphs.filter { $0.startTime != nil }
        let removals = anchored.filter { paragraph in
            guard paragraph.audioPath == nil,
                  paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return anchored.contains { other in
                other.id != paragraph.id
                    && other.startTime != nil
                    && abs((other.startTime ?? 0) - (paragraph.startTime ?? 0)) < 0.15
                    && (other.audioPath != nil
                        || !other.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        guard !removals.isEmpty else { return }
        let ids = Set(removals.map(\.id))
        paragraphs.removeAll { ids.contains($0.id) }
    }

    func clearParagraphStart(_ id: UUID) {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        guard paragraphs[index].startTime != nil else { return }
        paragraphs[index].startTime = nil
        Task { await refreshVideoPreview() }
    }

    func clearAllParagraphStarts() {
        guard paragraphs.contains(where: { $0.startTime != nil }) else { return }
        for index in paragraphs.indices {
            paragraphs[index].startTime = nil
        }
        statusMessage = "Cleared all paragraph anchors."
        Task { await refreshVideoPreview() }
    }

    func exportVideoWithVoiceOver() async {
        guard !isVideoExporting else { return }
        guard let path = videoPath, FileManager.default.fileExists(atPath: path) else {
            statusMessage = "Attach a video before exporting."
            return
        }
        guard !videoAnchoredClips().isEmpty else {
            statusMessage = "Anchor at least one paragraph (with generated audio) before exporting."
            return
        }

        let panel = NSSavePanel()
        panel.directoryURL = videoWorkspaceURL ?? documentsURL
        setAllowedContentTypes(panel, extensions: ["mov"])
        let baseName = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
        panel.nameFieldStringValue = "\(baseName)-voiceover.mov"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            _ = try await scriptExportVideo(to: destinationURL)
            revealExportedInNewFinderWindow(destinationURL)
        } catch {
            statusMessage = "Video export failed: \(error.localizedDescription)"
        }
    }

    /// Shared video export path: UI reaches it after its save panel, Apple
    /// Events supply the destination directly. Returns export notes ("" when
    /// every paragraph took part).
    @discardableResult
    func scriptExportVideo(to destinationURL: URL) async throws -> String {
        guard let path = videoPath, FileManager.default.fileExists(atPath: path) else {
            throw ScriptingError.videoNotAttached
        }
        let clips = videoAnchoredClips()
        guard !clips.isEmpty else {
            throw ScriptingError.noAnchoredVideoClips
        }

        isVideoExporting = true
        isProcessing = true
        statusMessage = "Mixing narration and copying the video (no re-encode)…"
        defer {
            isVideoExporting = false
            isProcessing = false
        }

        let videoAsset = AVURLAsset(url: URL(fileURLWithPath: path))
        do {
            try await VideoTimelineService.remuxExport(
                videoAsset: videoAsset,
                clips: clips,
                originalAudioVolume: Float(videoOriginalAudioVolume),
                to: destinationURL
            )
        } catch {
            // The faithful copy path failed; fall back to a full re-encode.
            statusMessage = "Fast copy failed (\(error.localizedDescription)) — re-encoding instead…"
            let (composition, audioMix) = try await VideoTimelineService.makeComposition(
                videoAsset: videoAsset,
                clips: clips,
                originalAudioVolume: Float(videoOriginalAudioVolume)
            )
            try await VideoTimelineService.export(
                composition: composition,
                audioMix: audioMix,
                to: destinationURL
            )
        }

        let anchoredWithoutAudio = paragraphs.filter { $0.startTime != nil && $0.audioPath == nil }.count
        let generatedWithoutAnchor = paragraphs.filter { $0.startTime == nil && $0.audioPath != nil }.count
        var notes: [String] = []
        if anchoredWithoutAudio > 0 {
            notes.append("\(anchoredWithoutAudio) anchored paragraph(s) had no audio and were skipped")
        }
        if generatedWithoutAnchor > 0 {
            notes.append("\(generatedWithoutAnchor) generated paragraph(s) were not anchored")
        }
        let newlyRecorded = markExportedClipsRecorded()
        let suffix = notes.isEmpty ? "" : " — " + notes.joined(separator: "; ") + "."
        statusMessage = "Video exported: \(destinationURL.lastPathComponent)" + suffix
            + (newlyRecorded > 0 ? " \(newlyRecorded) clip(s) recorded and locked." : "")
        persistVideoProject()
        return suffix
    }

    /// Open a Finder window on the export's folder with the file selected —
    /// the answer to "where did it go". UI exports only: scripted exports
    /// (smoke suite, agents) must never touch the user's screen, and
    /// activateFileViewerSelecting never hands the file to a player app.
    private func revealExportedInNewFinderWindow(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Clips included in an export are committed: mark them recorded (locked)
    /// and return how many changed state.
    @discardableResult
    func markExportedClipsRecorded() -> Int {
        var changed = 0
        for index in paragraphs.indices
        where paragraphs[index].audioPath != nil
            && paragraphs[index].startTime != nil
            && !paragraphs[index].isRecorded {
            paragraphs[index].isRecorded = true
            changed += 1
        }
        return changed
    }

    func exportVoiceTrackOnly() async {
        guard !isVideoExporting else { return }
        guard let path = videoPath, FileManager.default.fileExists(atPath: path) else {
            statusMessage = "Attach a video before exporting the voice track."
            return
        }
        guard !videoAnchoredClips().isEmpty else {
            statusMessage = "Anchor at least one paragraph (with generated audio) first."
            return
        }

        let panel = NSSavePanel()
        panel.directoryURL = videoWorkspaceURL ?? documentsURL
        setAllowedContentTypes(panel, extensions: ["wav"])
        let baseName = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
        panel.nameFieldStringValue = "\(baseName)-voice-track.wav"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            _ = try await scriptExportVoiceTrack(to: destinationURL)
            revealExportedInNewFinderWindow(destinationURL)
        } catch {
            statusMessage = "Voice track export failed: \(error.localizedDescription)"
        }
    }

    /// Voice-track-only export: a WAV spanning the video's full duration with
    /// each voice mixed in at its anchor time and silence elsewhere, ready to
    /// attach in a separate video editor. The video is only the timing
    /// reference; none of its audio is included.
    @discardableResult
    func scriptExportVoiceTrack(to destinationURL: URL) async throws -> String {
        guard let path = videoPath, FileManager.default.fileExists(atPath: path) else {
            throw ScriptingError.videoNotAttached
        }
        let clips = videoAnchoredClips()
        guard !clips.isEmpty else {
            throw ScriptingError.noAnchoredVideoClips
        }
        let duration = try await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NSError(
                domain: "ProjectViewModel",
                code: -43,
                userInfo: [NSLocalizedDescriptionKey: "The attached video reports no usable duration."]
            )
        }

        isVideoExporting = true
        isProcessing = true
        statusMessage = "Rendering voice track…"
        defer {
            isVideoExporting = false
            isProcessing = false
        }

        try await VideoTimelineService.renderVoiceTrack(
            clips: clips,
            totalDuration: duration,
            to: destinationURL
        )
        let newlyRecorded = markExportedClipsRecorded()
        statusMessage = "Voice track exported: \(destinationURL.lastPathComponent)"
            + (newlyRecorded > 0 ? " \(newlyRecorded) clip(s) recorded and locked." : "")
        persistVideoProject()
        return destinationURL.path
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

    func initializeEngines(managesProcessingState: Bool) async {
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
    
    /// Identity-addressed binding for a jingle card; same rationale as
    /// paragraphBinding(_:) — index bindings trap when the array shrinks.
    func jingleCardBinding(_ id: UUID) -> Binding<ABCJingleCard> {
        Binding(
            get: { [weak self] in
                self?.jingleCards.first(where: { $0.id == id }) ?? ABCJingleCard(id: id, name: "")
            },
            set: { [weak self] newValue in
                guard let self, let index = self.jingleCards.firstIndex(where: { $0.id == id }) else { return }
                self.jingleCards[index] = newValue
            }
        )
    }

    /// Identity-addressed binding for a paragraph row. ForEach($paragraphs)
    /// bindings index into the array and trap when a removal lands between a
    /// mutation and the next render pass; resolving by id is always safe.
    func paragraphBinding(_ id: UUID) -> Binding<Paragraph> {
        Binding(
            get: { [weak self] in
                self?.paragraphs.first(where: { $0.id == id }) ?? Paragraph(text: "")
            },
            set: { [weak self] newValue in
                guard let self, let index = self.paragraphs.firstIndex(where: { $0.id == id }) else { return }
                self.paragraphs[index] = newValue
            }
        )
    }

    static let starterParagraphText = "New paragraph text here."

    /// Reference Voice is the point of the app: when one is enrolled it is
    /// the default for every new clip; preset voices remain a fallback.
    func defaultVoiceIDForNewClips() -> String {
        referenceVoiceProfile != nil ? ReferenceVoiceProfile.voiceID : defaultVoiceConfigurationID()
    }

    /// The launch starter ignores timeline capacity — an empty editor is
    /// never the right answer to a full video.
    private func addStarterParagraphIfEmpty() {
        guard paragraphs.isEmpty else { return }
        var paragraph = Paragraph(text: Self.starterParagraphText, voiceID: defaultVoiceIDForNewClips())
        paragraph.outputFilename = "clip_\(paragraph.id.uuidString).wav"
        paragraph.gapDuration = defaultGap
        paragraphs.append(paragraph)
    }

    func addParagraph() {
        var p = Paragraph(text: Self.starterParagraphText, voiceID: defaultVoiceIDForNewClips())
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
            referenceVoiceEnrollmentStatus = "Record in a quiet room. Best results use the Qwen3-TTS 1.7B Base cloning model with about 8 to 12 seconds of clean speech."
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
                modelUpdateNarrative = "Preparing the cloning model (Qwen3-TTS 1.7B Base) for Reference Voice..."
                referenceVoiceEnrollmentStatus = "Downloading the cloning model needed for Reference Voice..."
                _ = try await ttsService.downloadModel(modelRepo: preferredRepo) { progress in
                    self.modelUpdateProgress = max(0.0, min(progress.fractionCompleted, 1.0))
                    let percent = Int((progress.fractionCompleted * 100.0).rounded())
                    self.modelUpdateNarrative = "Downloading the cloning model... \(percent)%"
                    self.referenceVoiceEnrollmentStatus = "Downloading the cloning model for Reference Voice... \(percent)%"
                }
            } else {
                modelUpdateProgress = 0.85
                modelUpdateNarrative = "Cloning model already cached. Loading it for Reference Voice..."
                referenceVoiceEnrollmentStatus = "Loading the cloning model for Reference Voice..."
            }

            modelUpdateProgress = max(modelUpdateProgress, 0.92)
            modelUpdateNarrative = "Loading the cloning model..."
            try await ttsService.initializeTTS(modelRepo: preferredRepo)
            isTTSReady = true
            voiceOptions = computedVoiceOptions()
            remapParagraphVoicesIfNeeded()

            modelUpdateProgress = 1.0
            modelUpdateNarrative = "Cloning model ready."
            referenceVoiceEnrollmentStatus = "Cloning model ready. You can record and save a Reference Voice now."
            statusMessage = "Reference Voice model ready."
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            modelUpdateNarrative = "Idle"
        } catch {
            modelUpdateNarrative = "Cloning model setup failed."
            referenceVoiceEnrollmentStatus = "Failed to prepare the cloning model: \(error.localizedDescription)"
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

        persistReferenceVoiceProfile(transcript: transcript, summary: summary, cleanedWithEnhancement: false)
    }

    func cleanAndSaveReferenceVoiceProfile() async {
        let transcript = referenceVoiceScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            referenceVoiceEnrollmentStatus = "Add or generate a reference script first."
            return
        }
        guard FileManager.default.fileExists(atPath: referenceVoiceRecordingURL.path) else {
            referenceVoiceEnrollmentStatus = "Record a reference sample before cleaning and saving."
            return
        }

        isCleaningReferenceVoice = true
        isProcessing = true
        referenceVoiceEnrollmentStatus = "Loading speech cleanup model..."
        statusMessage = "Preparing speech cleanup..."
        defer {
            isCleaningReferenceVoice = false
            isProcessing = false
        }

        let cleanedURL = referenceVoiceDirectoryURL.appendingPathComponent("reference-voice.cleaned.wav", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: referenceVoiceDirectoryURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cleanedURL.path) {
                try FileManager.default.removeItem(at: cleanedURL)
            }

            referenceVoiceEnrollmentStatus = "Cleaning background noise from the recording..."
            try await referenceVoiceEnhancementService.enhanceRecording(
                at: referenceVoiceRecordingURL,
                outputURL: cleanedURL
            )

            referenceVoiceEnrollmentStatus = "Finalizing cleaned sample..."
            let summary = try referenceVoiceRecorder.finalizeRecording(
                at: cleanedURL,
                targetSampleRate: ttsService.sampleRate
            )

            if FileManager.default.fileExists(atPath: referenceVoiceRecordingURL.path) {
                try FileManager.default.removeItem(at: referenceVoiceRecordingURL)
            }
            try FileManager.default.moveItem(at: cleanedURL, to: referenceVoiceRecordingURL)

            persistReferenceVoiceProfile(transcript: transcript, summary: summary, cleanedWithEnhancement: true)
        } catch {
            try? FileManager.default.removeItem(at: cleanedURL)
            referenceVoiceEnrollmentStatus = "Failed to clean reference voice: \(error.localizedDescription)"
            statusMessage = "Reference Voice cleanup failed: \(error.localizedDescription)"
        }
    }

    private func persistReferenceVoiceProfile(
        transcript: String,
        summary: ReferenceVoiceRecorder.RecordingSummary,
        cleanedWithEnhancement: Bool
    ) {

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
            let guidance = TTSService.prefersReferenceVoiceModel(modelRepo: ttsModelRepo)
                ? ""
                : " Switch Qwen to \(TTSService.preferredReferenceVoiceModelRepo) for real cloning quality."
            let silenceNote = summary.trimmedSilence ? " Leading/trailing silence removed." : ""
            let cleanupNote = cleanedWithEnhancement ? " Background noise reduced." : ""
            referenceVoiceEnrollmentStatus = "Reference Voice saved (\(durationText)s cleaned sample).\(silenceNote)\(cleanupNote)\(guidance)"
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
        let removedID = paragraphs[index].id
        let replacementAnchor = index > 0 ? paragraphs[index - 1].id : nil
        paragraphs.remove(at: index)
        reanchorTimelineItems(from: removedID, to: replacementAnchor)
    }

    func removeParagraph(_ id: UUID) {
        guard let index = paragraphs.firstIndex(where: { $0.id == id }) else { return }
        let replacementAnchor = index > 0 ? paragraphs[index - 1].id : nil
        paragraphs.remove(at: index)
        reanchorTimelineItems(from: id, to: replacementAnchor)
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
        copy.startTime = nil
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
        if isSlideshowClip {
            // Every take changed the spans; one bake at the end picks them
            // all up.
            await refreshSlideshow(rebake: true)
        }
        statusMessage = "All \(ids.count) paragraphs generated."
        isProcessing = false
    }

    /// The agent's bulk verb for large documents: synthesize only what is
    /// missing or stale (take generated from different text). Re-bakes a
    /// slideshow once at the end. Returns how many takes were written.
    @discardableResult
    func generateMissingAudio() async -> Int {
        guard isTTSReady else {
            statusMessage = "Initialize TTS before generating."
            return 0
        }
        // Skipped segments keep their stubs for the transcript but never
        // render — generating takes for them (an empty stub would loop
        // forever) is wasted work.
        var skippedSegments = Set<Int>()
        if isSlideshowClip, let clipID = currentClipID, let store = projectStore {
            skippedSegments = Set(
                store.loadSlideshowSegments(clipID: clipID).filter(\.skipped).map(\.number)
            )
        }
        let pending = paragraphs.filter { paragraph in
            if let number = paragraph.segmentNumber, skippedSegments.contains(number) {
                return false
            }
            return needsAudioRefresh(paragraph)
        }
        guard !pending.isEmpty else {
            statusMessage = "Nothing to generate — every paragraph has a current take."
            return 0
        }
        isProcessing = true
        for (i, paragraph) in pending.enumerated() {
            statusMessage = "Generating missing \(i + 1) of \(pending.count)…"
            await generateAudio(for: paragraph.id)
        }
        if isSlideshowClip {
            await refreshSlideshow(rebake: true)
        }
        statusMessage = "Generated \(pending.count) missing or stale paragraph\(pending.count == 1 ? "" : "s")."
        isProcessing = false
        return pending.count
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

        if paragraphs[index].isRecorded {
            statusMessage = "Clip \(index + 1) is recorded to the video — unlock it before regenerating."
            return
        }

        // Qwen3-TTS traps the process on empty or near-empty text: the ChatML
        // template adds ~8 tokens around the text and the model slices its
        // embedding as 4..<(count-5), which is an invalid range — and a hard
        // SIGTRAP — once the text contributes fewer than ~2 tokens. Reject it
        // here instead of crashing.
        let trimmedText = paragraphs[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmedText.split(whereSeparator: \.isWhitespace).count
        guard wordCount >= 2 else {
            statusMessage = wordCount == 0
                ? "Paragraph \(index + 1) is empty — type the narration before generating."
                : "Paragraph \(index + 1) is too short to synthesize — use at least two words."
            return
        }

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
        // Paragraph audio lives in the attached video's working folder when
        // there is one; audio-only projects keep writing next to Documents.
        // Video clips use the full paragraph UUID as the filename: unique by
        // construction, so no two takes can ever overwrite each other.
        let outputDirectory = videoWorkspaceURL ?? documentsURL
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let uniqueName = "clip_\(id.uuidString).wav"
        let outputName = (videoWorkspaceURL != nil) ? uniqueName : filename
        let outputPath = outputDirectory.appendingPathComponent(outputName).path

        if voiceID == ReferenceVoiceProfile.voiceID, referenceVoice == nil {
            statusMessage = "Enroll a Reference Voice before using that speaker preset."
            paragraphs[index].isGenerating = false
            isProcessing = false
            return
        }

        if voiceID == ReferenceVoiceProfile.voiceID,
           !TTSService.prefersReferenceVoiceModel(modelRepo: trimmedRepo)
        {
            let preferredRepo = TTSService.preferredReferenceVoiceModelRepo
            if ttsService.isModelCached(modelRepo: preferredRepo) {
                statusMessage = "Switching to the cloning model (Qwen3-TTS 1.7B Base) for Reference Voice..."
                do {
                    ttsModelRepo = preferredRepo
                    try await ttsService.initializeTTS(modelRepo: preferredRepo)
                    isTTSReady = true
                    voiceOptions = computedVoiceOptions()
                    remapParagraphVoicesIfNeeded()
                } catch {
                    statusMessage = "Reference Voice needs the cloning model: \(error.localizedDescription)"
                    paragraphs[index].isGenerating = false
                    isProcessing = false
                    return
                }
            } else {
                statusMessage = "Reference Voice needs the cloning model \(preferredRepo). Download it in Settings first."
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
            paragraphAudioTextDigests[id] = ProjectStore.textDigest(text)
            await measureAudioDuration(for: id)
            if isSlideshowClip {
                // Spans are voice-driven: recompute anchors now, re-bake in a
                // batch (generate all / the bake verb) so 60 pages don't
                // re-encode 60 times.
                await refreshSlideshow(rebake: false)
            } else {
                autoGapVoiceClips()
            }
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
                normalizeJingleTimelineItems()
                statusMessage = "Transcript loaded (\(loaded.count) paragraphs)."
                Task { await refreshParagraphAudioDurations() }
            } catch {
                statusMessage = "Load failed: \(error.localizedDescription)"
            }
        }
    }
    
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        midiPreviewPlayer?.stop()
        midiPreviewPlayer = nil
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

    private func defaultMIDISoundBankURL() -> URL? {
        MIDIAudioRenderer.defaultSoundBankURL()
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

        let exportSegments: [(url: URL, gapAfter: Double)]
        do {
            exportSegments = try buildFullSequenceExportSegments()
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
            return
        }

        guard !exportSegments.isEmpty else {
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

        for item in exportSegments {
            let asset = AVURLAsset(url: item.url)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let assetTrack = tracks.first else { continue }
                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                try track.insertTimeRange(timeRange, of: assetTrack, at: currentTime)

                currentTime = CMTimeAdd(currentTime, duration)

                let gapSeconds = item.gapAfter
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

    func buildFullSequenceExportSegments() throws -> [(url: URL, gapAfter: Double)] {
        var segments: [(url: URL, gapAfter: Double)] = []
        var renderedJingleAudio: [UUID: URL] = [:]

        for item in jingleTimelineItems(after: nil) {
            let audioURL = try renderedAudioURL(for: item.jingleCardID, cache: &renderedJingleAudio)
            segments.append((audioURL, 0))
        }

        for paragraph in paragraphs {
            guard let path = paragraph.audioPath else { continue }
            segments.append((URL(fileURLWithPath: path), max(0, paragraph.gapDuration)))

            for item in jingleTimelineItems(after: paragraph.id) {
                let audioURL = try renderedAudioURL(for: item.jingleCardID, cache: &renderedJingleAudio)
                segments.append((audioURL, 0))
            }
        }

        return segments
    }

    private func renderedAudioURL(for jingleCardID: UUID, cache: inout [UUID: URL]) throws -> URL {
        if let cachedURL = cache[jingleCardID] {
            return cachedURL
        }

        guard let card = jingleCards.first(where: { $0.id == jingleCardID }) else {
            throw NSError(domain: "ProjectViewModel", code: -30, userInfo: [NSLocalizedDescriptionKey: "Missing jingle card for export."])
        }

        let renderResult = try abcJingleService.render(card: card)
        let audioURL = jingleCacheDirectoryURL.appendingPathComponent("jingle-audio-\(jingleCardID.uuidString).wav", isDirectory: false)
        try MIDIAudioRenderer.render(midiData: renderResult.midiData, midiTracks: renderResult.midiTracks, outputURL: audioURL)
        try writeJingleMIDIDiagnostics(result: renderResult, midiURL: audioURL.deletingPathExtension().appendingPathExtension("mid"))
        cache[jingleCardID] = audioURL
        return audioURL
    }

    func remapParagraphVoicesIfNeeded() {
        // Before the engine reports its presets the list is empty; remapping
        // against nothing would reset every stored voice to the default
        // preset. Wait until real options exist.
        guard !voiceOptions.isEmpty else { return }
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

    func normalizeJingleTimelineItems() {
        let validParagraphIDs = Set(paragraphs.map(\.id))
        let validJingleIDs = Set(jingleCards.map(\.id))
        jingleTimelineItems = jingleTimelineItems.compactMap { item in
            guard validJingleIDs.contains(item.jingleCardID) else { return nil }
            var normalized = item
            if let afterParagraphID = normalized.afterParagraphID,
               !validParagraphIDs.contains(afterParagraphID) {
                normalized.afterParagraphID = nil
            }
            return normalized
        }
        persistJingleTimelineStore()
    }

    private func reanchorTimelineItems(from oldParagraphID: UUID, to newParagraphID: UUID?) {
        jingleTimelineItems = jingleTimelineItems.map { item in
            guard item.afterParagraphID == oldParagraphID else { return item }
            var updated = item
            updated.afterParagraphID = newParagraphID
            return updated
        }
        persistJingleTimelineStore()
    }

    private func timelineStartSeconds(for itemID: UUID) -> Double {
        var currentTime = 0.0

        for item in jingleTimelineItems(after: nil) {
            if item.id == itemID {
                return currentTime
            }
            currentTime += timelineJingleDurationSeconds(for: item.jingleCardID)
        }

        for paragraph in paragraphs {
            currentTime += estimatedParagraphDuration(for: paragraph)
            currentTime += max(0, paragraph.gapDuration)

            for item in jingleTimelineItems(after: paragraph.id) {
                if item.id == itemID {
                    return currentTime
                }
                currentTime += timelineJingleDurationSeconds(for: item.jingleCardID)
            }
        }

        return currentTime
    }

    private func timelineJingleDurationSeconds(for jingleCardID: UUID) -> Double {
        max(0, jingleCards.first(where: { $0.id == jingleCardID })?.promptSpec.targetDurationSeconds ?? 0)
    }

    private func estimatedParagraphDuration(for paragraph: Paragraph) -> Double {
        let words = max(1, paragraph.text.split(whereSeparator: \.isWhitespace).count)
        let wordsPerSecond = max(1.5, 2.6 * Double(paragraph.speed.rate))
        return max(0.8, Double(words) / wordsPerSecond)
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

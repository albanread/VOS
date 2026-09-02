//
//  ProjectViewModel+Scripting.swift
//  VoiceOverStudio
//
//  Panel-free variants of the project file operations. The UI versions put an
//  NSSavePanel / NSOpenPanel in front of these; Apple Events supply the path
//  directly, so the scripting layer calls these instead.
//

import AVFoundation
import Foundation

extension ProjectViewModel {

    enum ScriptingError: LocalizedError {
        case noAudioToExport
        case compositionFailed
        case exportSessionUnavailable
        case paragraphNotFound
        case jingleNotFound
        case noWindow
        case videoNotAttached
        case noAnchoredVideoClips

        var errorDescription: String? {
            switch self {
            case .noAudioToExport:
                return "No paragraph audio has been generated yet."
            case .compositionFailed:
                return "Could not create the audio composition track."
            case .exportSessionUnavailable:
                return "Could not create an export session for the chosen format."
            case .paragraphNotFound:
                return "No paragraph with that identifier exists."
            case .jingleNotFound:
                return "No jingle with that identifier exists."
            case .noWindow:
                return "The application has no window to capture."
            case .videoNotAttached:
                return "No video is attached. Use 'attach video to' with a movie file path first."
            case .noAnchoredVideoClips:
                return "No narrations are anchored with generated audio for video export. Use 'anchor' after synthesizing."
            }
        }
    }

    // MARK: - Transcript

    func scriptSaveTranscript(to url: URL) throws {
        let data = try JSONEncoder().encode(paragraphs)
        try data.write(to: url)
        statusMessage = "Transcript saved to \(url.lastPathComponent)"
    }

    @discardableResult
    func scriptLoadTranscript(from url: URL) throws -> Int {
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
        return loaded.count
    }

    // MARK: - Sequence export

    /// Build the stitched composition and write it, without prompting for a destination.
    func scriptExportSequence(to destinationURL: URL, format: ExportFormat) async throws {
        statusMessage = "Exporting full sequence..."

        let exportSegments = try buildFullSequenceExportSegments()
        guard !exportSegments.isEmpty else {
            statusMessage = "No audio generated to export."
            throw ScriptingError.noAudioToExport
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            statusMessage = "Failed to create audio track."
            throw ScriptingError.compositionFailed
        }

        var currentTime = CMTime.zero
        for item in exportSegments {
            let asset = AVURLAsset(url: item.url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let assetTrack = tracks.first else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: assetTrack,
                at: currentTime
            )
            currentTime = CMTimeAdd(currentTime, duration)

            if item.gapAfter > 0 {
                let gapDuration = CMTime(seconds: item.gapAfter, preferredTimescale: 600)
                track.insertEmptyTimeRange(CMTimeRange(start: currentTime, duration: gapDuration))
                currentTime = CMTimeAdd(currentTime, gapDuration)
            }
        }

        let presetName = (format == .wav) ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: presetName) else {
            statusMessage = "Export failed: no export session."
            throw ScriptingError.exportSessionUnavailable
        }

        try await exportSession.export(to: destinationURL, as: (format == .wav) ? .wav : .m4a)
        statusMessage = "Exported: \(destinationURL.lastPathComponent)"
    }

    // MARK: - Jingles

    func scriptExportJingleMIDI(id: UUID, to url: URL) throws {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else {
            throw ScriptingError.jingleNotFound
        }

        let result = try abcJingleService.exportMIDI(abcSource: jingleCards[index].abcSource, to: url)
        try writeJingleMIDIDiagnostics(result: result, midiURL: url)
        let safety = abcJingleService.suggestedSpeechSafety(for: result.analysis)
        jingleCards[index] = jingleCards[index].updatingValidationState(
            speechSafety: safety,
            cachedMIDIPath: url.path
        )
        statusMessage = "Exported MIDI for jingle \(jingleCards[index].name)."
        persistJingleCardStore()
    }

    /// Validate a jingle and return a readable report rather than only setting status.
    func scriptValidateJingle(id: UUID) throws -> String {
        guard let index = jingleCards.firstIndex(where: { $0.id == id }) else {
            throw ScriptingError.jingleNotFound
        }

        let card = jingleCards[index]
        let result = try abcJingleService.validate(card: card)
        let safety = abcJingleService.suggestedSpeechSafety(for: result.analysis)
        jingleCards[index] = card.updatingValidationState(speechSafety: safety)
        persistJingleCardStore()

        var lines = ["Jingle: \(card.name)", "Speech safety: \(safety.rawValue)"]
        if result.analysis.warnings.isEmpty {
            lines.append("No warnings.")
        } else {
            lines.append("Warnings:")
            lines.append(contentsOf: result.analysis.warnings.map {
                "  - [\($0.severity.rawValue)] \($0.code.rawValue): \($0.message)"
            })
        }
        statusMessage = "Validated jingle \(card.name)."
        return lines.joined(separator: "\n")
    }

    // MARK: - Paragraph helpers

    func scriptParagraphIndex(for id: UUID) -> Int? {
        paragraphs.firstIndex(where: { $0.id == id })
    }

    /// Append a paragraph and return its identifier, so a script can address it immediately.
    func scriptAddParagraph(text: String?, voiceID: String?) -> UUID {
        addParagraph()
        guard let index = paragraphs.indices.last else { return UUID() }
        if let text {
            paragraphs[index].text = text
        }
        if let voiceID, voiceOptions.contains(where: { $0.id == voiceID }) {
            paragraphs[index].voiceID = voiceID
        }
        return paragraphs[index].id
    }

    func scriptMoveParagraph(id: UUID, toIndex destination: Int) throws {
        guard let source = scriptParagraphIndex(for: id) else {
            throw ScriptingError.paragraphNotFound
        }
        let clamped = max(0, min(destination, paragraphs.count - 1))
        guard clamped != source else { return }

        let moved = paragraphs.remove(at: source)
        paragraphs.insert(moved, at: clamped)
        normalizeJingleTimelineItems()
        statusMessage = "Moved paragraph to position \(clamped + 1)."
    }

    // MARK: - Video timeline

    /// Attach and load a video without an open panel. Throws when the path is
    /// missing or the file has no readable video track.
    @discardableResult
    func scriptAttachVideo(path: String) async throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            throw NSError(
                domain: "ProjectViewModel",
                code: -40,
                userInfo: [NSLocalizedDescriptionKey: "attach video requires a file path."]
            )
        }
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw NSError(
                domain: "ProjectViewModel",
                code: -41,
                userInfo: [NSLocalizedDescriptionKey: "No video file at '\(expanded)'."]
            )
        }

        let url = URL(fileURLWithPath: expanded)
        guard await attachVideoFile(at: url) else {
            throw NSError(
                domain: "ProjectViewModel",
                code: -42,
                userInfo: [
                    NSLocalizedDescriptionKey: videoController.loadError
                        ?? "The video could not be loaded."
                ]
            )
        }
        return url.path
    }

    /// Detach the current video; returns the path that was attached, if any.
    @discardableResult
    func scriptDetachVideo() -> String? {
        let previous = videoPath
        detachVideo()
        return previous
    }
}

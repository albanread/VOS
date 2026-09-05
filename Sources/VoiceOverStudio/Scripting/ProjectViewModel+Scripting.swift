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
        } else if voiceID == nil {
            paragraphs[index].voiceID = defaultVoiceIDForNewClips()
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

    // MARK: - Slideshow

    private func slideshowUnavailable(_ code: Int, _ message: String) -> Error {
        NSError(
            domain: "ProjectViewModel",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    @discardableResult
    func scriptImportSlideshow(pdfPath: String) async throws -> String {
        let expanded = (pdfPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw slideshowUnavailable(-51, "No PDF file at '\(expanded)'.")
        }
        return try await importSlideshow(pdfURL: URL(fileURLWithPath: expanded))
    }

    /// The agent's eyes: one text file + one viewport PNG per segment plus a
    /// manifest.json describing segments, skips and current narrations.
    /// Returns the manifest path.
    @discardableResult
    func scriptDumpSlideshow(to directory: URL) async throws -> String {
        guard isSlideshowClip, let clipID = currentClipID, let store = projectStore,
              let pdfPath = slideshowPDFPath
        else {
            throw slideshowUnavailable(-52, "The active clip is not a slideshow. Use 'import slideshow' first.")
        }
        let segments = store.loadSlideshowSegments(clipID: clipID)
        guard !segments.isEmpty else {
            throw slideshowUnavailable(-53, "The slideshow has no segments.")
        }

        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)

        // Rendering the PNGs is the slow part; keep the event suspended for it.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try PDFSlideshowService.dumpSegmentAssets(
                        segments: segments,
                        pdfURL: URL(fileURLWithPath: pdfPath),
                        into: directory
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        struct SegmentManifest: Codable {
            let number: Int
            let page: Int
            let skipped: Bool
            let scrollsIn: Bool
            let crop: [Double]
            let textFile: String
            let imageFile: String
            let narration: String
            let hasAudio: Bool
            let narrationStart: Double?
            let estimatedSpan: Double
        }
        struct Manifest: Codable {
            let pdf: String
            let movie: String
            let segments: [SegmentManifest]
        }

        var entries: [SegmentManifest] = []
        for segment in segments {
            let paragraph = paragraphs.first { $0.segmentNumber == segment.number }
            let stem = String(format: "seg-%03d", segment.number)
            let voiceLength = paragraph.map { audioDuration(forParagraphID: $0.id) } ?? 0
            let pan = segment.scrollsIn ? PDFSlideshowService.panSeconds : 0
            let span = max(
                pan + PDFSlideshowService.leadSeconds + voiceLength + PDFSlideshowService.tailSeconds,
                PDFSlideshowService.minimumDwellSeconds
            )
            entries.append(SegmentManifest(
                number: segment.number,
                page: segment.page,
                skipped: segment.skipped,
                scrollsIn: segment.scrollsIn,
                crop: [segment.crop.minX, segment.crop.minY, segment.crop.width, segment.crop.height],
                textFile: "\(stem).txt",
                imageFile: "\(stem).png",
                narration: paragraph?.text ?? "",
                hasAudio: paragraph?.audioPath != nil,
                narrationStart: segment.skipped ? nil : paragraph?.startTime,
                estimatedSpan: segment.skipped ? 0 : span
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Manifest(pdf: pdfPath, movie: videoPath ?? "", segments: entries))
        try data.write(to: manifestURL, options: .atomic)
        statusMessage = "Slideshow dumped: \(segments.count) segments → \(directory.path)"
        return manifestURL.path
    }

    /// Write a segment's narration summary (the agent's words, not the page's).
    func scriptNarrateSegment(number: Int, text: String) async throws {
        guard isSlideshowClip else {
            throw slideshowUnavailable(-52, "The active clip is not a slideshow. Use 'import slideshow' first.")
        }
        guard let index = paragraphs.firstIndex(where: { $0.segmentNumber == number }) else {
            throw slideshowUnavailable(-54, "No segment \(number). Use 'slideshow info' to see the range.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        paragraphs[index].text = trimmed
        paragraphs[index].isRecorded = false
        // Estimates changed: refresh anchor math; the movie re-bakes when the
        // voices are generated.
        await refreshSlideshow(rebake: false)
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        statusMessage = "Segment \(number) narration set (\(words) words)."
    }

    /// Mark a content-free segment to be dropped from the baked movie (its
    /// narration stub survives, unanchored, for the transcript).
    func scriptSkipSegment(number: Int, skipped: Bool) async throws {
        guard isSlideshowClip, let clipID = currentClipID, let store = projectStore else {
            throw slideshowUnavailable(-52, "The active clip is not a slideshow. Use 'import slideshow' first.")
        }
        guard store.setSlideshowSegmentSkipped(clipID: clipID, number: number, skipped: skipped) else {
            throw slideshowUnavailable(-54, "No segment \(number). Use 'slideshow info' to see the range.")
        }
        await refreshSlideshow(rebake: true)
        statusMessage = skipped
            ? "Segment \(number) skipped — it will not appear in the baked movie."
            : "Segment \(number) restored to the slideshow."
    }

    /// Recompute spans from the current voices and rewrite the stills movie.
    @discardableResult
    func scriptBakeSlideshow() async throws -> String {
        guard isSlideshowClip else {
            throw slideshowUnavailable(-52, "The active clip is not a slideshow. Use 'import slideshow' first.")
        }
        await refreshSlideshow(rebake: true)
        return statusMessage
    }

    /// Re-split the PDF with the current splitter (whitespace breaks, padded
    /// crops), keeping narrations, voices and skips. Waits for the re-bake.
    @discardableResult
    func scriptReSplitSlideshow() async throws -> String {
        try await reSplitSlideshow()
    }

    /// Readable summary for scripts: paths, segment range, narration state.
    func slideshowInfoText() -> String {
        guard isSlideshowClip, let clipID = currentClipID, let store = projectStore else {
            return "The active clip is not a slideshow."
        }
        let segments = store.loadSlideshowSegments(clipID: clipID)
        guard !segments.isEmpty else { return "The slideshow has no segments." }
        let skipped = segments.filter(\.skipped).count
        let written = segments.filter { segment in
            guard let paragraph = paragraphs.first(where: { $0.segmentNumber == segment.number })
            else { return false }
            return !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let voiced = segments.filter { segment in
            paragraphs.first(where: { $0.segmentNumber == segment.number })?.audioPath != nil
        }.count
        return [
            "PDF: \(slideshowPDFPath ?? "?")",
            "Movie: \(videoPath ?? "?")",
            "Segments: \(segments.count) across pages \(segments.first?.page ?? 0)–\(segments.last?.page ?? 0)",
            "Narration: \(written) written, \(voiced) voiced, \(skipped) skipped."
        ].joined(separator: "\n")
    }
}

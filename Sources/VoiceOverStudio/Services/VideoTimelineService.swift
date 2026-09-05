//
//  VideoTimelineService.swift
//  VoiceOverStudio
//

import AVFoundation
import AppKit
import Combine
import Foundation

enum VideoTimelineError: LocalizedError {
    case noVideoTrack
    case trackCreationFailed
    case exportSessionCreationFailed
    case noUsableVoiceClips
    case voiceTrackRenderFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "The selected file has no playable video track."
        case .trackCreationFailed:
            return "Could not create a composition track for the video."
        case .exportSessionCreationFailed:
            return "Could not create an export session for the video."
        case .noUsableVoiceClips:
            return "No readable voice audio was found for the voice track."
        case .voiceTrackRenderFailed:
            return "Offline rendering of the voice track failed."
        }
    }
}

enum VideoTimelineService {
    struct Clip {
        let audioURL: URL
        let startSeconds: Double
    }

    static func isMovieURL(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// A voice-only timeline: entries stacked sequentially with their gaps —
    /// the same model a video clip uses, just without the video. Entries
    /// without audio occupy their estimated length as silence, so the visual
    /// track and the playable timeline are one and the same.
    static func makeVoiceOnlyComposition(
        entries: [(audioURL: URL?, length: Double, gapAfter: Double)]
    ) async -> (composition: AVMutableComposition, duration: Double)? {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }

        var cursor = CMTime.zero
        for entry in entries {
            let length = max(0.25, entry.length)
            if let url = entry.audioURL {
                let asset = AVURLAsset(url: url)
                if let sourceTracks = try? await asset.loadTracks(withMediaType: .audio),
                   let sourceTrack = sourceTracks.first,
                   let assetDuration = try? await asset.load(.duration) {
                    let usable = min(length, assetDuration.seconds)
                    if usable > 0 {
                        try? track.insertTimeRange(
                            CMTimeRange(start: .zero, duration: CMTime(seconds: usable, preferredTimescale: 600)),
                            of: sourceTrack,
                            at: cursor
                        )
                    }
                }
            }
            cursor = CMTimeAdd(cursor, CMTime(seconds: length + max(0, entry.gapAfter), preferredTimescale: 600))
        }
        return (composition, cursor.seconds)
    }

    /// Builds a composition that plays the source video with its original audio
    /// (scaled by `originalAudioVolume`) plus one audio track per voice-over
    /// clip, placed at its anchor time. One track per clip sidesteps
    /// AVMutableComposition's insert-shift behavior for overlapping inserts.
    static func makeComposition(
        videoAsset: AVURLAsset,
        clips: [Clip],
        originalAudioVolume: Float
    ) async throws -> (composition: AVMutableComposition, audioMix: AVMutableAudioMix?) {
        let composition = AVMutableComposition()
        let duration = try await videoAsset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        let sourceVideoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = sourceVideoTracks.first else {
            throw VideoTimelineError.noVideoTrack
        }
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoTimelineError.trackCreationFailed
        }
        try compositionVideoTrack.insertTimeRange(fullRange, of: sourceVideoTrack, at: .zero)

        var audioMix: AVMutableAudioMix?
        if let sourceAudioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compositionAudioTrack.insertTimeRange(fullRange, of: sourceAudioTrack, at: .zero)
            if abs(originalAudioVolume - 1.0) > 0.001 {
                // This SDK only exposes the parameterless initializer in Swift,
                // so associate the track by assigning trackID afterwards.
                let parameters = AVMutableAudioMixInputParameters()
                parameters.trackID = compositionAudioTrack.trackID
                parameters.setVolume(originalAudioVolume, at: CMTime.zero)
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                audioMix = mix
            }
        }

        for clip in clips.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let clipStart = max(0, min(clip.startSeconds, duration.seconds))
            let clipAsset = AVURLAsset(url: clip.audioURL)
            guard let sourceAudioTrack = try await clipAsset.loadTracks(withMediaType: .audio).first else {
                continue
            }
            let clipDuration = try await clipAsset.load(.duration)
            // Truncate clips that would run past the end of the video.
            let available = max(0, duration.seconds - clipStart)
            let insertedDuration = CMTime(seconds: min(clipDuration.seconds, available), preferredTimescale: 600)
            guard insertedDuration.seconds > 0 else { continue }
            guard let voiceOverTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            try voiceOverTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertedDuration),
                of: sourceAudioTrack,
                at: CMTime(seconds: clipStart, preferredTimescale: 600)
            )
        }

        return (composition, audioMix)
    }

    /// Fast, faithful export: the source video's encoded bitstream is copied
    /// untouched (so anything that plays the recording plays the export), and
    /// the fully mixed narration — voices plus original audio at the mix
    /// volume — rides along as one AAC track. Falls back to re-encoding only
    /// if the copy path fails.
    static func remuxExport(
        videoAsset: AVURLAsset,
        clips: [Clip],
        originalAudioVolume: Float,
        to outputURL: URL
    ) async throws {
        let duration = try await videoAsset.load(.duration)
        let mixURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vos-mix-\(UUID().uuidString).wav", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: mixURL) }

        try await renderVoiceTrack(
            clips: clips,
            totalDuration: duration.seconds,
            to: mixURL,
            mixingOriginalAudioFrom: videoAsset,
            originalAudioVolume: originalAudioVolume
        )

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw VideoTimelineError.noVideoTrack
        }
        let mixAsset = AVURLAsset(url: mixURL)
        guard let mixTrack = try await mixAsset.loadTracks(withMediaType: .audio).first else {
            throw VideoTimelineError.noUsableVoiceClips
        }

        let reader = try AVAssetReader(asset: videoAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let audioReader = try AVAssetReader(asset: mixAsset)
        let audioOutput = AVAssetReaderTrackOutput(track: mixTrack, outputSettings: nil)
        audioOutput.alwaysCopiesSampleData = false
        audioReader.add(audioOutput)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 160_000,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48_000,
        ])
        writer.metadata = try await videoAsset.load(.metadata)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        writer.add(videoInput)
        writer.add(audioInput)

        guard reader.startReading(), audioReader.startReading() else {
            throw VideoTimelineError.voiceTrackRenderFailed
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "vos.remux.video")) {
                while videoInput.isReadyForMoreMediaData {
                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    videoInput.append(sample)
                }
            }
            group.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "vos.remux.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioInput.append(sample)
                }
            }
            group.notify(queue: DispatchQueue.global()) {
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? VideoTimelineError.voiceTrackRenderFailed
        }
    }

    /// Exports the mixed composition as .mov. HighestQuality re-encodes, which
    /// keeps the mixed audio in sync on variable-frame-rate screen captures.
    static func export(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix?,
        to outputURL: URL
    ) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoTimelineError.exportSessionCreationFailed
        }
        exportSession.audioMix = audioMix
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: outputURL)
        try await exportSession.export(to: outputURL, as: .mov)
    }

    /// Renders a voice-track-only WAV spanning the full video duration: each
    /// clip mixed in at its anchor time, true silence everywhere else, at
    /// 48 kHz mono so it drops straight into a video editor. The video itself
    /// is only the timing reference; nothing from it is included.
    static func renderVoiceTrack(
        clips: [Clip],
        totalDuration seconds: Double,
        to outputURL: URL,
        mixingOriginalAudioFrom originalAsset: AVURLAsset? = nil,
        originalAudioVolume: Float = 0
    ) async throws {
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)

        var players: [AVAudioPlayerNode] = []
        for clip in clips {
            guard let file = try? AVAudioFile(forReading: clip.audioURL) else { continue }
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
            else { continue }
            try file.read(into: buffer)

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            // The player node's timeline runs at its output format's rate (the
            // file's rate), not the render format's rate, so offsets must be
            // expressed in file frames — verified against RMS-window tests.
            let nodeRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition((clip.startSeconds * nodeRate).rounded())
            player.scheduleBuffer(
                buffer,
                at: AVAudioTime(sampleTime: startFrame, atRate: nodeRate),
                options: [],
                completionHandler: nil
            )
            players.append(player)
        }
        guard !players.isEmpty else {
            throw VideoTimelineError.noUsableVoiceClips
        }

        try? FileManager.default.removeItem(at: outputURL)
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: renderFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Original video audio, scaled to the mix volume, joins the render as
        // one more source — the result is a single track holding everything.
        if let originalAsset, originalAudioVolume > 0.001,
           let file = try? AVAudioFile(forReading: originalAsset.url) {
            let frames = AVAudioFrameCount(file.length)
            if frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) {
                try file.read(into: buffer)
                let player = AVAudioPlayerNode()
                player.volume = originalAudioVolume
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
                player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: 0, atRate: file.processingFormat.sampleRate), options: [], completionHandler: nil)
                players.append(player)
            }
        }

        try engine.start()
        players.forEach { $0.play() }

        let totalFrames = AVAudioFramePosition((max(seconds, 0.1) * renderFormat.sampleRate).rounded(.up))
        let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        )!

        // Once every scheduled buffer has sounded the mixer renders silence,
        // which pads the track out to the video's full length. The stall guard
        // mirrors AudioPostProcessor: renderOffline does not advance sample
        // time when it cannot produce audio, so a non-advancing loop must end.
        let maximumStalledRenders = 8
        var stalledRenders = 0

        renderLoop: while engine.manualRenderingSampleTime < totalFrames {
            let sampleTimeBeforeRender = engine.manualRenderingSampleTime
            let status = try engine.renderOffline(engine.manualRenderingMaximumFrameCount, to: renderBuffer)
            switch status {
            case .success:
                if renderBuffer.frameLength > 0 {
                    try outputFile.write(from: renderBuffer)
                }
            case .insufficientDataFromInputNode:
                if renderBuffer.frameLength > 0 {
                    try outputFile.write(from: renderBuffer)
                }
            case .cannotDoInCurrentContext:
                break
            case .error:
                throw VideoTimelineError.voiceTrackRenderFailed
            @unknown default:
                break renderLoop
            }

            if engine.manualRenderingSampleTime > sampleTimeBeforeRender {
                stalledRenders = 0
            } else {
                stalledRenders += 1
                if stalledRenders >= maximumStalledRenders {
                    break renderLoop
                }
            }
        }

        engine.stop()
        players.forEach { $0.stop() }
    }
}

/// Generates and caches small frames for the filmstrip. Instances are used
/// from the main actor only.
final class VideoThumbnailProvider {
    private let cache = NSCache<NSString, NSImage>()
    private var generator: AVAssetImageGenerator?

    func configure(asset: AVAsset) {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.maximumSize = NSSize(width: 240, height: 160)
        imageGenerator.appliesPreferredTrackTransform = true
        // Filmstrip frames don't need frame accuracy; a loose tolerance makes
        // generation much cheaper on long screen captures.
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator = imageGenerator
        cache.removeAllObjects()
    }

    func thumbnail(at seconds: Double) async -> NSImage? {
        let key = "\(Int(seconds * 10))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let generator else { return nil }
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
final class VideoTimelineController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var duration: Double = 0
    @Published private(set) var playbackTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private(set) var videoURL: URL?
    private let thumbnails = VideoThumbnailProvider()
    private var timeObserverToken: Any?
    private var seekTask: Task<Void, Never>?
    /// True while the preview player item is being swapped: the new item
    /// reports time zero before the resume seek lands, and publishing that
    /// blip would snap the red bar and the scroll view back to the start.
    private var isReplacingPreviewItem = false

    private(set) var voiceOnly = false

    var isLoaded: Bool {
        (videoURL != nil || voiceOnly) && duration > 0 && loadError == nil
    }

    init() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, !self.isReplacingPreviewItem else { return }
                self.playbackTime = max(0, seconds)
            }
        }
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                let playing = status == .playing
                Task { @MainActor in
                    self?.isPlaying = playing
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    func load(url: URL) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        let asset = AVURLAsset(url: url)
        do {
            let loadedDuration = try await asset.load(.duration).seconds
            guard loadedDuration.isFinite, loadedDuration > 0 else {
                throw NSError(
                    domain: "VideoTimelineController",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "The video reports no usable duration."]
                )
            }
            videoURL = url
            voiceOnly = false
            duration = loadedDuration
            playbackTime = 0
            thumbnails.configure(asset: asset)
        } catch {
            videoURL = nil
            duration = 0
            loadError = "Could not read video: \(error.localizedDescription)"
        }
    }

    func unload() {
        player.replaceCurrentItem(with: nil)
        videoURL = nil
        voiceOnly = false
        duration = 0
        playbackTime = 0
        loadError = nil
    }

    /// Present a voice-only (podcast-style) timeline: an audio composition
    /// standing in for the video.
    func presentVoiceOnly(item: AVPlayerItem, duration total: Double) {
        let resume = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        player.replaceCurrentItem(with: item)
        voiceOnly = true
        videoURL = nil
        duration = max(0, total)
        loadError = nil
        player.seek(to: min(resume, CMTime(seconds: duration, preferredTimescale: 600)))
        if wasPlaying {
            player.play()
        }
    }

    /// Rebuilds the player item so preview playback matches what export will
    /// produce, resuming at the current playhead.
    func rebuildPreview(
        clips: [VideoTimelineService.Clip],
        originalAudioVolume: Float
    ) async {
        guard let url = videoURL, duration > 0 else {
            player.replaceCurrentItem(with: nil)
            return
        }
        do {
            let (composition, audioMix) = try await VideoTimelineService.makeComposition(
                videoAsset: AVURLAsset(url: url),
                clips: clips,
                originalAudioVolume: originalAudioVolume
            )
            let item = AVPlayerItem(asset: composition)
            item.audioMix = audioMix
            // Remember, rebuild, restore. The saved playhead is forced back
            // afterwards no matter what the fresh item reported — seeks on a
            // just-replaced item can silently fail and leave the player at
            // zero, and any such report is suppressed until the restore has
            // had time to land.
            let savedPlayhead = max(0, min(playbackTime, duration))
            let resumeTime = CMTime(seconds: savedPlayhead, preferredTimescale: 600)
            let wasPlaying = player.timeControlStatus == .playing
            isReplacingPreviewItem = true
            player.replaceCurrentItem(with: item)
            await player.seek(
                to: resumeTime,
                toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)
            )
            // Hard restore: our value wins over whatever the player did.
            playbackTime = savedPlayhead
            seekTask?.cancel()
            seekTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                await self.player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if wasPlaying {
                player.play()
            }
            // Hold the suppression window so residual zero reports from the
            // swap cannot publish and drag the view back to the start.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.isReplacingPreviewItem = false
            }
        } catch {
            loadError = "Preview build failed: \(error.localizedDescription)"
        }
    }

    func playPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func pause() {
        player.pause()
    }

    func rewindToStart() {
        seek(to: 0)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        playbackTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        // Scrubbing fires many seeks; cancel the stale one so they don't queue.
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func thumbnail(at seconds: Double) async -> NSImage? {
        await thumbnails.thumbnail(at: seconds)
    }
}

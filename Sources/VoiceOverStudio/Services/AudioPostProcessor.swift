//
//  AudioPostProcessor.swift
//  VoiceOverStudio
//

import AVFoundation

enum AudioPostProcessor {
    private static let speechAnalysisGate: Float = 0.003
    private static let targetSpeechRMS: Float = 0.12
    private static let peakCeiling: Float = 0.95
    private static let minimumGain: Float = 0.35
    private static let maximumGain: Float = 3.5
    private static let neutralRate: Float = 1.0
    private static let neutralPitchCents: Float = 0.0

    static func normalizeSpeechLevel(fileURL: URL) throws {
        let sourceFile = try AVAudioFile(forReading: fileURL)
        let format = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(
                domain: "AudioPostProcessor",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio buffer for normalization"]
            )
        }

        try sourceFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channelCount > 0, frames > 0 else { return }

        var peak: Float = 0
        var gatedSumSquares: Float = 0
        var gatedSampleCount: Int = 0
        var totalSumSquares: Float = 0
        var totalSampleCount: Int = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frames {
                let sample = samples[frame]
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                totalSumSquares += sample * sample
                totalSampleCount += 1
                if magnitude >= speechAnalysisGate {
                    gatedSumSquares += sample * sample
                    gatedSampleCount += 1
                }
            }
        }

        guard peak > 0.0001, totalSampleCount > 0 else { return }

        let effectiveRMS: Float
        if gatedSampleCount > max(frames / 20, 1) {
            effectiveRMS = sqrt(gatedSumSquares / Float(gatedSampleCount))
        } else {
            effectiveRMS = sqrt(totalSumSquares / Float(totalSampleCount))
        }

        guard effectiveRMS > 0.0001 else { return }

        let targetGain = targetSpeechRMS / effectiveRMS
        let peakLimitedGain = peakCeiling / peak
        let appliedGain = min(max(targetGain, minimumGain), maximumGain, peakLimitedGain)

        guard abs(appliedGain - 1.0) > 0.02 else { return }

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frames {
                let scaled = samples[frame] * appliedGain
                samples[frame] = max(-0.98, min(0.98, scaled))
            }
        }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".wav")

        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: sourceFile.fileFormat.settings
        )
        try outputFile.write(from: buffer)

        let fileManager = FileManager.default
        try fileManager.removeItem(at: fileURL)
        try fileManager.moveItem(at: tempURL, to: fileURL)
    }

    /// Apply tempo and pitch changes in place using AVAudioUnitTimePitch offline rendering.
    /// `rate`: 1.0 keeps the original duration, below 1.0 slows down, above 1.0 speeds up.
    /// `semitones`: negative = deeper, positive = brighter. Typical range: -4 … +4.
    static func applyTempoAndPitch(rate: Float = 1.0, semitones: Float = 0.0, fileURL: URL) throws {
        let clampedRate = max(0.25, min(rate, 4.0))
        let pitchCents = semitones * 100
        guard abs(clampedRate - neutralRate) > 0.001 || abs(pitchCents - neutralPitchCents) > 0.5 else { return }

        let sourceFile = try AVAudioFile(forReading: fileURL)
        let format = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard frameCount > 0 else { return }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = clampedRate
        timePitch.pitch = pitchCents

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        try sourceFile.read(into: inputBuffer)
        playerNode.scheduleBuffer(inputBuffer, at: nil, options: [])
        playerNode.play()

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".wav")

        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: sourceFile.fileFormat.settings
        )

        let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                             frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let estimatedOutputFrames = AVAudioFramePosition((Double(frameCount) / Double(clampedRate)).rounded(.up))
        // Render a little past the estimate so the time/pitch unit's tail is captured.
        let renderTargetFrames = max(estimatedOutputFrames, 1) + AVAudioFramePosition(engine.manualRenderingMaximumFrameCount * 8)

        // renderOffline does not advance manualRenderingSampleTime when it cannot
        // produce audio, so a status that leaves the loop condition unchanged would
        // otherwise spin forever. Bail out once rendering stops making progress.
        let maximumStalledRenders = 8
        var stalledRenders = 0

        renderLoop: while engine.manualRenderingSampleTime < renderTargetFrames {
            let sampleTimeBeforeRender = engine.manualRenderingSampleTime
            let status = try engine.renderOffline(engine.manualRenderingMaximumFrameCount,
                                                   to: renderBuffer)
            switch status {
            case .success:
                if renderBuffer.frameLength > 0 {
                    try outputFile.write(from: renderBuffer)
                }
            case .insufficientDataFromInputNode:
                // The whole source buffer is scheduled before rendering starts, so this
                // means the input is drained. Keep whatever partial frames this call
                // produced, then stop: further renders cannot add anything.
                if renderBuffer.frameLength > 0 {
                    try outputFile.write(from: renderBuffer)
                }
                break renderLoop
            case .cannotDoInCurrentContext:
                // Transient; retry on the next iteration. Falls through to the stall
                // guard below, which bounds how many times that can happen.
                break
            case .error:
                throw NSError(domain: "AudioPostProcessor", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Offline render failed"])
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
        playerNode.stop()

        let fm = FileManager.default
        try fm.removeItem(at: fileURL)
        try fm.moveItem(at: tempURL, to: fileURL)
    }
}

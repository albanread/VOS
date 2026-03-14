//
//  AudioPostProcessor.swift
//  VoiceOverStudio
//

import AVFoundation

enum AudioPostProcessor {

    /// Pitch-shift a WAV file in place using AVAudioEngine + AVAudioUnitTimePitch.
    /// `semitones`: negative = deeper, positive = brighter. Typical range: -4 … +4.
    static func applyPitch(semitones: Float, fileURL: URL) throws {
        guard semitones != 0 else { return }

        let sourceFile = try AVAudioFile(forReading: fileURL)
        let format = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard frameCount > 0 else { return }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.pitch = semitones * 100 // AVAudioUnitTimePitch uses cents (100 cents = 1 semitone)

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        playerNode.play()

        let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        try sourceFile.read(into: inputBuffer)
        playerNode.scheduleBuffer(inputBuffer, completionHandler: nil)

        // Render into a temp file
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".wav")

        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: sourceFile.fileFormat.settings
        )

        let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                             frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while engine.manualRenderingSampleTime < Int64(frameCount) {
            let status = try engine.renderOffline(engine.manualRenderingMaximumFrameCount,
                                                   to: renderBuffer)
            switch status {
            case .success:
                try outputFile.write(from: renderBuffer)
            case .insufficientDataFromInputNode:
                break
            case .cannotDoInCurrentContext, .error:
                throw NSError(domain: "AudioPostProcessor", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Offline render failed"])
            @unknown default:
                break
            }
        }

        engine.stop()
        playerNode.stop()

        // Replace original file with processed version
        let fm = FileManager.default
        try fm.removeItem(at: fileURL)
        try fm.moveItem(at: tempURL, to: fileURL)
    }
}

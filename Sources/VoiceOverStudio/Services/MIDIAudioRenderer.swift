import AVFoundation
import AudioToolbox
import Foundation

enum MIDIAudioRenderer {
    static func defaultSoundBankURL() -> URL? {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls",
            "/System/Library/Components/DLSMusicDevice.component/Contents/Resources/gs_instruments.dls"
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func render(
        midiData: Data,
        midiTracks: [ABCMIDITrack],
        outputURL: URL,
        soundBankURL: URL? = defaultSoundBankURL(),
        sampleRate: Double = 44_100
    ) throws {
        guard let soundBankURL else {
            throw NSError(domain: "MIDIAudioRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No system MIDI soundbank was found."])
        }

        let directoryURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let tempMIDIURL = directoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("mid")
        try midiData.write(to: tempMIDIURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempMIDIURL) }

        let engine = AVAudioEngine()
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let noteTracks = midiTracks
            .filter { $0.type == .notes }
            .sorted { $0.trackNumber < $1.trackNumber }

        let samplers: [AVAudioUnitSampler] = try noteTracks.map { track in
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: renderFormat)

            let program = UInt8(clamping: track.events.first(where: { $0.type == .programChange })?.data1 ?? 0)
            let bankMSB: UInt8 = track.channel == 9 ? UInt8(kAUSampler_DefaultPercussionBankMSB) : UInt8(kAUSampler_DefaultMelodicBankMSB)
            try sampler.loadSoundBankInstrument(
                at: soundBankURL,
                program: program,
                bankMSB: bankMSB,
                bankLSB: UInt8(kAUSampler_DefaultBankLSB)
            )
            return sampler
        }

        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: tempMIDIURL, options: [])

        let sequencerTracks = sequencer.tracks
        for (index, sampler) in samplers.enumerated() where index + 1 < sequencerTracks.count {
            sequencerTracks[index + 1].destinationAudioUnit = sampler
        }

        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
        try engine.start()

        sequencer.prepareToPlay()
        try sequencer.start()

        let durationSeconds = max(0.1, sequencerTracks.map(\ .lengthInSeconds).max() ?? 0.1) + 0.25
        let totalFrames = AVAudioFramePosition(ceil(durationSeconds * renderFormat.sampleRate))

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: renderFormat.settings,
            commonFormat: renderFormat.commonFormat,
            interleaved: renderFormat.isInterleaved
        )

        let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        )!

        while engine.manualRenderingSampleTime < totalFrames {
            let remainingFrames = totalFrames - engine.manualRenderingSampleTime
            let frameCount = AVAudioFrameCount(min(Int64(engine.manualRenderingMaximumFrameCount), remainingFrames))
            let status = try engine.renderOffline(frameCount, to: renderBuffer)
            switch status {
            case .success:
                if renderBuffer.frameLength > 0 {
                    try outputFile.write(from: renderBuffer)
                }
            case .insufficientDataFromInputNode:
                break
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw NSError(domain: "MIDIAudioRenderer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Offline MIDI render failed."])
            @unknown default:
                break
            }
        }

        sequencer.stop()
        engine.stop()
    }
}
import AVFoundation
import Foundation
import MLXAudioCore

@MainActor
final class ReferenceVoiceRecorder: NSObject {
    private var recorder: AVAudioRecorder?

    struct RecordingSummary {
        let durationSeconds: Double
        let trimmedSilence: Bool
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func startRecording(to url: URL) async throws {
        let granted = await Self.requestMicrophoneAccessIfNeeded()
        guard granted else {
            throw RecorderError.microphonePermissionDenied
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw RecorderError.failedToStartRecording
        }
        self.recorder = recorder
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
    }

    func finalizeRecording(at url: URL, targetSampleRate: Int) throws -> RecordingSummary {
        let resolvedSampleRate = max(16_000, targetSampleRate)
        let (_, audio) = try loadAudioArray(from: url, sampleRate: resolvedSampleRate)
        let originalSamples = audio.asArray(Float.self)
        let trimmedSamples = Self.trimSilence(from: originalSamples, sampleRate: resolvedSampleRate)
        guard !trimmedSamples.isEmpty else {
            throw RecorderError.recordingTooQuiet
        }

        let minimumFrames = max(resolvedSampleRate * 2, 16_000)
        guard trimmedSamples.count >= minimumFrames else {
            throw RecorderError.recordingTooShort
        }

        let normalizedSamples = Self.normalize(trimmedSamples)
        try AudioUtils.writeWavFile(
            samples: normalizedSamples,
            sampleRate: Double(resolvedSampleRate),
            fileURL: url
        )

        return RecordingSummary(
            durationSeconds: Double(normalizedSamples.count) / Double(resolvedSampleRate),
            trimmedSilence: trimmedSamples.count != originalSamples.count
        )
    }

    private static func trimSilence(from samples: [Float], sampleRate: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let threshold: Float = 0.003
        let padding = max(sampleRate / 10, 1)

        guard let firstIndex = samples.firstIndex(where: { abs($0) >= threshold }),
              let lastIndex = samples.lastIndex(where: { abs($0) >= threshold }) else {
            return []
        }

        let start = max(0, firstIndex - padding)
        let end = min(samples.count - 1, lastIndex + padding)
        return Array(samples[start ... end])
    }

    private static func normalize(_ samples: [Float]) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else {
            return samples
        }

        let scale = min(0.95 / peak, 1.5)
        return samples.map { $0 * scale }
    }

    private static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    enum RecorderError: LocalizedError {
        case microphonePermissionDenied
        case failedToStartRecording
        case recordingTooShort
        case recordingTooQuiet

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access was denied. Enable microphone access for the app or host process in System Settings."
            case .failedToStartRecording:
                return "Failed to start microphone recording."
            case .recordingTooShort:
                return "Reference recording is too short. Please record at least a few seconds of natural speech."
            case .recordingTooQuiet:
                return "Reference recording was too quiet or mostly silence. Please try again closer to the microphone."
            }
        }
    }
}
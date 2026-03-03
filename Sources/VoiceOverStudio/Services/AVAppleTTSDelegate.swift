import Foundation
import AVFoundation

/// Owns the AVSpeechSynthesizer for the duration of a single write() call
/// and resumes the Swift continuation exactly once when done. Must run on the
/// main actor because AVSpeechSynthesizer expects main-thread access.
@MainActor
final class AppleSynthWriter: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Bool, Never>?
    private let onFinish: (() -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
        super.init()
        synth.delegate = self
    }

    func write(
        text: String,
        to url: URL,
        voice: AVSpeechSynthesisVoice,
        rate: Float,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.continuation = continuation

        // Failsafe: if write() never produces the sentinel buffer, force-complete.
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            await MainActor.run { [weak self] in
                guard let self, self.continuation != nil else { return }
                debugLog("[TTS][Apple] timeout reached; stopping synth and finishing")
                self.synth.stopSpeaking(at: .immediate)
                self.finish(success: self.file != nil)
            }
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate  = rate

        // AVSpeechSynthesizer.write() must be invoked on the main thread.
        precondition(Thread.isMainThread, "AVSpeechSynthesizer.write must run on main thread")

        debugLog("[TTS][Apple] write begin on main thread, text count=\(text.count) url=\(url.path) voice=\(voice.identifier) rate=\(rate)")

        synth.write(utterance) { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let pcm = buffer as? AVAudioPCMBuffer {
                    debugLog("[TTS][Apple] buffer pcm frames=\(pcm.frameLength) format=\(pcm.format) fileExists=\(self.file != nil)")
                } else {
                    debugLog("[TTS][Apple] buffer non-PCM (sentinel) fileExists=\(self.file != nil)")
                }

                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    // Real audio data — write it to file.
                    if self.file == nil {
                        do {
                            self.file = try AVAudioFile(forWriting: url,
                                                        settings: pcm.format.settings)
                        } catch {
                            debugLog("[TTS][Apple] AVAudioFile create error: \(error)")
                            self.finish(success: false)
                            return
                        }
                    }
                    do {
                        try self.file?.write(from: pcm)
                    } catch {
                        debugLog("[TTS][Apple] AVAudioFile write error: \(error)")
                    }
                } else {
                    // End-of-stream sentinel (zero-frame PCM or non-PCM buffer).
                    self.finish(success: self.file != nil)
                }
            }
        }
    }

    private func finish(success: Bool) {
        guard let c = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        onFinish?()
        debugLog("[TTS][Apple] finish success=\(success)")
        c.resume(returning: success)
    }

    // Delegate callbacks are rarely fired for write(), but helpful for logging
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Delegate is nonisolated by protocol; log without touching UI state.
        debugLog("[TTS][Apple] delegate didFinish")
    }

    deinit {
        timeoutTask?.cancel()
    }
}

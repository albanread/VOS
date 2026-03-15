import Foundation

final class ABCVoiceManager {
    private(set) var currentVoice: Int = 1
    private var nextVoiceID: Int = 1
    private var voiceTimes: [Int: Double] = [:]
    private var voiceNameToID: [String: Int] = [:]

    func reset() {
        currentVoice = 1
        nextVoiceID = 1
        voiceTimes.removeAll(keepingCapacity: true)
        voiceNameToID.removeAll(keepingCapacity: true)
    }

    func saveCurrentTime(_ time: Double) {
        guard currentVoice != 0 else { return }
        voiceTimes[currentVoice] = time
    }

    func restoreVoiceTime(_ voiceID: Int) -> Double {
        voiceTimes[voiceID] ?? 0
    }

    func initializeVoiceFromDefaults(_ voice: inout ABCVoiceContext, tune: ABCTune) {
        voice.key = tune.defaultKey
        voice.timeSig = tune.defaultTimeSig
        voice.unitLen = tune.defaultUnit
        voice.transpose = 0
        voice.octaveShift = 0
        voice.instrument = tune.defaultInstrument
        voice.channel = tune.defaultChannel
        voice.velocity = 80
        voice.percussion = tune.defaultPercussion
    }

    func findVoiceByIdentifier(_ identifier: String, tune: ABCTune) -> Int {
        if let numericID = Int(identifier), tune.voices[numericID] != nil {
            return numericID
        }

        for (id, voice) in tune.voices where voice.name == identifier {
            return id
        }

        return voiceNameToID[identifier] ?? 0
    }

    func getOrCreateVoice(_ identifier: String, tune: inout ABCTune) -> Int {
        let existingID = findVoiceByIdentifier(identifier, tune: tune)
        if existingID != 0 {
            return existingID
        }

        let voiceID = nextVoiceID
        nextVoiceID += 1

        var voice = ABCVoiceContext(
            id: voiceID,
            name: identifier,
            key: tune.defaultKey,
            timeSig: tune.defaultTimeSig,
            unitLen: tune.defaultUnit,
            transpose: 0,
            octaveShift: 0,
            instrument: tune.defaultInstrument,
            channel: -1,
            velocity: 80,
            percussion: tune.defaultPercussion
        )
        initializeVoiceFromDefaults(&voice, tune: tune)
        tune.voices[voiceID] = voice
        voiceNameToID[identifier] = voiceID
        return voiceID
    }

    func switchToVoice(_ identifier: String, tune: inout ABCTune) -> Int {
        var voiceID = findVoiceByIdentifier(identifier, tune: tune)
        if voiceID == 0 {
            voiceID = getOrCreateVoice(identifier, tune: &tune)
        }
        currentVoice = voiceID
        return voiceID
    }

    func registerExternalVoice(_ voiceID: Int, identifier: String) {
        voiceNameToID[identifier] = voiceID
        if voiceID >= nextVoiceID {
            nextVoiceID = voiceID + 1
        }
    }
}
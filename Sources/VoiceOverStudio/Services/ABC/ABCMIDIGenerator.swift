import Foundation

enum ABCMIDITrackType: Equatable {
    case notes
    case tempo
}

enum ABCMIDIEventType: Equatable {
    case noteOn
    case noteOff
    case programChange
    case controlChange
    case metaTempo
    case metaTimeSignature
    case metaKeySignature
    case metaText
    case metaEndOfTrack
}

struct ABCMIDIEvent: Equatable {
    var type: ABCMIDIEventType
    var timestamp: Double
    var channel: Int
    var data1: Int
    var data2: Int
    var metaData: [UInt8] = []
}

struct ABCMIDITrack: Equatable {
    var trackNumber: Int
    var type: ABCMIDITrackType
    var voiceNumber: Int = 0
    var name: String = ""
    var channel: Int = -1
    var events: [ABCMIDIEvent] = []
}

private struct ABCActiveMIDINote {
    var midiNote: Int
    var channel: Int
    var velocity: Int
    var endTime: Double
}

private final class ABCMIDIChannelManager {
    private var channelsInUse = Array(repeating: false, count: 16)
    private var voiceToChannel: [Int: Int] = [:]
    private var nextAvailableChannel = 0

    func reset() {
        channelsInUse = Array(repeating: false, count: 16)
        voiceToChannel.removeAll(keepingCapacity: true)
        nextAvailableChannel = 0
    }

    func assignChannel(voiceID: Int) -> Int {
        if let channel = voiceToChannel[voiceID] {
            return channel
        }

        while nextAvailableChannel < 16 {
            if nextAvailableChannel != 9, !channelsInUse[nextAvailableChannel] {
                let channel = nextAvailableChannel
                channelsInUse[channel] = true
                voiceToChannel[voiceID] = channel
                nextAvailableChannel += 1
                return channel
            }
            nextAvailableChannel += 1
        }

        return 0
    }

    func assignExplicitChannel(voiceID: Int, channel: Int) {
        guard (0..<16).contains(channel) else { return }
        channelsInUse[channel] = true
        voiceToChannel[voiceID] = channel
    }
}

final class ABCMIDIGenerator {
    let ticksPerQuarter: Int = 480
    private let channelManager = ABCMIDIChannelManager()
    private var currentTime: Double = 0
    private var currentTempo: Int = 120
    private var activeNotes: [ABCActiveMIDINote] = []

    func generateMIDI(_ tune: ABCTune) -> [ABCMIDITrack] {
        channelManager.reset()
        currentTime = 0
        currentTempo = tune.defaultTempo.bpm
        activeNotes.removeAll(keepingCapacity: true)

        var tracks = createTracks(tune)
        assignChannels(tune, tracks: &tracks)

        for index in tracks.indices where tracks[index].trackNumber != 0 {
            generateTrackEvents(tune, track: &tracks[index])
        }

        if !tracks.isEmpty {
            processTempoTrack(tune, track: &tracks[0])
        }

        return tracks
    }

    private func createTracks(_ tune: ABCTune) -> [ABCMIDITrack] {
        var tracks: [ABCMIDITrack] = [
            ABCMIDITrack(trackNumber: 0, type: .tempo, voiceNumber: 0, name: "Tempo Track", channel: -1, events: [])
        ]

        var trackNumber = 1
        for voice in tune.voices.values.sorted(by: { $0.id < $1.id }) {
            tracks.append(ABCMIDITrack(trackNumber: trackNumber, type: .notes, voiceNumber: voice.id, name: voice.name.isEmpty ? "Voice" : voice.name, channel: -1, events: []))
            trackNumber += 1
        }

        return tracks
    }

    private func assignChannels(_ tune: ABCTune, tracks: inout [ABCMIDITrack]) {
        for index in tracks.indices where tracks[index].trackNumber != 0 {
            if let voice = tune.voices[tracks[index].voiceNumber], voice.channel >= 0 {
                tracks[index].channel = voice.channel
                channelManager.assignExplicitChannel(voiceID: tracks[index].voiceNumber, channel: voice.channel)
            }
        }

        for index in tracks.indices where tracks[index].trackNumber != 0 {
            if tracks[index].channel < 0 {
                tracks[index].channel = channelManager.assignChannel(voiceID: tracks[index].voiceNumber)
            }
        }

        for index in tracks.indices where tracks[index].trackNumber != 0 {
            if let voice = tune.voices[tracks[index].voiceNumber] {
                addProgramChange(program: voice.instrument, channel: tracks[index].channel, timestamp: 0, track: &tracks[index])
            }
        }
    }

    private func generateTrackEvents(_ tune: ABCTune, track: inout ABCMIDITrack) {
        currentTime = 0
        activeNotes.removeAll(keepingCapacity: true)
        var maxEndTime = 0.0

        for feature in tune.features where feature.voiceID == track.voiceNumber {
            processFeature(tune, feature: feature, track: &track, maxEndTime: &maxEndTime)
        }

        flushActiveNotes(track: &track)
        addEndOfTrack(timestamp: max(currentTime, maxEndTime), track: &track)
        sortEvents(&track)
    }

    private func processTempoTrack(_ tune: ABCTune, track: inout ABCMIDITrack) {
        addTempo(bpm: tune.defaultTempo.bpm, timestamp: 0, track: &track)
        addTimeSignature(num: tune.defaultTimeSig.num, denom: tune.defaultTimeSig.denom, timestamp: 0, track: &track)
        addKeySignature(sharps: tune.defaultKey.sharps, isMajor: tune.defaultKey.isMajor, timestamp: 0, track: &track)
        if !tune.title.isEmpty {
            addText(tune.title, timestamp: 0, track: &track)
        }

        var maxEndTime = 0.0
        for feature in tune.features {
            let voice = tune.voices[feature.voiceID]
            let tsBeats = voice.map { timestampToBeats(feature.timestamp, voice: $0) } ?? (feature.timestamp * Double(tune.defaultTimeSig.denom))

            switch feature.data {
            case let .tempo(tempo): addTempo(bpm: tempo.bpm, timestamp: tsBeats, track: &track)
            case let .time(time): addTimeSignature(num: time.num, denom: time.denom, timestamp: tsBeats, track: &track)
            case let .key(key): addKeySignature(sharps: key.sharps, isMajor: key.isMajor, timestamp: tsBeats, track: &track)
            default: break
            }

            let featureEnd: Double
            switch feature.data {
            case let .note(note):
                featureEnd = tsBeats + durationToBeats(note.duration, voice: tune.voices[feature.voiceID]!)
            case let .rest(rest):
                featureEnd = tsBeats + durationToBeats(rest.duration, voice: tune.voices[feature.voiceID]!)
            case let .chord(chord):
                featureEnd = tsBeats + durationToBeats(chord.duration, voice: tune.voices[feature.voiceID]!)
            case let .gchord(gChord):
                featureEnd = tsBeats + durationToBeats(gChord.duration, voice: tune.voices[feature.voiceID]!)
            default:
                featureEnd = tsBeats
            }
            maxEndTime = max(maxEndTime, featureEnd)
        }

        addEndOfTrack(timestamp: maxEndTime, track: &track)
        sortEvents(&track)
    }

    private func processFeature(_ tune: ABCTune, feature: ABCFeature, track: inout ABCMIDITrack, maxEndTime: inout Double) {
        guard let voice = tune.voices[track.voiceNumber] else { return }
        let timestamp = timestampToBeats(feature.timestamp, voice: voice)

        switch feature.data {
        case let .note(note):
            processActiveNotes(currentTime: timestamp, track: &track)
            scheduleNoteOn(midiNote: note.midiNote, velocity: note.velocity, channel: track.channel, timestamp: timestamp, track: &track)
            let noteOffTime = timestamp + durationToBeats(note.duration, voice: voice)
            scheduleNoteOff(midiNote: note.midiNote, channel: track.channel, timestamp: noteOffTime)
            maxEndTime = max(maxEndTime, noteOffTime)
        case let .rest(rest):
            let restEnd = timestamp + durationToBeats(rest.duration, voice: voice)
            processActiveNotes(currentTime: restEnd, track: &track)
            maxEndTime = max(maxEndTime, restEnd)
        case let .chord(chord):
            processActiveNotes(currentTime: timestamp, track: &track)
            for note in chord.notes {
                scheduleNoteOn(midiNote: note.midiNote, velocity: note.velocity, channel: track.channel, timestamp: timestamp, track: &track)
                let noteOffTime = timestamp + durationToBeats(chord.duration, voice: voice)
                scheduleNoteOff(midiNote: note.midiNote, channel: track.channel, timestamp: noteOffTime)
                maxEndTime = max(maxEndTime, noteOffTime)
            }
        case let .gchord(gChord):
            let noteOffTime = timestamp + durationToBeats(gChord.duration, voice: voice)
            if !playChordsEnabled() {
                maxEndTime = max(maxEndTime, noteOffTime)
                break
            }
            processActiveNotes(currentTime: timestamp, track: &track)
            for interval in chordIntervals(for: gChord.chordType) {
                let midiNote = min(max(gChord.rootNote + interval + voice.transpose, 0), 127)
                scheduleNoteOn(midiNote: midiNote, velocity: voice.velocity, channel: track.channel, timestamp: timestamp, track: &track)
                scheduleNoteOff(midiNote: midiNote, channel: track.channel, timestamp: noteOffTime)
            }
            maxEndTime = max(maxEndTime, noteOffTime)
        default:
            break
        }

        currentTime = max(currentTime, timestamp)
    }

    private func scheduleNoteOn(midiNote: Int, velocity: Int, channel: Int, timestamp: Double, track: inout ABCMIDITrack) {
        track.events.append(ABCMIDIEvent(type: .noteOn, timestamp: timestamp, channel: channel, data1: midiNote, data2: velocity))
    }

    private func scheduleNoteOff(midiNote: Int, channel: Int, timestamp: Double) {
        activeNotes.append(ABCActiveMIDINote(midiNote: midiNote, channel: channel, velocity: 0, endTime: timestamp))
    }

    private func processActiveNotes(currentTime: Double, track: inout ABCMIDITrack) {
        var retained: [ABCActiveMIDINote] = []
        for active in activeNotes {
            if active.endTime <= currentTime {
                track.events.append(ABCMIDIEvent(type: .noteOff, timestamp: active.endTime, channel: active.channel, data1: active.midiNote, data2: 0))
            } else {
                retained.append(active)
            }
        }
        activeNotes = retained
    }

    private func flushActiveNotes(track: inout ABCMIDITrack) {
        for active in activeNotes {
            track.events.append(ABCMIDIEvent(type: .noteOff, timestamp: active.endTime, channel: active.channel, data1: active.midiNote, data2: 0))
        }
        activeNotes.removeAll(keepingCapacity: true)
    }

    private func addProgramChange(program: Int, channel: Int, timestamp: Double, track: inout ABCMIDITrack) {
        track.events.append(ABCMIDIEvent(type: .programChange, timestamp: timestamp, channel: channel, data1: program, data2: 0))
    }

    private func addTempo(bpm: Int, timestamp: Double, track: inout ABCMIDITrack) {
        let mpq = UInt32(60_000_000 / max(bpm, 1))
        let meta: [UInt8] = [UInt8((mpq >> 16) & 0xFF), UInt8((mpq >> 8) & 0xFF), UInt8(mpq & 0xFF)]
        track.events.append(ABCMIDIEvent(type: .metaTempo, timestamp: timestamp, channel: 0, data1: 0, data2: 0, metaData: meta))
    }

    private func addTimeSignature(num: Int, denom: Int, timestamp: Double, track: inout ABCMIDITrack) {
        var denomPower = 0
        var temp = max(denom, 1)
        while temp > 1 {
            temp /= 2
            denomPower += 1
        }
        let meta: [UInt8] = [UInt8(num), UInt8(denomPower), 24, 8]
        track.events.append(ABCMIDIEvent(type: .metaTimeSignature, timestamp: timestamp, channel: 0, data1: 0, data2: 0, metaData: meta))
    }

    private func addKeySignature(sharps: Int, isMajor: Bool, timestamp: Double, track: inout ABCMIDITrack) {
        let sf = UInt8(bitPattern: Int8(clamping: sharps))
        let meta: [UInt8] = [sf, isMajor ? 0 : 1]
        track.events.append(ABCMIDIEvent(type: .metaKeySignature, timestamp: timestamp, channel: 0, data1: 0, data2: 0, metaData: meta))
    }

    private func addText(_ text: String, timestamp: Double, track: inout ABCMIDITrack) {
        track.events.append(ABCMIDIEvent(type: .metaText, timestamp: timestamp, channel: 0, data1: 0, data2: 0, metaData: Array(text.utf8)))
    }

    private func addEndOfTrack(timestamp: Double, track: inout ABCMIDITrack) {
        track.events.append(ABCMIDIEvent(type: .metaEndOfTrack, timestamp: timestamp, channel: 0, data1: 0, data2: 0))
    }

    private func sortEvents(_ track: inout ABCMIDITrack) {
        track.events.sort { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return eventPriority(lhs.type) < eventPriority(rhs.type)
            }
            return lhs.timestamp < rhs.timestamp
        }
    }
}

private func durationToBeats(_ duration: ABCFraction, voice: ABCVoiceContext) -> Double {
    duration.toDouble() * Double(voice.timeSig.denom)
}

private func timestampToBeats(_ timestamp: Double, voice: ABCVoiceContext) -> Double {
    timestamp * Double(voice.timeSig.denom)
}

private func playChordsEnabled() -> Bool {
    ProcessInfo.processInfo.environment["ED_PLAY_CHORDS"] != nil
}

private func chordIntervals(for chordType: String) -> [Int] {
    switch chordType {
    case "minor": return [0, 3, 7]
    case "dom7": return [0, 4, 7, 10]
    case "maj7": return [0, 4, 7, 11]
    case "m7": return [0, 3, 7, 10]
    case "dim": return [0, 3, 6]
    case "aug": return [0, 4, 8]
    default: return [0, 4, 7]
    }
}

private func eventPriority(_ type: ABCMIDIEventType) -> Int {
    switch type {
    case .programChange: return 0
    case .metaTempo, .metaTimeSignature, .metaKeySignature, .metaText: return 1
    case .noteOff: return 2
    case .noteOn: return 3
    case .controlChange: return 4
    case .metaEndOfTrack: return 5
    }
}
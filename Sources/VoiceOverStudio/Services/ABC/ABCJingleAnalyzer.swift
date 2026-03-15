import Foundation

enum ABCJingleWarningSeverity: String, Equatable {
    case info
    case warning
}

enum ABCJingleWarningCode: String, Equatable {
    case longCue
    case longTail
    case denseTexture
    case busyPercussion
    case tooManyVoices
    case lowRangeMasking
}

struct ABCJingleWarning: Equatable {
    var code: ABCJingleWarningCode
    var severity: ABCJingleWarningSeverity
    var message: String
}

struct ABCJingleAnalysis: Equatable {
    var estimatedDurationBeats: Double
    var estimatedDurationSeconds: Double
    var tailDurationBeats: Double
    var tailDurationSeconds: Double
    var voiceCount: Int
    var melodicVoiceCount: Int
    var percussionVoiceCount: Int
    var soundingEventCount: Int
    var maxSimultaneousNotes: Int
    var lowestMIDINote: Int?
    var highestMIDINote: Int?
    var warnings: [ABCJingleWarning]
}

struct ABCJingleAnalyzer {
    func analyze(_ tune: ABCTune) -> ABCJingleAnalysis {
        let timeline = buildTimeline(for: tune)
        let durationBeats = timeline.totalDurationBeats
        let durationSeconds = seconds(forBeat: durationBeats, tempoSegments: timeline.tempoSegments)
        let tailBeats = max(0, timeline.lastSoundEndBeat - timeline.lastSoundOnsetBeat)
        let tailSeconds = max(0, seconds(forBeat: timeline.lastSoundEndBeat, tempoSegments: timeline.tempoSegments) - seconds(forBeat: timeline.lastSoundOnsetBeat, tempoSegments: timeline.tempoSegments))

        var warnings: [ABCJingleWarning] = []
        if durationSeconds > 8.0 {
            warnings.append(ABCJingleWarning(code: .longCue, severity: .warning, message: "Cue runs longer than 8 seconds and may crowd spoken intros or outros."))
        }
        if tailSeconds > 2.5 {
            warnings.append(ABCJingleWarning(code: .longTail, severity: .warning, message: "Cue has a long tail and may overlap narration starts or transitions."))
        }
        if timeline.maxSimultaneousNotes > 4 {
            warnings.append(ABCJingleWarning(code: .denseTexture, severity: .warning, message: "Texture peaks above four simultaneous notes, which can mask spoken content."))
        }
        if tune.voices.count > 3 {
            warnings.append(ABCJingleWarning(code: .tooManyVoices, severity: .warning, message: "More than three voices is likely too busy for short spoken-word cues."))
        }
        if let lowestMIDINote = timeline.lowestMIDINote, lowestMIDINote < 36 {
            warnings.append(ABCJingleWarning(code: .lowRangeMasking, severity: .warning, message: "Very low notes can compete with speech warmth and podcast bed clarity."))
        }
        if timeline.percussionOnsetRate > 6.0 {
            warnings.append(ABCJingleWarning(code: .busyPercussion, severity: .warning, message: "Percussion onset rate is high for a speech-safe jingle or podcast transition."))
        }

        let percussionVoiceCount = tune.voices.values.filter(\.percussion).count
        return ABCJingleAnalysis(
            estimatedDurationBeats: durationBeats,
            estimatedDurationSeconds: durationSeconds,
            tailDurationBeats: tailBeats,
            tailDurationSeconds: tailSeconds,
            voiceCount: tune.voices.count,
            melodicVoiceCount: max(0, tune.voices.count - percussionVoiceCount),
            percussionVoiceCount: percussionVoiceCount,
            soundingEventCount: timeline.soundingEventCount,
            maxSimultaneousNotes: timeline.maxSimultaneousNotes,
            lowestMIDINote: timeline.lowestMIDINote,
            highestMIDINote: timeline.highestMIDINote,
            warnings: warnings
        )
    }

    private func buildTimeline(for tune: ABCTune) -> TimelineSummary {
        var totalDurationBeats = 0.0
        var lastSoundOnsetBeat = 0.0
        var lastSoundEndBeat = 0.0
        var soundingEventCount = 0
        var lowestMIDINote: Int?
        var highestMIDINote: Int?
        var noteWindows: [(start: Double, end: Double, count: Int)] = []
        var tempoEvents: [(beat: Double, bpm: Int)] = [(0.0, max(tune.defaultTempo.bpm, 1))]
        var percussionOnsetCount = 0

        for feature in tune.features {
            let voice = tune.voices[feature.voiceID] ?? defaultVoiceContext(from: tune, voiceID: feature.voiceID)
            let startBeat = analysisTimestampToBeats(feature.timestamp, voice: voice)
            let durationBeat = featureDurationBeats(feature.data, voice: voice)
            let endBeat = startBeat + durationBeat
            totalDurationBeats = max(totalDurationBeats, endBeat)

            switch feature.data {
            case let .note(note):
                soundingEventCount += 1
                noteWindows.append((startBeat, endBeat, 1))
                lastSoundOnsetBeat = max(lastSoundOnsetBeat, startBeat)
                lastSoundEndBeat = max(lastSoundEndBeat, endBeat)
                lowestMIDINote = min(lowestMIDINote ?? note.midiNote, note.midiNote)
                highestMIDINote = max(highestMIDINote ?? note.midiNote, note.midiNote)
                if voice.percussion { percussionOnsetCount += 1 }
            case let .chord(chord):
                soundingEventCount += 1
                noteWindows.append((startBeat, endBeat, chord.notes.count))
                lastSoundOnsetBeat = max(lastSoundOnsetBeat, startBeat)
                lastSoundEndBeat = max(lastSoundEndBeat, endBeat)
                for note in chord.notes {
                    lowestMIDINote = min(lowestMIDINote ?? note.midiNote, note.midiNote)
                    highestMIDINote = max(highestMIDINote ?? note.midiNote, note.midiNote)
                }
                if voice.percussion { percussionOnsetCount += 1 }
            case let .gchord(gChord):
                soundingEventCount += 1
                let chordNoteCount = analysisChordIntervals(for: gChord.chordType).count
                noteWindows.append((startBeat, endBeat, chordNoteCount))
                lastSoundOnsetBeat = max(lastSoundOnsetBeat, startBeat)
                lastSoundEndBeat = max(lastSoundEndBeat, endBeat)
                for interval in analysisChordIntervals(for: gChord.chordType) {
                    let midiNote = min(max(gChord.rootNote + interval + voice.transpose, 0), 127)
                    lowestMIDINote = min(lowestMIDINote ?? midiNote, midiNote)
                    highestMIDINote = max(highestMIDINote ?? midiNote, midiNote)
                }
                if voice.percussion { percussionOnsetCount += 1 }
            case let .tempo(tempo):
                tempoEvents.append((startBeat, max(tempo.bpm, 1)))
            default:
                break
            }
        }

        let maxSimultaneousNotes = peakSimultaneousNotes(noteWindows)
        let tempoSegments = buildTempoSegments(from: tempoEvents, totalDurationBeats: totalDurationBeats)
        let percussionDurationSeconds = seconds(forBeat: totalDurationBeats, tempoSegments: tempoSegments)
        let percussionOnsetRate = percussionDurationSeconds > 0 ? Double(percussionOnsetCount) / percussionDurationSeconds : 0

        return TimelineSummary(
            totalDurationBeats: totalDurationBeats,
            lastSoundOnsetBeat: lastSoundOnsetBeat,
            lastSoundEndBeat: lastSoundEndBeat,
            soundingEventCount: soundingEventCount,
            maxSimultaneousNotes: maxSimultaneousNotes,
            lowestMIDINote: lowestMIDINote,
            highestMIDINote: highestMIDINote,
            percussionOnsetRate: percussionOnsetRate,
            tempoSegments: tempoSegments
        )
    }
}

private struct TimelineSummary {
    var totalDurationBeats: Double
    var lastSoundOnsetBeat: Double
    var lastSoundEndBeat: Double
    var soundingEventCount: Int
    var maxSimultaneousNotes: Int
    var lowestMIDINote: Int?
    var highestMIDINote: Int?
    var percussionOnsetRate: Double
    var tempoSegments: [ABCTempoSegment]
}

private struct ABCTempoSegment {
    var startBeat: Double
    var bpm: Int
}

private func buildTempoSegments(from tempoEvents: [(beat: Double, bpm: Int)], totalDurationBeats: Double) -> [ABCTempoSegment] {
    let sorted = tempoEvents.sorted {
        if $0.beat == $1.beat {
            return $0.bpm < $1.bpm
        }
        return $0.beat < $1.beat
    }

    var deduped: [ABCTempoSegment] = []
    for event in sorted {
        let beat = max(0, min(event.beat, totalDurationBeats))
        if let last = deduped.last, abs(last.startBeat - beat) < 0.000001 {
            deduped[deduped.count - 1] = ABCTempoSegment(startBeat: beat, bpm: event.bpm)
        } else {
            deduped.append(ABCTempoSegment(startBeat: beat, bpm: event.bpm))
        }
    }
    return deduped.isEmpty ? [ABCTempoSegment(startBeat: 0, bpm: 120)] : deduped
}

private func seconds(forBeat beat: Double, tempoSegments: [ABCTempoSegment]) -> Double {
    guard beat > 0 else { return 0 }
    let sorted = tempoSegments.sorted { $0.startBeat < $1.startBeat }
    var seconds = 0.0
    var index = 0

    while index < sorted.count {
        let segment = sorted[index]
        let nextBeat = index + 1 < sorted.count ? sorted[index + 1].startBeat : beat
        let clampedEnd = min(beat, nextBeat)
        if clampedEnd > segment.startBeat {
            let deltaBeats = clampedEnd - segment.startBeat
            seconds += deltaBeats * 60.0 / Double(max(segment.bpm, 1))
        }
        if nextBeat >= beat {
            break
        }
        index += 1
    }

    return seconds
}

private func peakSimultaneousNotes(_ windows: [(start: Double, end: Double, count: Int)]) -> Int {
    var changes: [(beat: Double, delta: Int, isStart: Bool)] = []
    for window in windows {
        changes.append((window.start, window.count, true))
        changes.append((window.end, -window.count, false))
    }

    changes.sort {
        if $0.beat == $1.beat {
            if $0.isStart == $1.isStart {
                return $0.delta < $1.delta
            }
            return !$0.isStart && $1.isStart
        }
        return $0.beat < $1.beat
    }

    var active = 0
    var peak = 0
    for change in changes {
        active += change.delta
        peak = max(peak, active)
    }
    return peak
}

private func featureDurationBeats(_ data: ABCFeatureData, voice: ABCVoiceContext) -> Double {
    switch data {
    case let .note(note): return analysisDurationToBeats(note.duration, voice: voice)
    case let .rest(rest): return analysisDurationToBeats(rest.duration, voice: voice)
    case let .chord(chord): return analysisDurationToBeats(chord.duration, voice: voice)
    case let .gchord(gChord): return analysisDurationToBeats(gChord.duration, voice: voice)
    default: return 0
    }
}

private func defaultVoiceContext(from tune: ABCTune, voiceID: Int) -> ABCVoiceContext {
    ABCVoiceContext(
        id: voiceID,
        name: String(voiceID),
        key: tune.defaultKey,
        timeSig: tune.defaultTimeSig,
        unitLen: tune.defaultUnit,
        transpose: 0,
        octaveShift: 0,
        instrument: tune.defaultInstrument,
        channel: tune.defaultChannel,
        velocity: 80,
        percussion: tune.defaultPercussion
    )
}

private func analysisDurationToBeats(_ duration: ABCFraction, voice: ABCVoiceContext) -> Double {
    duration.toDouble() * Double(voice.timeSig.denom)
}

private func analysisTimestampToBeats(_ timestamp: Double, voice: ABCVoiceContext) -> Double {
    timestamp * Double(voice.timeSig.denom)
}

private func analysisChordIntervals(for chordType: String) -> [Int] {
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
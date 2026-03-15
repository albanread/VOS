import Foundation

final class ABCMusicParser {
    var currentTime: Double = 0
    var currentLine: Int = 0

    private var voiceBarAccidentals: [Int: [Int?]] = [:]
    private var tupletNum: Int = 1
    private var tupletDenom: Int = 1
    private var tupletNotesRemaining: Int = 0

    func reset() {
        currentTime = 0
        currentLine = 0
        voiceBarAccidentals.removeAll(keepingCapacity: true)
        tupletNum = 1
        tupletDenom = 1
        tupletNotesRemaining = 0
    }

    func parseMusicLine(_ line: String, tune: inout ABCTune, voiceManager: ABCVoiceManager) throws {
        if line.count >= 2 {
            let chars = Array(line)
            if chars[1] == ":" {
                try parseInlineHeader(line, tune: &tune, voiceManager: voiceManager)
                return
            }
        }

        try parseNoteSequence(line, tune: &tune, voiceManager: voiceManager)
    }

    private func parseInlineHeader(_ line: String, tune: inout ABCTune, voiceManager: ABCVoiceManager) throws {
        let chars = Array(line)
        guard chars.count >= 2, chars[1] == ":" else { return }
        let field = chars[0]
        let value = String(chars.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        try applyInlineFieldValue(field, value: value, tune: &tune, voiceManager: voiceManager)
    }

    fileprivate func applyInlineFieldValue(_ field: Character, value: String, tune: inout ABCTune, voiceManager: ABCVoiceManager) throws {
        guard var voice = tune.voices[voiceManager.currentVoice] else { return }

        switch field {
        case "Q":
            var tempoString = value
            if let eqIndex = tempoString.firstIndex(of: "=") {
                tempoString = String(tempoString[tempoString.index(after: eqIndex)...])
            }
            tempoString = tempoString.trimmingCharacters(in: .whitespaces)
            if let bpm = Int(tempoString) {
                tune.defaultTempo = ABCTempo(bpm: bpm)
                tune.features.append(ABCFeature(voiceID: voiceManager.currentVoice, timestamp: currentTime, lineNumber: currentLine, data: .tempo(ABCTempo(bpm: bpm))))
            }
        case "M":
            let timeSig = parseTimeSignature(value, fallback: voice.timeSig)
            voice.timeSig = timeSig
            tune.voices[voiceManager.currentVoice] = voice
            tune.features.append(ABCFeature(voiceID: voiceManager.currentVoice, timestamp: currentTime, lineNumber: currentLine, data: .time(timeSig)))
        case "L":
            if let unit = parseFractionValue(value) {
                voice.unitLen = unit
                tune.voices[voiceManager.currentVoice] = voice
            }
        case "K":
            let keySig = parseABCKeySig(value)
            voice.key = keySig
            tune.voices[voiceManager.currentVoice] = voice
            tune.features.append(ABCFeature(voiceID: voiceManager.currentVoice, timestamp: currentTime, lineNumber: currentLine, data: .key(keySig)))
        default:
            break
        }
    }

    private func parseNoteSequence(_ sequence: String, tune: inout ABCTune, voiceManager: ABCVoiceManager) throws {
        let chars = Array(sequence)
        var pos = 0

        while pos < chars.count {
            pos = skipWhitespace(chars, from: pos)
            if pos >= chars.count { break }

            if skipGraceGroup(chars, pos: &pos) {
                continue
            }

            if chars[pos] == "[" {
                if try parseInlineBracketField(chars, pos: &pos, tune: &tune, voiceManager: voiceManager) {
                    continue
                }
            }

            if chars[pos] == "\"" {
                if var guitarChord = parseGuitarChord(chars, pos: &pos) {
                    let nextPos = skipWhitespace(chars, from: pos)
                    if nextPos < chars.count {
                        var probe = nextPos
                        if let note = try parseNote(chars, pos: &probe, tune: tune, voiceID: voiceManager.currentVoice) {
                            guitarChord.duration = note.duration
                        } else {
                            guitarChord.duration = tune.voices[voiceManager.currentVoice]?.unitLen ?? tune.defaultUnit
                        }
                    } else {
                        guitarChord.duration = tune.voices[voiceManager.currentVoice]?.unitLen ?? tune.defaultUnit
                    }
                    tune.features.append(ABCFeature(voiceID: voiceManager.currentVoice, timestamp: currentTime, lineNumber: currentLine, data: .gchord(guitarChord)))
                    continue
                }
            }

            if chars[pos] == "[" {
                let start = pos
                if let chord = try parseChord(chars, pos: &pos, tune: tune, voiceID: voiceManager.currentVoice) {
                    tune.features.append(ABCFeature(voiceID: voiceManager.currentVoice, timestamp: currentTime, lineNumber: currentLine, data: .chord(chord)))
                    currentTime += chord.duration.toDouble()
                    continue
                }
                pos = max(start + 1, pos)
            }

            if isBarLine(chars[pos]) {
                if let barLine = parseBarLine(chars, pos: &pos) {
                    resetVoiceBarAccidentals(voiceManager.currentVoice)
                    tune.features.append(ABCFeature(voiceID: voiceManager.currentVoice, timestamp: currentTime, lineNumber: currentLine, data: .bar(barLine)))
                    continue
                }
            }

            if chars[pos] == "z" || chars[pos] == "Z" {
                if let rest = parseRest(chars, pos: &pos, tune: tune, voiceID: voiceManager.currentVoice) {
                    tune.features.append(ABCFeature(voiceID: voiceManager.currentVoice, timestamp: currentTime, lineNumber: currentLine, data: .rest(rest)))
                    currentTime += rest.duration.toDouble()
                    continue
                }
            }

            if chars[pos] == "(" || chars[pos] == ")" {
                if chars[pos] == "(", pos + 1 < chars.count, isDigit(chars[pos + 1]) {
                    _ = try parseTupletSpecifier(chars, pos: &pos, tune: tune, voiceID: voiceManager.currentVoice)
                    continue
                }
                pos += 1
                continue
            }

            if isNote(chars[pos]) || isAccidentalMarker(chars[pos]) {
                let voiceID = voiceManager.currentVoice
                if var note = try parseNote(chars, pos: &pos, tune: tune, voiceID: voiceID) {
                    var hasBrokenRhythm = false
                    var firstLonger = false

                    if pos < chars.count {
                        if chars[pos] == ">" {
                            hasBrokenRhythm = true
                            firstLonger = true
                            pos += 1
                        } else if chars[pos] == "<" {
                            hasBrokenRhythm = true
                            firstLonger = false
                            pos += 1
                        } else {
                            var lookahead = pos
                            while skipGraceGroup(chars, pos: &lookahead) {
                                lookahead = skipWhitespace(chars, from: lookahead)
                            }
                            if lookahead < chars.count {
                                if chars[lookahead] == ">" {
                                    hasBrokenRhythm = true
                                    firstLonger = true
                                    pos = lookahead + 1
                                } else if chars[lookahead] == "<" {
                                    hasBrokenRhythm = true
                                    firstLonger = false
                                    pos = lookahead + 1
                                }
                            }
                        }
                    }

                    if hasBrokenRhythm {
                        note.duration = note.duration.mul(ABCFraction(firstLonger ? 3 : 1, 2))
                    }

                    applyTuplet(to: &note.duration)

                    if pos < chars.count, chars[pos] == "-" {
                        note.isTied = true
                        pos += 1
                    }

                    try mergeTiedNotes(chars, pos: &pos, note: &note, tune: tune, voiceID: voiceID)
                    tune.features.append(ABCFeature(voiceID: voiceID, timestamp: currentTime, lineNumber: currentLine, data: .note(note)))
                    currentTime += note.duration.toDouble()

                    if hasBrokenRhythm {
                        pos = skipWhitespace(chars, from: pos)
                        while skipGraceGroup(chars, pos: &pos) {
                            pos = skipWhitespace(chars, from: pos)
                        }
                        if pos < chars.count, var nextNote = try parseNote(chars, pos: &pos, tune: tune, voiceID: voiceID) {
                            nextNote.duration = nextNote.duration.mul(ABCFraction(firstLonger ? 1 : 3, 2))
                            applyTuplet(to: &nextNote.duration)
                            if pos < chars.count, chars[pos] == "-" {
                                nextNote.isTied = true
                                pos += 1
                            }
                            try mergeTiedNotes(chars, pos: &pos, note: &nextNote, tune: tune, voiceID: voiceID)
                            tune.features.append(ABCFeature(voiceID: voiceID, timestamp: currentTime, lineNumber: currentLine, data: .note(nextNote)))
                            currentTime += nextNote.duration.toDouble()
                        }
                    }
                    continue
                }
            }

            pos += 1
        }
    }

    private func parseNote(_ chars: [Character], pos: inout Int, tune: ABCTune, voiceID: Int) throws -> ABCNote? {
        guard pos < chars.count else { return nil }
        var probe = pos
        _ = parseAccidental(chars, pos: &probe)
        guard probe < chars.count, isNote(chars[probe]) else { return nil }

        let explicitAccidental = parseAccidental(chars, pos: &pos)
        guard let pitch = parseNotePitch(chars, pos: &pos) else { return nil }
        let octave = parseOctave(chars, pos: &pos)
        guard let voice = tune.voices[voiceID] else { return nil }
        let duration = parseDuration(chars, pos: &pos, defaultDuration: voice.unitLen)

        guard let noteIndex = pitchIndex(pitch) else { return nil }
        var accidental = keyAccidental(for: voice.key, pitch: Character(pitch.uppercased()))

        if let explicitAccidental {
            accidental = explicitAccidental
            try setBarAccidental(voiceID: voiceID, noteIndex: noteIndex, accidental: explicitAccidental)
        } else if let barAccidental = getBarAccidental(voiceID: voiceID, noteIndex: noteIndex) {
            accidental = barAccidental
        }

        let midiNote = calculateMIDINote(pitch: pitch, accidental: accidental, octave: octave + voice.octaveShift, transpose: voice.transpose)

        return ABCNote(
            pitch: pitch,
            accidental: accidental,
            octave: octave,
            duration: duration,
            midiNote: midiNote,
            velocity: voice.velocity,
            isTied: false
        )
    }

    private func parseRest(_ chars: [Character], pos: inout Int, tune: ABCTune, voiceID: Int) -> ABCRest? {
        guard pos < chars.count, chars[pos] == "z" || chars[pos] == "Z", let voice = tune.voices[voiceID] else { return nil }
        pos += 1
        return ABCRest(duration: parseDuration(chars, pos: &pos, defaultDuration: voice.unitLen))
    }

    private func parseChord(_ chars: [Character], pos: inout Int, tune: ABCTune, voiceID: Int) throws -> ABCChord? {
        guard pos < chars.count, chars[pos] == "[" else { return nil }
        let start = pos
        pos += 1
        var notes: [ABCNote] = []

        while pos < chars.count, chars[pos] != "]" {
            pos = skipWhitespace(chars, from: pos)
            if pos >= chars.count || chars[pos] == "]" { break }
            if let note = try parseNote(chars, pos: &pos, tune: tune, voiceID: voiceID) {
                notes.append(note)
            } else if pos < chars.count, chars[pos] != "]" {
                pos += 1
            }
            pos = skipWhitespace(chars, from: pos)
        }

        guard pos < chars.count, chars[pos] == "]", let voice = tune.voices[voiceID], !notes.isEmpty else {
            pos = min(start + 1, chars.count)
            return nil
        }

        pos += 1
        let duration = parseDuration(chars, pos: &pos, defaultDuration: voice.unitLen)
        return ABCChord(notes: notes, duration: duration)
    }

    private func parseGuitarChord(_ chars: [Character], pos: inout Int) -> ABCGuitarChord? {
        guard pos < chars.count, chars[pos] == "\"" else { return nil }
        pos += 1
        let start = pos
        while pos < chars.count, chars[pos] != "\"" {
            pos += 1
        }
        guard pos < chars.count, chars[pos] == "\"" else { return nil }
        let symbol = String(chars[start..<pos])
        pos += 1
        return ABCGuitarChord(symbol: symbol, rootNote: parseChordRoot(symbol), chordType: parseChordType(symbol), duration: ABCFraction(1, 8))
    }

    private func parseBarLine(_ chars: [Character], pos: inout Int) -> ABCBarLine? {
        guard pos < chars.count, isBarLine(chars[pos]) else { return nil }
        let start = pos
        while pos < chars.count, isBarLine(chars[pos]) {
            pos += 1
        }
        let barString = String(chars[start..<pos])
        let type: ABCBarLineType
        switch barString {
        case "|": type = .bar1
        case "||": type = .doubleBar
        case "|:": type = .repBar
        case ":|": type = .barRep
        case ":|:": type = .doubleRep
        default: type = .bar1
        }
        return ABCBarLine(barType: type)
    }

    private func parseInlineVoiceSwitch(_ chars: [Character], pos: inout Int, tune: inout ABCTune, voiceManager: ABCVoiceManager) throws -> Bool {
        guard pos + 2 < chars.count, chars[pos] == "[", chars[pos + 1] == "V", chars[pos + 2] == ":" else { return false }
        pos += 3
        let start = pos
        while pos < chars.count, chars[pos] != "]", !chars[pos].isWhitespace {
            pos += 1
        }
        let identifier = String(chars[start..<pos])
        while pos < chars.count, chars[pos] != "]" {
            pos += 1
        }
        guard pos < chars.count, chars[pos] == "]", !identifier.isEmpty else { return false }
        pos += 1

        voiceManager.saveCurrentTime(currentTime)
        let voiceID = voiceManager.switchToVoice(identifier, tune: &tune)
        currentTime = voiceManager.restoreVoiceTime(voiceID)
        tune.features.append(ABCFeature(voiceID: voiceID, timestamp: currentTime, lineNumber: currentLine, data: .voice(ABCVoiceChange(voiceNumber: voiceID, voiceName: identifier))))
        return true
    }

    private func parseInlineBracketField(_ chars: [Character], pos: inout Int, tune: inout ABCTune, voiceManager: ABCVoiceManager) throws -> Bool {
        guard pos + 3 < chars.count, chars[pos] == "[", chars[pos + 2] == ":", chars[pos + 1].isLetter else { return false }
        let field = chars[pos + 1].uppercased().first ?? chars[pos + 1]
        if field == "V" {
            return try parseInlineVoiceSwitch(chars, pos: &pos, tune: &tune, voiceManager: voiceManager)
        }
        var p = pos + 3
        let start = p
        while p < chars.count, chars[p] != "]" {
            p += 1
        }
        guard p < chars.count, chars[p] == "]" else { return false }
        let value = String(chars[start..<p]).trimmingCharacters(in: .whitespaces)
        try applyInlineFieldValue(field, value: value, tune: &tune, voiceManager: voiceManager)
        pos = p + 1
        return true
    }

    private func mergeTiedNotes(_ chars: [Character], pos: inout Int, note: inout ABCNote, tune: ABCTune, voiceID: Int) throws {
        while note.isTied {
            var scan = skipTieJoinDelimiters(chars, from: pos)
            guard scan < chars.count, isNote(chars[scan]) else { break }
            guard let nextNote = try parseNote(chars, pos: &scan, tune: tune, voiceID: voiceID), nextNote.midiNote == note.midiNote else { break }
            note.duration = note.duration.add(nextNote.duration)
            pos = scan
            if pos < chars.count, chars[pos] == "-" {
                note.isTied = true
                pos += 1
            } else {
                note.isTied = false
            }
        }
        note.isTied = false
    }

    private func parseTupletSpecifier(_ chars: [Character], pos: inout Int, tune: ABCTune, voiceID: Int) throws -> Bool {
        guard pos + 1 < chars.count, chars[pos] == "(", isDigit(chars[pos + 1]), let voice = tune.voices[voiceID] else { return false }
        pos += 1
        let p = Int(String(chars[pos])) ?? 0
        pos += 1
        var q: Int?
        var r: Int?
        if pos < chars.count, chars[pos] == ":" {
            pos += 1
            if pos < chars.count, isDigit(chars[pos]) {
                q = Int(String(chars[pos]))
                pos += 1
            }
            if pos < chars.count, chars[pos] == ":" {
                pos += 1
                if pos < chars.count, isDigit(chars[pos]) {
                    r = Int(String(chars[pos]))
                    pos += 1
                }
            }
        }
        let inferredQ = inferTupletQ(p: p, timeSig: voice.timeSig)
        let finalQ = q ?? inferredQ
        let finalR = r ?? p
        guard p > 0, finalQ > 0, finalR > 0 else { return false }
        tupletNum = finalQ
        tupletDenom = p
        tupletNotesRemaining = finalR
        return true
    }

    private func applyTuplet(to duration: inout ABCFraction) {
        guard tupletNotesRemaining > 0 else { return }
        duration = duration.mul(ABCFraction(tupletNum, tupletDenom))
        tupletNotesRemaining -= 1
        if tupletNotesRemaining <= 0 {
            tupletNum = 1
            tupletDenom = 1
            tupletNotesRemaining = 0
        }
    }

    private func ensureVoiceBarAccidentalState(_ voiceID: Int) -> [Int?] {
        if let existing = voiceBarAccidentals[voiceID] {
            return existing
        }
        let state = Array(repeating: Optional<Int>.none, count: 7)
        voiceBarAccidentals[voiceID] = state
        return state
    }

    private func setBarAccidental(voiceID: Int, noteIndex: Int, accidental: Int) throws {
        var state = ensureVoiceBarAccidentalState(voiceID)
        state[noteIndex] = accidental
        voiceBarAccidentals[voiceID] = state
    }

    private func getBarAccidental(voiceID: Int, noteIndex: Int) -> Int? {
        voiceBarAccidentals[voiceID]?[noteIndex] ?? nil
    }

    private func resetVoiceBarAccidentals(_ voiceID: Int) {
        voiceBarAccidentals[voiceID] = Array(repeating: Optional<Int>.none, count: 7)
    }
}

private func skipWhitespace(_ chars: [Character], from pos: Int) -> Int {
    var p = pos
    while p < chars.count, chars[p] == " " || chars[p] == "\t" {
        p += 1
    }
    return p
}

private func isDigit(_ char: Character) -> Bool {
    char >= "0" && char <= "9"
}

private func isNote(_ char: Character) -> Bool {
    (char >= "A" && char <= "G") || (char >= "a" && char <= "g")
}

private func isBarLine(_ char: Character) -> Bool {
    char == "|" || char == ":" || char == "[" || char == "]"
}

private func isAccidentalMarker(_ char: Character) -> Bool {
    char == "^" || char == "_" || char == "="
}

private func parseAccidental(_ chars: [Character], pos: inout Int) -> Int? {
    guard pos < chars.count else { return nil }
    let char = chars[pos]
    if char == "^" {
        if pos + 1 < chars.count, chars[pos + 1] == "^" {
            pos += 2
            return 2
        }
        pos += 1
        return 1
    }
    if char == "_" {
        if pos + 1 < chars.count, chars[pos + 1] == "_" {
            pos += 2
            return -2
        }
        pos += 1
        return -1
    }
    if char == "=" {
        pos += 1
        return 0
    }
    return nil
}

private func parseNotePitch(_ chars: [Character], pos: inout Int) -> Character? {
    guard pos < chars.count, isNote(chars[pos]) else { return nil }
    let pitch = chars[pos]
    pos += 1
    return pitch
}

private func parseOctave(_ chars: [Character], pos: inout Int) -> Int {
    var octave = 0
    while pos < chars.count, chars[pos] == "'" {
        octave += 1
        pos += 1
    }
    while pos < chars.count, chars[pos] == "," {
        octave -= 1
        pos += 1
    }
    return octave
}

private func parseDuration(_ chars: [Character], pos: inout Int, defaultDuration: ABCFraction) -> ABCFraction {
    var duration = defaultDuration
    if pos < chars.count, isDigit(chars[pos]) {
        var numerator = 0
        while pos < chars.count, isDigit(chars[pos]) {
            numerator = numerator * 10 + Int(String(chars[pos]))!
            pos += 1
        }
        if pos < chars.count, chars[pos] == "/" {
            pos += 1
            var denominator = 2
            if pos < chars.count, isDigit(chars[pos]) {
                denominator = 0
                while pos < chars.count, isDigit(chars[pos]) {
                    denominator = denominator * 10 + Int(String(chars[pos]))!
                    pos += 1
                }
            }
            duration = ABCFraction(numerator, denominator).mul(defaultDuration)
        } else {
            duration = ABCFraction(numerator, 1).mul(defaultDuration)
        }
    } else if pos < chars.count, chars[pos] == "/" {
        pos += 1
        var denominator = 2
        if pos < chars.count, isDigit(chars[pos]) {
            denominator = 0
            while pos < chars.count, isDigit(chars[pos]) {
                denominator = denominator * 10 + Int(String(chars[pos]))!
                pos += 1
            }
        }
        duration = ABCFraction(defaultDuration.num, defaultDuration.denom * denominator)
    }

    while pos < chars.count, chars[pos] == "." {
        duration = duration.mul(ABCFraction(3, 2))
        pos += 1
    }

    return duration
}

func parseABCKeySig(_ value: String) -> ABCKeySig {
    let keyName = value.trimmingCharacters(in: .whitespaces)
    let isMinor = keyName.contains("m") && keyName != "M"
    let sharps: Int
    if keyName.hasPrefix("C#") { sharps = 7 }
    else if keyName.hasPrefix("F#") { sharps = 6 }
    else if keyName.hasPrefix("B") { sharps = 5 }
    else if keyName.hasPrefix("E") { sharps = 4 }
    else if keyName.hasPrefix("A") { sharps = 3 }
    else if keyName.hasPrefix("D") { sharps = 2 }
    else if keyName.hasPrefix("G") { sharps = 1 }
    else if keyName.hasPrefix("Cb") { sharps = -7 }
    else if keyName.hasPrefix("Gb") { sharps = -6 }
    else if keyName.hasPrefix("Db") { sharps = -5 }
    else if keyName.hasPrefix("Ab") { sharps = -4 }
    else if keyName.hasPrefix("Eb") { sharps = -3 }
    else if keyName.hasPrefix("Bb") { sharps = -2 }
    else if keyName.hasPrefix("F") { sharps = -1 }
    else { sharps = 0 }
    return ABCKeySig(sharps: sharps, isMajor: !isMinor)
}

func parseTimeSignature(_ value: String, fallback: ABCTimeSig) -> ABCTimeSig {
    if value == "C" || value == "c" {
        return ABCTimeSig(num: 4, denom: 4)
    }
    if value == "C|" || value == "c|" {
        return ABCTimeSig(num: 2, denom: 2)
    }
    let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
    if parts.count == 2, let num = Int(parts[0]), let denom = Int(parts[1]) {
        return ABCTimeSig(num: num, denom: denom)
    }
    return fallback
}

func parseFractionValue(_ value: String) -> ABCFraction? {
    let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, let num = Int(parts[0]), let denom = Int(parts[1]) else { return nil }
    return ABCFraction(num, denom)
}

private func calculateMIDINote(pitch: Character, accidental: Int, octave: Int, transpose: Int) -> Int {
    let normalized = Character(pitch.uppercased())
    let semitones: [Character: Int] = ["A": 9, "B": 11, "C": 0, "D": 2, "E": 4, "F": 5, "G": 7]
    guard var semitone = semitones[normalized] else { return 60 }
    semitone += accidental
    var baseOctave = 4
    if pitch.isLowercase {
        baseOctave += 1
    }
    baseOctave += octave
    return min(max(baseOctave * 12 + semitone + transpose, 0), 127)
}

private func pitchIndex(_ pitch: Character) -> Int? {
    switch Character(pitch.uppercased()) {
    case "A": return 0
    case "B": return 1
    case "C": return 2
    case "D": return 3
    case "E": return 4
    case "F": return 5
    case "G": return 6
    default: return nil
    }
}

private func inferTupletQ(p: Int, timeSig: ABCTimeSig) -> Int {
    switch p {
    case 2: return 3
    case 3: return 2
    case 4: return 3
    case 6: return 2
    case 8: return 3
    case 5, 7, 9: return isCompoundMeter(timeSig) ? 3 : 2
    default: return isCompoundMeter(timeSig) ? 3 : 2
    }
}

private func isCompoundMeter(_ timeSig: ABCTimeSig) -> Bool {
    timeSig.denom == 8 && [6, 9, 12].contains(timeSig.num)
}

private func keyAccidental(for key: ABCKeySig, pitch: Character) -> Int {
    let sharpOrder = Array("FCGDAEB")
    let flatOrder = Array("BEADGCF")
    if key.sharps > 0 {
        for idx in 0..<min(key.sharps, sharpOrder.count) where sharpOrder[idx] == pitch {
            _ = idx
            return 1
        }
        return 0
    }
    if key.sharps < 0 {
        let count = min(-key.sharps, flatOrder.count)
        for idx in 0..<count where flatOrder[idx] == pitch {
            _ = idx
            return -1
        }
    }
    return 0
}

private func skipTieJoinDelimiters(_ chars: [Character], from pos: Int) -> Int {
    var p = pos
    while p < chars.count {
        let c = chars[p]
        if c == " " || c == "\t" || c == "\r" || c == "|" || c == ":" {
            p += 1
            continue
        }
        break
    }
    return p
}

private func skipGraceGroup(_ chars: [Character], pos: inout Int) -> Bool {
    guard pos < chars.count, chars[pos] == "{" else { return false }
    pos += 1
    if pos < chars.count, chars[pos] == "/" {
        pos += 1
    }
    while pos < chars.count, chars[pos] != "}" {
        pos += 1
    }
    if pos < chars.count, chars[pos] == "}" {
        pos += 1
        return true
    }
    pos = chars.count
    return true
}

private func parseChordRoot(_ symbol: String) -> Int {
    guard let root = symbol.first?.uppercased().first else { return 48 }
    var midi = 60
    switch root {
    case "C": midi = 60
    case "D": midi = 62
    case "E": midi = 64
    case "F": midi = 65
    case "G": midi = 67
    case "A": midi = 69
    case "B": midi = 71
    default: midi = 60
    }
    let chars = Array(symbol)
    if chars.count > 1 {
        if chars[1] == "#" { midi += 1 }
        if chars[1] == "b" { midi -= 1 }
    }
    return midi - 12
}

private func parseChordType(_ symbol: String) -> String {
    let chars = Array(symbol)
    var typeStart = 1
    if chars.count > 1, chars[1] == "#" || chars[1] == "b" {
        typeStart = 2
    }
    guard typeStart < chars.count else { return "major" }
    let suffix = String(chars[typeStart...])
    switch suffix {
    case "m", "min": return "minor"
    case "7": return "dom7"
    case "maj7", "M7": return "maj7"
    case "m7": return "m7"
    case "dim", "o": return "dim"
    case "aug", "+": return "aug"
    default: return suffix.isEmpty ? "major" : suffix
    }
}
import Foundation

enum ABCParseState {
    case header
    case body
    case complete
}

enum ABCParseError: Error {
    case parseFailed
}

final class ABCParser {
    private(set) var state: ABCParseState = .header
    private(set) var currentLine: Int = 0
    private(set) var errors: [String] = []
    private(set) var warnings: [String] = []

    private let voiceManager = ABCVoiceManager()
    private let musicParser = ABCMusicParser()

    func reset() {
        state = .header
        currentLine = 0
        errors.removeAll(keepingCapacity: true)
        warnings.removeAll(keepingCapacity: true)
        voiceManager.reset()
        musicParser.reset()
    }

    func parse(_ abcContent: String) throws -> ABCTune {
        var tune = ABCTune()
        let ok = parseABC(abcContent, tune: &tune)
        guard ok else { throw ABCParseError.parseFailed }
        return tune
    }

    @discardableResult
    func parseABC(_ abcContent: String, tune: inout ABCTune) -> Bool {
        reset()
        let expanded = ABCRepeatExpander.expandABCRepeats(abcContent)
        let lines = expanded.split(separator: "\n", omittingEmptySubsequences: false)
        var lastField: Character?
        var sawKeyField = false

        for rawLine in lines {
            currentLine += 1
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("%%MIDI") {
                parseMIDIDirective(String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces), tune: &tune)
                continue
            }

            if trimmed.hasPrefix("%") {
                continue
            }

            var cleanLine = trimmed
            if let commentIndex = trimmed.firstIndex(of: "%") {
                cleanLine = String(trimmed[..<commentIndex]).trimmingCharacters(in: .whitespaces)
            }
            if cleanLine.isEmpty { continue }

            if cleanLine.hasPrefix("+:") {
                if let previousField = lastField {
                    if isStringField(previousField) {
                        let continuation = String(cleanLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        parseLine("\(previousField):\(continuation)", tune: &tune)
                    } else {
                        warnings.append("Ignoring +: continuation for non-string field")
                    }
                } else {
                    warnings.append("Ignoring +: continuation with no previous field")
                }
                continue
            }

            if isHeaderField(cleanLine) {
                lastField = cleanLine.first
                if cleanLine.hasPrefix("K:") {
                    sawKeyField = true
                }
            }

            parseLine(cleanLine, tune: &tune)
        }

        if !sawKeyField {
            errors.append("Missing K: field")
            return false
        }

        if errors.isEmpty {
            if tune.voices.isEmpty {
                tune.voices[1] = ABCVoiceContext(
                    id: 1,
                    name: "1",
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
            state = .complete
        }

        return errors.isEmpty
    }

    private func parseLine(_ line: String, tune: inout ABCTune) {
        if line.hasPrefix("[V:"), let endBracket = line.firstIndex(of: "]") {
            let tail = String(line[line.index(after: endBracket)...]).trimmingCharacters(in: .whitespaces)
            if tail.isEmpty {
                let start = line.index(line.startIndex, offsetBy: 3)
                let voiceID = String(line[start..<endBracket]).trimmingCharacters(in: .whitespaces)
                if !voiceID.isEmpty {
                    voiceManager.saveCurrentTime(musicParser.currentTime)
                    let newVoice = voiceManager.switchToVoice(voiceID, tune: &tune)
                    musicParser.currentLine = currentLine
                    musicParser.currentTime = voiceManager.restoreVoiceTime(newVoice)
                }
                return
            }
        }

        if line.hasPrefix("V:") {
            let voiceSpec = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let voiceID = voiceSpec.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            if !voiceID.isEmpty {
                if voiceSpec.contains("=") {
                    voiceManager.saveCurrentTime(musicParser.currentTime)
                    parseHeaderLine(line, tune: &tune)
                    let foundVoice = voiceManager.findVoiceByIdentifier(voiceID, tune: tune)
                    if foundVoice != 0 {
                        voiceManager.registerExternalVoice(foundVoice, identifier: voiceID)
                        let newVoice = voiceManager.switchToVoice(voiceID, tune: &tune)
                        musicParser.currentTime = voiceManager.restoreVoiceTime(newVoice)
                    }
                } else {
                    voiceManager.saveCurrentTime(musicParser.currentTime)
                    let newVoice = voiceManager.switchToVoice(voiceID, tune: &tune)
                    musicParser.currentTime = voiceManager.restoreVoiceTime(newVoice)
                }
            }
            return
        }

        if state == .header, isHeaderField(line) {
            parseHeaderLine(line, tune: &tune)
            if line.hasPrefix("K:") {
                state = .body
            }
            return
        }

        if state == .header {
            state = .body
        }

        if state == .body {
            if tune.voices.isEmpty {
                _ = voiceManager.switchToVoice("1", tune: &tune)
            }
            musicParser.currentLine = currentLine
            do {
                try musicParser.parseMusicLine(line, tune: &tune, voiceManager: voiceManager)
            } catch {
                errors.append("Parse failure on line \(currentLine): \(error.localizedDescription)")
            }
        }
    }

    private func isHeaderField(_ line: String) -> Bool {
        let chars = Array(line)
        return chars.count >= 2 && chars[0].isLetter && chars[1] == ":"
    }

    private func isStringField(_ field: Character) -> Bool {
        "ABCDFGHNORSTWZw".contains(field)
    }

    private func parseHeaderLine(_ line: String, tune: inout ABCTune) {
        let chars = Array(line)
        guard chars.count >= 2 else { return }
        let field = chars[0]
        let value = String(chars.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        switch field {
        case "T": appendStringField(&tune.title, value)
        case "H": appendStringField(&tune.history, value)
        case "C": appendStringField(&tune.composer, value)
        case "O": appendStringField(&tune.origin, value)
        case "R": appendStringField(&tune.rhythm, value)
        case "N": appendStringField(&tune.notes, value)
        case "W": appendStringField(&tune.words, value)
        case "w": appendStringField(&tune.alignedWords, value)
        case "M": tune.defaultTimeSig = parseTimeSignature(value, fallback: tune.defaultTimeSig)
        case "L": if let fraction = parseFractionValue(value) { tune.defaultUnit = fraction }
        case "Q":
            var tempoString = value
            if let eqIndex = tempoString.firstIndex(of: "=") {
                tempoString = String(tempoString[tempoString.index(after: eqIndex)...])
            }
            if let bpm = Int(tempoString.trimmingCharacters(in: .whitespaces)) {
                tune.defaultTempo = ABCTempo(bpm: bpm)
            }
        case "K": tune.defaultKey = parseABCKeySig(value)
        case "V":
            let voiceIDString = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
            if !voiceIDString.isEmpty {
                let voiceID = voiceManager.getOrCreateVoice(voiceIDString, tune: &tune)
                if var voice = tune.voices[voiceID] {
                    let attrOffset = min(voiceIDString.count, value.count)
                    let start = value.index(value.startIndex, offsetBy: attrOffset)
                    let attrs = String(value[start...]).trimmingCharacters(in: .whitespaces)
                    applyVoiceAttributes(attrs, voice: &voice)
                    tune.voices[voiceID] = voice
                }
            }
        default:
            break
        }
    }

    private func appendStringField(_ field: inout String, _ value: String) {
        guard !value.isEmpty else { return }
        if field.isEmpty {
            field = value
        } else {
            field += " " + value
        }
    }

    private func applyVoiceAttributes(_ attrs: String, voice: inout ABCVoiceContext) {
        let chars = Array(attrs)
        var pos = 0
        while pos < chars.count {
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
            if pos >= chars.count { break }

            let keyStart = pos
            while pos < chars.count, chars[pos] != "=", !chars[pos].isWhitespace { pos += 1 }
            guard pos < chars.count, chars[pos] == "=" else {
                while pos < chars.count, !chars[pos].isWhitespace { pos += 1 }
                continue
            }
            let key = String(chars[keyStart..<pos])
            pos += 1

            let quoted = pos < chars.count && chars[pos] == "\""
            if quoted { pos += 1 }
            let valueStart = pos
            if quoted {
                while pos < chars.count, chars[pos] != "\"" { pos += 1 }
            } else {
                while pos < chars.count, !chars[pos].isWhitespace { pos += 1 }
            }
            let value = String(chars[valueStart..<pos]).trimmingCharacters(in: .whitespaces)
            if quoted, pos < chars.count, chars[pos] == "\"" { pos += 1 }

            switch key.lowercased() {
            case "name": voice.name = value
            case "instrument", "program", "prog":
                if let program = Int(value), (0...127).contains(program) {
                    voice.instrument = program
                }
            default:
                break
            }
        }
    }

    private func parseMIDIDirective(_ rest: String, tune: inout ABCTune) {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let subcommand = parts.first?.lowercased() else { return }
        let value = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet.whitespaces) : ""

        let currentVoiceID = tune.voices.isEmpty ? nil : voiceManager.currentVoice

        func updateVoice(_ body: (inout ABCVoiceContext) -> Void) {
            if let currentVoiceID, var voice = tune.voices[currentVoiceID] {
                body(&voice)
                tune.voices[currentVoiceID] = voice
            }
        }

        switch subcommand {
        case "program":
            if let program = Int(value), (0...127).contains(program) {
                if currentVoiceID != nil {
                    updateVoice { $0.instrument = program }
                } else {
                    tune.defaultInstrument = program
                }
            }
        case "channel":
            if let channel = Int(value), (1...16).contains(channel) {
                if currentVoiceID != nil {
                    updateVoice { $0.channel = channel - 1 }
                } else {
                    tune.defaultChannel = channel - 1
                }
            }
        case "transpose":
            if let transpose = Int(value) {
                updateVoice { $0.transpose = transpose }
            }
        case "velocity", "volume":
            if let velocity = Int(value), (0...127).contains(velocity) {
                updateVoice { $0.velocity = velocity }
            }
        case "drum", "percussion":
            let enabled = value.isEmpty || value.caseInsensitiveCompare("on") == .orderedSame || value == "1"
            if currentVoiceID != nil {
                updateVoice {
                    $0.percussion = enabled
                    if enabled { $0.channel = 9 }
                }
            } else {
                tune.defaultPercussion = enabled
                if enabled { tune.defaultChannel = 9 }
            }
        default:
            break
        }
    }
}
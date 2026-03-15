import Foundation

struct ABCJingleRenderResult {
    var tune: ABCTune
    var analysis: ABCJingleAnalysis
    var midiTracks: [ABCMIDITrack]
    var midiData: Data
}

struct ABCJingleValidationResult {
    var tune: ABCTune
    var analysis: ABCJingleAnalysis
}

private struct ABCJingleScaffold {
    var title: String
    var meter: String
    var defaultLength: String
    var tempoBPM: Int
    var key: String
    var barCount: Int
    var barUnitCount: Int

    var headerBlock: String {
        """
        X:1
        T:\(title)
        M:\(meter)
        L:\(defaultLength)
        Q:1/4=\(tempoBPM)
        K:\(key)
        """
    }
}

struct ABCJingleService {
    private let parser: ABCParser
    private let analyzer: ABCJingleAnalyzer
    private let midiGenerator: ABCMIDIGenerator
    private let midiWriter: ABCMIDIWriter

    init(
        parser: ABCParser = ABCParser(),
        analyzer: ABCJingleAnalyzer = ABCJingleAnalyzer(),
        midiGenerator: ABCMIDIGenerator = ABCMIDIGenerator(),
        midiWriter: ABCMIDIWriter = ABCMIDIWriter()
    ) {
        self.parser = parser
        self.analyzer = analyzer
        self.midiGenerator = midiGenerator
        self.midiWriter = midiWriter
    }

    func validate(abcSource: String) throws -> ABCJingleValidationResult {
        let tune = try parser.parse(abcSource)
        let analysis = analyzer.analyze(tune)
        return ABCJingleValidationResult(tune: tune, analysis: analysis)
    }

    func render(abcSource: String) throws -> ABCJingleRenderResult {
        let validation = try validate(abcSource: abcSource)
        let midiTracks = midiGenerator.generateMIDI(validation.tune)
        let midiData = midiWriter.write(tracks: midiTracks)
        return ABCJingleRenderResult(
            tune: validation.tune,
            analysis: validation.analysis,
            midiTracks: midiTracks,
            midiData: midiData
        )
    }

    func exportMIDI(abcSource: String, to outputURL: URL) throws -> ABCJingleRenderResult {
        let result = try render(abcSource: abcSource)
        let directoryURL = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try result.midiData.write(to: outputURL, options: .atomic)
        return result
    }

    func validate(card: ABCJingleCard) throws -> ABCJingleValidationResult {
        try validate(abcSource: card.abcSource)
    }

    func render(card: ABCJingleCard) throws -> ABCJingleRenderResult {
        try render(abcSource: card.abcSource)
    }

    func generateDeterministicABC(for card: ABCJingleCard) -> String {
        let scaffold = makeScaffold(for: card)
        let bars = makeDeterministicBars(for: card, scaffold: scaffold)
        return ([scaffold.headerBlock] + bars).joined(separator: "\n")
    }

    func durationFeedback(for analysis: ABCJingleAnalysis, targetDurationSeconds: Double) -> String? {
        guard targetDurationSeconds > 0 else { return nil }

        let actual = analysis.estimatedDurationSeconds
        let absoluteDelta = abs(actual - targetDurationSeconds)
        let allowedDelta = max(0.6, targetDurationSeconds * 0.35)

        guard absoluteDelta > allowedDelta else { return nil }

        if actual > targetDurationSeconds {
            return String(
                format: "Cue is too long: target %.2fs, estimated %.2fs. Shorten the phrase count, reduce held durations, and use a faster integer BPM tempo such as Q:160 or Q:1/4=160.",
                targetDurationSeconds,
                actual
            )
        }

        return String(
            format: "Cue is too short: target %.2fs, estimated %.2fs. Add a small amount of material or use a slower integer BPM tempo such as Q:120 or Q:1/4=120.",
            targetDurationSeconds,
            actual
        )
    }

    func structureFeedback(for tune: ABCTune) -> String? {
        var barStartByVoice: [Int: Double] = [:]
        var timeSigByVoice: [Int: ABCTimeSig] = [:]

        for feature in tune.features {
            let voiceID = feature.voiceID
            let defaultVoice = tune.voices[voiceID] ?? ABCVoiceContext(
                id: voiceID,
                name: "\(voiceID)",
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

            if timeSigByVoice[voiceID] == nil {
                timeSigByVoice[voiceID] = defaultVoice.timeSig
            }
            if barStartByVoice[voiceID] == nil {
                barStartByVoice[voiceID] = 0
            }

            switch feature.data {
            case let .time(timeSig):
                timeSigByVoice[voiceID] = timeSig
            case .bar:
                let timeSig = timeSigByVoice[voiceID] ?? defaultVoice.timeSig
                let expectedBarDuration = Double(timeSig.num) / Double(timeSig.denom)
                let actualBarDuration = feature.timestamp - (barStartByVoice[voiceID] ?? 0)
                if abs(actualBarDuration - expectedBarDuration) > 0.0001 {
                    let relation = actualBarDuration > expectedBarDuration ? "too long" : "too short"
                    return String(
                        format: "A bar is %@ for %@: expected %.3f whole notes, got %.3f. Rewrite the music so every bar matches the declared meter exactly.",
                        relation,
                        formatTimeSignature(timeSig),
                        expectedBarDuration,
                        actualBarDuration
                    )
                }
                barStartByVoice[voiceID] = feature.timestamp
            default:
                break
            }
        }

        return nil
    }

    func suggestedSpeechSafety(for analysis: ABCJingleAnalysis) -> ABCJingleSpeechSafety {
        if analysis.warnings.contains(where: { $0.severity == .warning }) {
            if analysis.warnings.contains(where: { $0.code == .busyPercussion || $0.code == .denseTexture || $0.code == .lowRangeMasking }) {
                return .risky
            }
            return .review
        }
        return .safe
    }

    func diagnosticReport(for result: ABCJingleRenderResult) -> String {
        var lines: [String] = []
        lines.append("title: \(result.tune.title)")
        lines.append(String(format: "estimated_duration_seconds: %.3f", result.analysis.estimatedDurationSeconds))
        lines.append("voice_count: \(result.tune.voices.count)")

        for voice in result.tune.voices.values.sorted(by: { $0.id < $1.id }) {
            let voiceFeatures = result.tune.features.filter { $0.voiceID == voice.id }
            let noteLikeCount = voiceFeatures.reduce(into: 0) { partialResult, feature in
                switch feature.data {
                case .note, .chord, .gchord:
                    partialResult += 1
                default:
                    break
                }
            }
            let firstTimestamp = voiceFeatures.first?.timestamp ?? 0
            lines.append(String(format: "voice %d name=%@ feature_count=%d note_like=%d first_feature_timestamp=%.3f", voice.id, voice.name, voiceFeatures.count, noteLikeCount, firstTimestamp))
        }

        for track in result.midiTracks.sorted(by: { $0.trackNumber < $1.trackNumber }) {
            let noteOnEvents = track.events.filter { $0.type == .noteOn && $0.data2 > 0 }
            let noteOffEvents = track.events.filter { $0.type == .noteOff }
            let firstNoteOn = noteOnEvents.first?.timestamp ?? -1
            let endOfTrack = track.events.first(where: { $0.type == .metaEndOfTrack })?.timestamp ?? -1
            lines.append(String(format: "track %d type=%@ voice=%d name=%@ channel=%d note_on=%d note_off=%d first_note_on=%.3f end_of_track=%.3f", track.trackNumber, track.type == .tempo ? "tempo" : "notes", track.voiceNumber, track.name, track.channel, noteOnEvents.count, noteOffEvents.count, firstNoteOn, endOfTrack))
        }

        return lines.joined(separator: "\n")
    }

    private func makeScaffold(for card: ABCJingleCard) -> ABCJingleScaffold {
        let target = max(1.0, card.promptSpec.targetDurationSeconds)

        let meter: String
        let defaultLength = "1/8"
        let barCount: Int

        switch card.promptSpec.cueRole {
        case .transition, .emphasisSting:
            meter = "2/4"
            barCount = target <= 2.5 ? 2 : 4
        case .intro, .bumper, .outro:
            meter = "4/4"
            barCount = target <= 3.5 ? 2 : (target <= 6.0 ? 3 : 4)
        }

        let parts = meter.split(separator: "/")
        let num = Int(parts.first ?? "4") ?? 4
        let denom = Int(parts.last ?? "4") ?? 4
        let quarterBeatsPerBar = Double(num) * 4.0 / Double(denom)
        let exactTempo = Int(round((Double(barCount) * quarterBeatsPerBar * 60.0) / target))
        let tempoBPM = min(max(exactTempo, 112), 176)
        let barUnitCount = Int(round((Double(num) / Double(denom)) / (1.0 / 8.0)))

        return ABCJingleScaffold(
            title: card.name,
            meter: meter,
            defaultLength: defaultLength,
            tempoBPM: tempoBPM,
            key: "C",
            barCount: barCount,
            barUnitCount: barUnitCount
        )
    }

    private func formatTimeSignature(_ timeSig: ABCTimeSig) -> String {
        "\(timeSig.num)/\(timeSig.denom)"
    }

    private func makeDeterministicBars(for card: ABCJingleCard, scaffold: ABCJingleScaffold) -> [String] {
        let isEnergetic = matchesAnyKeyword(in: card.promptSpec.promptText + " " + card.promptSpec.styleTags.joined(separator: " "), keywords: ["energetic", "quick", "quicker", "short", "shorter", "bright", "punchy", "uplift", "news"])
        let isSoft = matchesAnyKeyword(in: card.promptSpec.promptText + " " + card.promptSpec.styleTags.joined(separator: " "), keywords: ["soft", "gentle", "calm", "warm", "light"])

        switch scaffold.barUnitCount {
        case 4:
            return makeTwoFourBars(for: card.promptSpec.cueRole, barCount: scaffold.barCount, energetic: isEnergetic, soft: isSoft)
        default:
            return makeFourFourBars(for: card.promptSpec.cueRole, barCount: scaffold.barCount, energetic: isEnergetic, soft: isSoft)
        }
    }

    private func makeTwoFourBars(for role: ABCJingleCueRole, barCount: Int, energetic: Bool, soft: Bool) -> [String] {
        let introBars = energetic
            ? ["G2 A2 |", "c2 G2 |", "A2 B2 |", "c2 z2 |"]
            : ["E2 G2 |", "A2 G2 |", "E2 D2 |", "C2 z2 |"]
        let transitionBars = soft
            ? ["E2 G2 |", "A2 G2 |", "E2 D2 |", "C2 z2 |"]
            : ["G2 B2 |", "A2 G2 |", "E2 D2 |", "C2 z2 |"]
        let bumperBars = ["c2 B2 |", "A2 G2 |", "E2 G2 |", "c2 z2 |"]
        let outroBars = ["G2 A2 |", "B2 G2 |", "E2 D2 |", "C2 z2 |"]
        let stingBars = ["G2 c2 |", "z2 c2 |", "G2 c2 |", "z2 c2 |"]

        let source: [String]
        switch role {
        case .intro: source = introBars
        case .transition: source = transitionBars
        case .bumper: source = bumperBars
        case .outro: source = outroBars
        case .emphasisSting: source = stingBars
        }
        return Array(source.prefix(max(1, min(barCount, source.count))))
    }

    private func makeFourFourBars(for role: ABCJingleCueRole, barCount: Int, energetic: Bool, soft: Bool) -> [String] {
        let introBars = energetic
            ? ["G2 A2 B2 c2 |", "e2 d2 c2 G2 |", "A2 B2 c2 e2 |", "g2 e2 d2 c2 |"]
            : ["E2 G2 A2 G2 |", "E2 D2 C2 G2 |", "A2 G2 E2 D2 |", "C2 E2 D2 C2 |"]
        let transitionBars = soft
            ? ["E2 G2 A2 G2 |", "E2 D2 C2 z2 |", "G2 A2 G2 E2 |", "D2 C2 z2 z2 |"]
            : ["G2 B2 A2 G2 |", "E2 D2 C2 z2 |", "A2 G2 E2 D2 |", "C2 z2 z2 z2 |"]
        let bumperBars = ["c2 B2 A2 G2 |", "E2 G2 A2 B2 |", "c2 A2 G2 E2 |", "D2 E2 G2 c2 |"]
        let outroBars = ["G2 A2 B2 G2 |", "E2 G2 A2 G2 |", "E2 D2 C2 G2 |", "C2 z2 z2 z2 |"]
        let stingBars = ["G2 c2 G2 c2 |", "z2 z2 c2 z2 |", "G2 c2 e2 c2 |", "z2 z2 c2 z2 |"]

        let source: [String]
        switch role {
        case .intro: source = introBars
        case .transition: source = transitionBars
        case .bumper: source = bumperBars
        case .outro: source = outroBars
        case .emphasisSting: source = stingBars
        }
        return Array(source.prefix(max(1, min(barCount, source.count))))
    }

    private func matchesAnyKeyword(in text: String, keywords: [String]) -> Bool {
        let lowercased = text.lowercased()
        return keywords.contains { lowercased.contains($0) }
    }
}
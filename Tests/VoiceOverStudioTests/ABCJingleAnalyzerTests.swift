import XCTest
@testable import VoiceOverStudio

final class ABCJingleAnalyzerTests: XCTestCase {
    private func analyze(_ abc: String) throws -> ABCJingleAnalysis {
        let tune = try ABCParser().parse(abc)
        return ABCJingleAnalyzer().analyze(tune)
    }

    func testAnalyzerComputesDurationAndTailForSimpleCue() throws {
        let analysis = try analyze("""
        X:1
        T:SimpleCue
        M:4/4
        L:1/8
        Q:120
        K:C
        C z2
        """)

        XCTAssertEqual(analysis.estimatedDurationBeats, 1.5, accuracy: 0.000001)
        XCTAssertEqual(analysis.estimatedDurationSeconds, 0.75, accuracy: 0.000001)
        XCTAssertEqual(analysis.tailDurationBeats, 0.5, accuracy: 0.000001)
        XCTAssertEqual(analysis.tailDurationSeconds, 0.25, accuracy: 0.000001)
        XCTAssertEqual(analysis.soundingEventCount, 1)
    }

    func testAnalyzerDetectsDenseTextureAndLowRangeMasking() throws {
        let analysis = try analyze("""
        X:1
        T:DenseLowCue
        M:4/4
        L:1/8
        K:C
        V:1
        [C,E,G,B]2
        V:2
        C,,2
        """)

        XCTAssertGreaterThanOrEqual(analysis.maxSimultaneousNotes, 5)
        XCTAssertEqual(analysis.lowestMIDINote, 24)
        XCTAssertTrue(analysis.warnings.contains { $0.code == .denseTexture })
        XCTAssertTrue(analysis.warnings.contains { $0.code == .lowRangeMasking })
    }

    func testAnalyzerFlagsBusyPercussionForSpeechSafety() throws {
        let analysis = try analyze("""
        X:1
        T:BusyDrums
        %%MIDI percussion on
        M:4/4
        L:1/16
        Q:1/4=120
        K:C
        C D E F G A B c
        """)

        XCTAssertEqual(analysis.percussionVoiceCount, 1)
        XCTAssertTrue(analysis.warnings.contains { $0.code == .busyPercussion })
    }

    func testAnalyzerFlagsLongCueAndLongTail() throws {
        let analysis = try analyze("""
        X:1
        T:LongCue
        M:4/4
        L:1/1
        Q:1/4=60
        K:C
        C2
        """)

        XCTAssertEqual(analysis.estimatedDurationSeconds, 8.0, accuracy: 0.000001)
        XCTAssertEqual(analysis.tailDurationSeconds, 8.0, accuracy: 0.000001)
        XCTAssertTrue(analysis.warnings.contains { $0.code == .longTail })
        XCTAssertFalse(analysis.warnings.contains { $0.code == .longCue })
    }

    func testAnalyzerIntegratesTempoChangesIntoDurationEstimate() throws {
        var tune = ABCTune()
        tune.defaultTempo = ABCTempo(bpm: 120)
        tune.defaultTimeSig = ABCTimeSig(num: 4, denom: 4)
        tune.defaultUnit = ABCFraction(1, 8)
        tune.voices[1] = ABCVoiceContext(
            id: 1,
            name: "1",
            key: tune.defaultKey,
            timeSig: tune.defaultTimeSig,
            unitLen: tune.defaultUnit,
            transpose: 0,
            octaveShift: 0,
            instrument: 0,
            channel: -1,
            velocity: 80,
            percussion: false
        )
        tune.features = [
            ABCFeature(
                voiceID: 1,
                timestamp: 0.0,
                lineNumber: 1,
                data: .note(ABCNote(pitch: "C", accidental: 0, octave: 0, duration: ABCFraction(1, 8), midiNote: 48, velocity: 80, isTied: false))
            ),
            ABCFeature(
                voiceID: 1,
                timestamp: 1.0 / 8.0,
                lineNumber: 2,
                data: .tempo(ABCTempo(bpm: 60))
            ),
            ABCFeature(
                voiceID: 1,
                timestamp: 1.0 / 8.0,
                lineNumber: 3,
                data: .note(ABCNote(pitch: "C", accidental: 0, octave: 0, duration: ABCFraction(1, 8), midiNote: 48, velocity: 80, isTied: false))
            )
        ]
        let analysis = ABCJingleAnalyzer().analyze(tune)

        XCTAssertEqual(analysis.estimatedDurationBeats, 1.0, accuracy: 0.000001)
        XCTAssertEqual(analysis.estimatedDurationSeconds, 0.75, accuracy: 0.000001)
    }

    func testAnalyzerMeasuresRepeatedTwoVoicePodcastIntroAtTwentyFourSeconds() throws {
        let analysis = try analyze("""
        X:1
        T:Podcast Intro Jingle
        C:Adaptive Collaborator
        M:4/4
        L:1/8
        Q:1/4=120
        K:C
        %%score (V1 V2)
        % Lead Melody
        V:1 name="Lead"

        |: G2 c2 e2 g2 | f2 d2 B2 G2 | G2 c2 e2 g2 | f e d c G4 |
        |  e g c'2 b a g f | e2 d2 c4 :|
        % Rhythmic Bassline
        V:2 name="Bass" clef=bass

        |: C,2 G,2 E,2 G,2 | G,,2 D,2 G,2 D,2 | C,2 G,2 E,2 G,2 | G,,2 D,2 G,2 D,2 |
        |  A,,2 E,2 F,,2 C,2 | G,,2 G,,2 C,4 :|
        """)

        XCTAssertEqual(analysis.voiceCount, 2)
        XCTAssertEqual(analysis.estimatedDurationBeats, 48.0, accuracy: 0.000001)
        XCTAssertEqual(analysis.estimatedDurationSeconds, 24.0, accuracy: 0.000001)
        XCTAssertEqual(analysis.tailDurationSeconds, 1.0, accuracy: 0.000001)
    }
}
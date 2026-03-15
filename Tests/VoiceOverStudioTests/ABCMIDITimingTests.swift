import XCTest
@testable import VoiceOverStudio

final class ABCMIDITimingTests: XCTestCase {
    private func parse(_ abc: String) throws -> ABCTune {
        try ABCParser().parse(abc)
    }

    private func generate(_ abc: String) throws -> [ABCMIDITrack] {
        let tune = try parse(abc)
        return ABCMIDIGenerator().generateMIDI(tune)
    }

    private func firstNoteTrack(_ tracks: [ABCMIDITrack]) -> ABCMIDITrack? {
        tracks.first { $0.type == .notes }
    }

    private func tempoTrack(_ tracks: [ABCMIDITrack]) -> ABCMIDITrack? {
        tracks.first { $0.type == .tempo }
    }

    private func track(for voiceID: Int, in tracks: [ABCMIDITrack]) -> ABCMIDITrack? {
        tracks.first { $0.type == .notes && $0.voiceNumber == voiceID }
    }

    func testMIDITimingUsesSustainedDurationForTiedNotes() throws {
        let tracks = try generate("""
        X:1
        T:TieTiming
        M:4/4
        L:1/8
        K:C
        C-C
        """)

        let noteTrack = try XCTUnwrap(firstNoteTrack(tracks))
        let noteOns = noteTrack.events.filter { $0.type == .noteOn }
        let noteOffs = noteTrack.events.filter { $0.type == .noteOff }

        XCTAssertEqual(noteOns.count, 1)
        XCTAssertEqual(noteOffs.count, 1)
        XCTAssertEqual(noteOns[0].timestamp, 0.0, accuracy: 0.000001)
        XCTAssertEqual(noteOffs[0].timestamp, 1.0, accuracy: 0.000001)
    }

    func testGuitarChordsOnlyPlayWhenEnabled() throws {
        let abc = """
        X:1
        T:ChordFlag
        M:4/4
        L:1/8
        K:C
        "C" C
        """

        unsetenv("ED_PLAY_CHORDS")
        let tracksOff = ABCMIDIGenerator().generateMIDI(try parse(abc))
        setenv("ED_PLAY_CHORDS", "1", 1)
        let tracksOn = ABCMIDIGenerator().generateMIDI(try parse(abc))
        unsetenv("ED_PLAY_CHORDS")

        let offTrack = try XCTUnwrap(firstNoteTrack(tracksOff))
        let onTrack = try XCTUnwrap(firstNoteTrack(tracksOn))

        XCTAssertEqual(offTrack.events.filter { $0.type == .noteOn }.count, 1)
        XCTAssertEqual(offTrack.events.filter { $0.type == .noteOff }.count, 1)
        XCTAssertEqual(onTrack.events.filter { $0.type == .noteOn }.count, 4)
        XCTAssertEqual(onTrack.events.filter { $0.type == .noteOff }.count, 4)
    }

    func testMIDITimingPreservesBrokenRhythmBoundaries() throws {
        let tracks = try generate("""
        X:1
        T:BrokenTiming
        M:4/4
        L:1/8
        K:C
        C>D
        """)
        let noteTrack = try XCTUnwrap(firstNoteTrack(tracks))
        let noteOns = noteTrack.events.filter { $0.type == .noteOn }
        let noteOffs = noteTrack.events.filter { $0.type == .noteOff }

        XCTAssertEqual(noteOns.count, 2)
        XCTAssertEqual(noteOffs.count, 2)
        XCTAssertEqual(noteOns[0].timestamp, 0.0, accuracy: 0.000001)
        XCTAssertEqual(noteOns[1].timestamp, 0.75, accuracy: 0.000001)
        XCTAssertEqual(noteOffs[0].timestamp, 0.75, accuracy: 0.000001)
        XCTAssertEqual(noteOffs[1].timestamp, 1.0, accuracy: 0.000001)
    }

    func testNoteTrackEOTIncludesTrailingRestDuration() throws {
        let tracks = try generate("""
        X:1
        T:RestEOT
        M:4/4
        L:1/8
        K:C
        C z2
        """)
        let noteTrack = try XCTUnwrap(firstNoteTrack(tracks))
        let eot = try XCTUnwrap(noteTrack.events.first { $0.type == .metaEndOfTrack })
        XCTAssertEqual(eot.timestamp, 1.5, accuracy: 0.000001)
    }

    func testChordNotesEndTogetherAndEOTMatchesChordEnd() throws {
        let tracks = try generate("""
        X:1
        T:ChordTiming
        M:4/4
        L:1/8
        K:C
        [CEG]2
        """)
        let noteTrack = try XCTUnwrap(firstNoteTrack(tracks))
        let noteOns = noteTrack.events.filter { $0.type == .noteOn }
        let noteOffs = noteTrack.events.filter { $0.type == .noteOff }
        let eot = try XCTUnwrap(noteTrack.events.first { $0.type == .metaEndOfTrack })

        XCTAssertEqual(noteOns.count, 3)
        XCTAssertEqual(noteOffs.count, 3)
        XCTAssertTrue(noteOffs.allSatisfy { abs($0.timestamp - 1.0) < 0.000001 })
        XCTAssertEqual(eot.timestamp, 1.0, accuracy: 0.000001)
    }

    func testTempoTrackEOTReachesEndOfMusicalTimeline() throws {
        let tracks = try generate("""
        X:1
        T:TempoEOT
        M:4/4
        L:1/8
        K:C
        C z2
        """)
        let tempo = try XCTUnwrap(tempoTrack(tracks))
        let eot = try XCTUnwrap(tempo.events.first { $0.type == .metaEndOfTrack })
        XCTAssertEqual(eot.timestamp, 1.5, accuracy: 0.000001)
    }

    func testMultiVoiceOverlapUsesSeparateChannelsAndAlignedStarts() throws {
        let tracks = try generate("""
        X:1
        T:VoiceOverlap
        M:4/4
        L:1/8
        K:C
        V:1
        C
        V:2
        E
        """)
        let v1 = try XCTUnwrap(track(for: 1, in: tracks))
        let v2 = try XCTUnwrap(track(for: 2, in: tracks))

        XCTAssertNotEqual(v1.channel, v2.channel)
        XCTAssertEqual(v1.events.first { $0.type == .noteOn }?.timestamp ?? -1, 0.0, accuracy: 0.000001)
        XCTAssertEqual(v2.events.first { $0.type == .noteOn }?.timestamp ?? -1, 0.0, accuracy: 0.000001)
    }

    func testTempoChangesAreEmittedAtExactFeatureBoundaries() throws {
        let tracks = try generate("""
        X:1
        T:TempoBoundaries
        M:4/4
        L:1/8
        Q:120
        K:C
        C
        Q:180
        D
        """)
        let tempo = try XCTUnwrap(tempoTrack(tracks))
        let tempoEvents = tempo.events.filter { $0.type == .metaTempo }

        XCTAssertGreaterThanOrEqual(tempoEvents.count, 2)
        XCTAssertEqual(tempoEvents[0].timestamp, 0.0, accuracy: 0.000001)
        XCTAssertEqual(tempoEvents[1].timestamp, 0.5, accuracy: 0.000001)
    }

    func testRapidSuccessiveTempoChangesKeepMonotonicBoundaries() throws {
        let tracks = try generate("""
        X:1
        T:RapidTempo
        M:4/4
        L:1/8
        Q:120
        K:C
        C
        Q:132
        D
        Q:144
        E
        Q:156
        F
        """)

        let tempo = try XCTUnwrap(tempoTrack(tracks))
        let timestamps = tempo.events
            .filter { $0.type == .metaTempo }
            .map(\.timestamp)

        XCTAssertGreaterThanOrEqual(timestamps.count, 4)
        XCTAssertEqual(timestamps[0], 0.0, accuracy: 0.000001)
        XCTAssertEqual(timestamps[1], 0.5, accuracy: 0.000001)
        XCTAssertEqual(timestamps[2], 1.0, accuracy: 0.000001)
        XCTAssertEqual(timestamps[3], 1.5, accuracy: 0.000001)

        for index in 1..<timestamps.count {
            XCTAssertGreaterThanOrEqual(timestamps[index], timestamps[index - 1])
        }
    }

    func testThreeVoiceOverlapKeepsDistinctChannelsAndSynchronizedStarts() throws {
        let tracks = try generate("""
        X:1
        T:ThreeVoiceOverlap
        M:4/4
        L:1/8
        K:C
        V:1
        C
        V:2
        E
        V:3
        G
        """)
        let v1 = try XCTUnwrap(track(for: 1, in: tracks))
        let v2 = try XCTUnwrap(track(for: 2, in: tracks))
        let v3 = try XCTUnwrap(track(for: 3, in: tracks))

        XCTAssertNotEqual(v1.channel, v2.channel)
        XCTAssertNotEqual(v1.channel, v3.channel)
        XCTAssertNotEqual(v2.channel, v3.channel)
        XCTAssertEqual(v1.events.first { $0.type == .noteOn }?.timestamp ?? -1, 0.0, accuracy: 0.000001)
        XCTAssertEqual(v2.events.first { $0.type == .noteOn }?.timestamp ?? -1, 0.0, accuracy: 0.000001)
        XCTAssertEqual(v3.events.first { $0.type == .noteOn }?.timestamp ?? -1, 0.0, accuracy: 0.000001)
    }

    func testBodyLevelVoiceAttributesStillSwitchActiveVoiceForParallelTiming() throws {
        let tracks = try generate("""
        X:1
        T:VoiceAttributesSwitch
        M:4/4
        L:1/8
        Q:1/4=120
        K:C
        V:1 name="Lead"
        C2 D2 |
        V:2 name="Bass" clef=bass
        C,2 D,2 |
        """)

        let v1 = try XCTUnwrap(track(for: 1, in: tracks))
        let v2 = try XCTUnwrap(track(for: 2, in: tracks))

        XCTAssertEqual(v1.events.first { $0.type == .noteOn }?.timestamp ?? -1, 0.0, accuracy: 0.000001)
        XCTAssertEqual(v2.events.first { $0.type == .noteOn }?.timestamp ?? -1, 0.0, accuracy: 0.000001)
        XCTAssertEqual(v1.events.first { $0.type == .metaEndOfTrack }?.timestamp ?? -1, 2.0, accuracy: 0.000001)
        XCTAssertEqual(v2.events.first { $0.type == .metaEndOfTrack }?.timestamp ?? -1, 2.0, accuracy: 0.000001)
    }

    func testVoiceInstrumentAttributesMapToPerTrackProgramChanges() throws {
        let tracks = try generate("""
        X:1
        T:VoiceInstruments
        M:4/4
        L:1/8
        K:C
        V:1 name="Lead" instrument=40
        V:2 name="Harmony" instrument=41
        [V:1] C
        [V:2] E
        """)
        let v1 = try XCTUnwrap(track(for: 1, in: tracks))
        let v2 = try XCTUnwrap(track(for: 2, in: tracks))

        XCTAssertEqual(v1.events.first { $0.type == .programChange }?.data1, 40)
        XCTAssertEqual(v2.events.first { $0.type == .programChange }?.data1, 41)
    }

    func testExplicitMIDIDefaultChannelAppliesToFirstCreatedVoice() throws {
        let tune = try parse("""
        X:1
        T:DefaultChannel
        %%MIDI channel 4
        M:4/4
        L:1/8
        K:C
        C
        """)
        let tracks = ABCMIDIGenerator().generateMIDI(tune)

        XCTAssertEqual(tune.defaultChannel, 3)
        XCTAssertEqual(tune.voices[1]?.channel, 3)
        XCTAssertEqual(firstNoteTrack(tracks)?.channel, 3)
    }

    func testMIDIChannelDirectiveTargetsCurrentVoiceOnly() throws {
        let tracks = try generate("""
        X:1
        T:VoiceSpecificChannel
        M:4/4
        L:1/8
        K:C
        V:1
        %%MIDI channel 6
        C
        V:2
        E
        """)

        let v1 = try XCTUnwrap(track(for: 1, in: tracks))
        let v2 = try XCTUnwrap(track(for: 2, in: tracks))

        XCTAssertEqual(v1.channel, 5)
        XCTAssertNotEqual(v1.channel, v2.channel)
        XCTAssertNotEqual(v2.channel, 9)
    }

    func testMIDIPercussionDirectiveForcesChannelTenAndKeepsKitProgram() throws {
        let tune = try parse("""
        X:1
        T:PercussionVoice
        M:4/4
        L:1/8
        K:C
        V:1 name="Drums" instrument=16
        %%MIDI percussion on
        C
        """)
        let tracks = ABCMIDIGenerator().generateMIDI(tune)

        XCTAssertEqual(tune.voices[1]?.percussion, true)
        XCTAssertEqual(tune.voices[1]?.channel, 9)

        let drumTrack = try XCTUnwrap(track(for: 1, in: tracks))
        XCTAssertEqual(drumTrack.channel, 9)
        XCTAssertEqual(drumTrack.events.first { $0.type == .programChange }?.data1, 16)
        XCTAssertEqual(drumTrack.events.first { $0.type == .noteOn }?.channel, 9)
    }

    func testDefaultPercussionDirectiveAppliesToLaterCreatedVoice() throws {
        let tune = try parse("""
        X:1
        T:DefaultPercussion
        %%MIDI percussion on
        %%MIDI program 24
        M:4/4
        L:1/8
        K:C
        C
        """)
        let tracks = ABCMIDIGenerator().generateMIDI(tune)

        XCTAssertEqual(tune.defaultChannel, 9)
        XCTAssertEqual(tune.defaultPercussion, true)
        XCTAssertEqual(tune.voices[1]?.channel, 9)
        XCTAssertEqual(tune.voices[1]?.percussion, true)
        XCTAssertEqual(tune.voices[1]?.instrument, 24)

        let drumTrack = try XCTUnwrap(firstNoteTrack(tracks))
        XCTAssertEqual(drumTrack.channel, 9)
        XCTAssertEqual(drumTrack.events.first { $0.type == .programChange }?.data1, 24)
    }

    func testQuotedMultiWordVoiceNamesKeepProgramMapping() throws {
        let tune = try parse("""
        X:1
        T:QuotedNamesPrograms
        M:4/4
        L:1/8
        K:C
        V:1 name="Soprano Lead" instrument=40
        V:2 name="Alto Harmony" instrument=41
        [V:1] C
        [V:2] E
        """)
        let tracks = ABCMIDIGenerator().generateMIDI(tune)

        XCTAssertEqual(tune.voices[1]?.name, "Soprano Lead")
        XCTAssertEqual(tune.voices[2]?.name, "Alto Harmony")

        let v1 = try XCTUnwrap(track(for: 1, in: tracks))
        let v2 = try XCTUnwrap(track(for: 2, in: tracks))

        XCTAssertEqual(v1.events.first { $0.type == .programChange }?.data1, 40)
        XCTAssertEqual(v2.events.first { $0.type == .programChange }?.data1, 41)
    }
}
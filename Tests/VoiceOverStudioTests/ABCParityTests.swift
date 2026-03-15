import XCTest
@testable import VoiceOverStudio

final class ABCParityTests: XCTestCase {
    func testRepeatExpansionDuplicatesSimpleSection() throws {
        let abc = """
        X:1
        T:Repeat
        M:4/4
        L:1/8
        K:C
        |: C D :|
        """

        let expanded = ABCRepeatExpander.expandABCRepeats(abc)
        XCTAssertTrue(expanded.contains("C D C D"))
    }

    func testParserRequiresKeyFieldLikeABC() throws {
        let abc = """
        X:1
        T:MissingKey
        M:4/4
        L:1/8
        C D
        """

        let parser = ABCParser()
        XCTAssertThrowsError(try parser.parse(abc))
    }

    func testHeaderContinuationAppendsTitle() throws {
        let abc = """
        X:1
        T:Inline
        +: Voice Test
        M:4/4
        L:1/8
        K:C
        C
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        XCTAssertEqual(tune.title, "Inline Voice Test")
    }

    func testTiedNotesMergeIntoSingleSustainedNote() throws {
        let abc = """
        X:1
        T:Ties
        M:4/4
        L:1/8
        K:C
        C-C D
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let notes = tune.features.compactMap {
            if case let .note(note) = $0.data { return ($0.timestamp, note) }
            return nil
        }

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].1.duration, ABCFraction(1, 4))
        XCTAssertEqual(notes[1].0, 0.25, accuracy: 0.000001)
    }

    func testKeySignatureAdjustsPitch() throws {
        let parser = ABCParser()
        let tuneC = try parser.parse("""
        X:1
        T:KeyC
        M:4/4
        L:1/8
        K:C
        F
        """)
        let tuneG = try parser.parse("""
        X:1
        T:KeyG
        M:4/4
        L:1/8
        K:G
        F
        """)

        let noteC = tuneC.features.compactMap {
            if case let .note(note) = $0.data { return note.midiNote }
            return nil
        }.first
        let noteG = tuneG.features.compactMap {
            if case let .note(note) = $0.data { return note.midiNote }
            return nil
        }.first

        XCTAssertNotNil(noteC)
        XCTAssertNotNil(noteG)
        XCTAssertEqual(noteG, noteC.map { $0 + 1 })
    }

    func testMultiVoiceTimekeepingRestoresPerVoiceTimeline() throws {
        let abc = """
        X:1
        T:Voices
        M:4/4
        L:1/8
        K:C
        V:1
        C D
        V:2
        E
        V:1
        F
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let noteFeatures = tune.features.filter {
            if case .note = $0.data { return true }
            return false
        }

        let voice1 = noteFeatures.filter { $0.voiceID == 1 }
        let voice2 = noteFeatures.filter { $0.voiceID == 2 }

        XCTAssertEqual(voice1.count, 3)
        XCTAssertEqual(voice2.count, 1)
        XCTAssertEqual(voice1[0].timestamp, 0.0, accuracy: 0.000001)
        XCTAssertEqual(voice1[1].timestamp, 1.0 / 8.0, accuracy: 0.000001)
        XCTAssertEqual(voice1[2].timestamp, 2.0 / 8.0, accuracy: 0.000001)
        XCTAssertEqual(voice2[0].timestamp, 0.0, accuracy: 0.000001)
    }

    func testVoiceDefinitionSupportsQuotedMultiwordName() throws {
        let abc = """
        X:1
        T:VoiceNameQuoted
        M:4/4
        L:1/8
        K:C
        V:1 name="Soprano Lead" instrument=40
        [V:1] C
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        XCTAssertEqual(tune.voices[1]?.name, "Soprano Lead")
        XCTAssertEqual(tune.voices[1]?.instrument, 40)
    }

    func testDottedNoteDurationParses() throws {
        let abc = """
        X:1
        T:Dotted
        M:4/4
        L:1/8
        K:C
        C. D
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let firstNote = tune.features.compactMap {
            if case let .note(note) = $0.data { return note }
            return nil
        }.first

        XCTAssertEqual(firstNote?.duration, ABCFraction(3, 16))
    }

    func testGuitarChordSymbolsEmitGChordFeature() throws {
        let abc = """
        X:1
        T:GChord
        M:4/4
        L:1/8
        K:C
        "C" C
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let gChord = tune.features.compactMap {
            if case let .gchord(chord) = $0.data { return ($0.timestamp, chord) }
            return nil
        }.first

        XCTAssertNotNil(gChord)
        XCTAssertEqual(gChord?.1.symbol, "C")
        XCTAssertEqual(gChord?.1.rootNote, 48)
        XCTAssertEqual(gChord?.1.duration, ABCFraction(1, 8))
        XCTAssertEqual(gChord?.0 ?? -1.0, 0.0, accuracy: 0.000001)
    }

    func testMidTuneKeyChangeEmitsFeatureAndAffectsFollowingNote() throws {
        let abc = """
        X:1
        T:MidKey
        M:4/4
        L:1/8
        K:C
        F
        K:G
        F
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)

        let notes = tune.features.compactMap {
            if case let .note(note) = $0.data { return note.midiNote }
            return nil
        }
        let keyChanges = tune.features.filter {
            if case .key = $0.data { return $0.timestamp > 0 }
            return false
        }

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[1], notes[0] + 1)
        XCTAssertFalse(keyChanges.isEmpty)
    }

    func testBarAccidentalCarriesWithinBarThenResets() throws {
        let abc = """
        X:1
        T:BarAccidentals
        M:4/4
        L:1/8
        K:C
        ^F F | F
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let notes = tune.features.compactMap {
            if case let .note(note) = $0.data { return note.midiNote }
            return nil
        }

        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes[0], notes[1])
        XCTAssertEqual(notes[2] + 1, notes[1])
    }

    func testTripletScalesNextThreeNotes() throws {
        let abc = """
        X:1
        T:TupletTriplet
        M:4/4
        L:1/8
        K:C
        (3ABC
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let notes = tune.features.compactMap {
            if case let .note(note) = $0.data { return ($0.timestamp, note.duration) }
            return nil
        }

        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes[0].1, ABCFraction(1, 12))
        XCTAssertEqual(notes[1].1, ABCFraction(1, 12))
        XCTAssertEqual(notes[2].1, ABCFraction(1, 12))
        XCTAssertEqual(notes[1].0 - notes[0].0, 1.0 / 12.0, accuracy: 0.000001)
        XCTAssertEqual(notes[2].0 - notes[1].0, 1.0 / 12.0, accuracy: 0.000001)
    }

    func testBracketedInlineFieldsAffectSubsequentParsing() throws {
        let abc = """
        X:1
        T:InlineBracketFields
        M:4/4
        L:1/8
        K:C
        F [K:G] F [L:1/16] C2 [Q:150] [M:3/4] D
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)

        let notes = tune.features.compactMap {
            if case let .note(note) = $0.data { return note }
            return nil
        }
        let sawTempo = tune.features.contains {
            if case let .tempo(tempo) = $0.data { return tempo.bpm == 150 }
            return false
        }
        let sawTime = tune.features.contains {
            if case let .time(time) = $0.data { return time.num == 3 && time.denom == 4 }
            return false
        }
        let sawKeyChange = tune.features.contains {
            if case let .key(key) = $0.data { return $0.timestamp > 0 && key.sharps == 1 }
            return false
        }

        XCTAssertEqual(notes.count, 4)
        XCTAssertEqual(notes[1].midiNote, notes[0].midiNote + 1)
        XCTAssertEqual(notes[0].duration, ABCFraction(1, 8))
        XCTAssertEqual(notes[2].duration, ABCFraction(1, 8))
        XCTAssertTrue(sawTempo)
        XCTAssertTrue(sawTime)
        XCTAssertTrue(sawKeyChange)
    }

    func testMalformedChordRecoversAndContinuesParsing() throws {
        let abc = """
        X:1
        T:MalformedChord
        M:4/4
        L:1/8
        K:C
        [CE D
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let noteCount = tune.features.reduce(into: 0) { result, feature in
            if case .note = feature.data { result += 1 }
        }

        XCTAssertGreaterThanOrEqual(noteCount, 1)
    }

    func testBrokenRhythmAdjustsPairedDurations() throws {
        let abc = """
        X:1
        T:BrokenRhythm
        M:4/4
        L:1/8
        K:C
        C>D
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let notes = tune.features.compactMap {
            if case let .note(note) = $0.data { return ($0.timestamp, note.duration) }
            return nil
        }

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].1, ABCFraction(3, 16))
        XCTAssertEqual(notes[1].1, ABCFraction(1, 16))
        XCTAssertEqual(notes[1].0 - notes[0].0, 3.0 / 16.0, accuracy: 0.000001)
    }

    func testTieAcrossBarlineMergesSustainedNote() throws {
        let abc = """
        X:1
        T:TieAcrossBar
        M:4/4
        L:1/8
        K:C
        C-|C D
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let notes = tune.features.compactMap {
            if case let .note(note) = $0.data { return note }
            return nil
        }

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].duration, ABCFraction(1, 4))
    }

    func testSectionStyleInlineNamedVoicesParseIntoSeparateTimelines() throws {
        let abc = """
        X:1
        T:Inline Voice Test
        M:4/4
        L:1/4
        Q:120
        K:C
        [V:melody]
        C D E F |
        [V:bass]
        G A B c |
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)

        XCTAssertEqual(tune.voices.count, 2)
        let melodyID = tune.voices.first(where: { $0.value.name == "melody" })?.key
        let bassID = tune.voices.first(where: { $0.value.name == "bass" })?.key

        XCTAssertNotNil(melodyID)
        XCTAssertNotNil(bassID)
        XCTAssertNotEqual(melodyID, bassID)

        let melodyNotes = tune.features.filter {
            if case .note = $0.data { return $0.voiceID == melodyID }
            return false
        }
        let bassNotes = tune.features.filter {
            if case .note = $0.data { return $0.voiceID == bassID }
            return false
        }

        XCTAssertEqual(melodyNotes.count, 4)
        XCTAssertEqual(bassNotes.count, 4)
    }

    func testContinuationOnTempoLineEmitsWarningAndDoesNotModifyTempo() throws {
        let abc = """
        X:1
        T:TempoContinuation
        M:4/4
        L:1/8
        Q:120
        +:150
        K:C
        C
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)

        XCTAssertEqual(tune.defaultTempo.bpm, 120)
        XCTAssertGreaterThanOrEqual(parser.warnings.count, 1)
    }

    func testLeadingContinuationLineEmitsWarning() throws {
        let abc = """
        +:orphan continuation
        X:1
        T:LeadingContinuation
        M:4/4
        L:1/8
        K:C
        C
        """

        let parser = ABCParser()
        _ = try parser.parse(abc)
        XCTAssertGreaterThanOrEqual(parser.warnings.count, 1)
    }

    func testValidHistoryContinuationDoesNotEmitWarning() throws {
        let abc = """
        X:1
        T:HistoryContinuation
        H:first line
        +:second line
        M:4/4
        L:1/8
        K:C
        C
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        XCTAssertEqual(parser.warnings.count, 0)
        XCTAssertEqual(tune.history, "first line second line")
    }

    func testStringMetadataFieldsAreRetainedAndContinuable() throws {
        let abc = """
        X:1
        T:Meta
        C:Jane Doe
        O:Ireland
        R:reel
        N:first
        +:second
        M:4/4
        L:1/8
        K:C
        C
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        XCTAssertEqual(tune.composer, "Jane Doe")
        XCTAssertEqual(tune.origin, "Ireland")
        XCTAssertEqual(tune.rhythm, "reel")
        XCTAssertEqual(tune.notes, "first second")
        XCTAssertEqual(parser.warnings.count, 0)
    }

    func testLyricsFieldsAreRetained() throws {
        let abc = """
        X:1
        T:Lyrics
        W:line one
        w:do re mi
        M:4/4
        L:1/8
        K:C
        C D E
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        XCTAssertEqual(tune.words, "line one")
        XCTAssertEqual(tune.alignedWords, "do re mi")
    }

    func testAlignedLyricsContinuationAppends() throws {
        let abc = """
        X:1
        T:LyricsContinuation
        w:fa la
        +:la
        M:4/4
        L:1/8
        K:C
        C D E
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        XCTAssertEqual(tune.alignedWords, "fa la la")
        XCTAssertEqual(parser.warnings.count, 0)
    }

    func testGraceNotesAreTimingNeutral() throws {
        let abc = """
        X:1
        T:GraceNeutral
        M:4/4
        L:1/8
        K:C
        C{g}D
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let timestamps = tune.features.compactMap {
            if case .note = $0.data { return $0.timestamp }
            return nil
        }

        XCTAssertEqual(timestamps.count, 2)
        XCTAssertEqual(timestamps[0], 0.0, accuracy: 0.000001)
        XCTAssertEqual(timestamps[1], 1.0 / 8.0, accuracy: 0.000001)
    }

    func testAcciaccaturaGraceSyntaxDoesNotBlockNoteParse() throws {
        let abc = """
        X:1
        T:Acciaccatura
        M:4/4
        L:1/8
        K:C
        {/g}C
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let noteCount = tune.features.reduce(into: 0) { result, feature in
            if case .note = feature.data { result += 1 }
        }
        XCTAssertEqual(noteCount, 1)
    }

    func testBrokenRhythmWithInterveningGraceIsParsed() throws {
        let abc = """
        X:1
        T:GraceBrokenRhythm
        M:4/4
        L:1/8
        K:C
        A{g}<A
        """

        let parser = ABCParser()
        let tune = try parser.parse(abc)
        let durations = tune.features.compactMap {
            if case let .note(note) = $0.data { return note.duration.toDouble() }
            return nil
        }

        XCTAssertEqual(durations.count, 2)
        XCTAssertEqual(durations[0], 1.0 / 16.0, accuracy: 0.000001)
        XCTAssertEqual(durations[1], 3.0 / 16.0, accuracy: 0.000001)
    }
}
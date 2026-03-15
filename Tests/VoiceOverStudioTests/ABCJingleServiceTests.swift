import Foundation
import XCTest
@testable import VoiceOverStudio

final class ABCJingleServiceTests: XCTestCase {
    private let abc = """
    X:1
    T:ServiceCue
    %%MIDI percussion on
    M:4/4
    L:1/8
    Q:120
    K:C
    C z2
    """

    func testServiceValidateReturnsTuneAndAnalysis() throws {
        let result = try ABCJingleService().validate(abcSource: abc)

        XCTAssertEqual(result.tune.title, "ServiceCue")
        XCTAssertEqual(result.analysis.percussionVoiceCount, 1)
        XCTAssertEqual(result.analysis.estimatedDurationSeconds, 0.75, accuracy: 0.000001)
        XCTAssertTrue(result.analysis.warnings.isEmpty)
    }

    func testServiceRenderBuildsTracksAndMIDIData() throws {
        let result = try ABCJingleService().render(abcSource: abc)

        XCTAssertEqual(result.midiTracks.count, 2)
        XCTAssertEqual(String(decoding: result.midiData.prefix(4), as: UTF8.self), "MThd")
        XCTAssertTrue(result.midiData.count > 14)
        XCTAssertEqual(result.midiTracks.last?.channel, 9)
    }

    func testServiceExportWritesMIDIFile() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputURL = tempDirectory.appendingPathComponent("jingle.mid")

        let result = try ABCJingleService().exportMIDI(abcSource: abc, to: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let writtenData = try Data(contentsOf: outputURL)
        XCTAssertEqual(writtenData, result.midiData)
        XCTAssertEqual(String(decoding: writtenData.prefix(4), as: UTF8.self), "MThd")
    }

    func testServiceFlagsLargeDurationMismatch() {
        let analysis = ABCJingleAnalysis(
            estimatedDurationBeats: 48,
            estimatedDurationSeconds: 24.0,
            tailDurationBeats: 2,
            tailDurationSeconds: 1.0,
            voiceCount: 1,
            melodicVoiceCount: 1,
            percussionVoiceCount: 0,
            soundingEventCount: 10,
            maxSimultaneousNotes: 1,
            lowestMIDINote: 60,
            highestMIDINote: 72,
            warnings: []
        )

        let feedback = ABCJingleService().durationFeedback(for: analysis, targetDurationSeconds: 3.0)
        XCTAssertNotNil(feedback)
        XCTAssertTrue(feedback?.contains("Cue is too long") == true)
        XCTAssertTrue(feedback?.contains("Q:160") == true)
    }

    func testServiceFlagsOverfullBarStructure() throws {
        let abc = """
        X:1
        T:BadBar
        M:4/4
        L:1/8
        Q:1/4=140
        K:C
        C4 E4 G4 C4 |
        """

        let validation = try ABCJingleService().validate(abcSource: abc)
        let feedback = ABCJingleService().structureFeedback(for: validation.tune)
        XCTAssertNotNil(feedback)
        XCTAssertTrue(feedback?.contains("too long") == true)
        XCTAssertTrue(feedback?.contains("4/4") == true)
    }

    func testServiceGeneratesDeterministicABCThatValidates() throws {
        let card = ABCJingleCard(
            name: "Podcast Intro",
            promptSpec: ABCJinglePromptSpec(
                promptText: "Create a short spoken-word-safe podcast intro with a clear cadence ending. Make it quicker, shorter, energetic.",
                cueRole: .intro,
                targetDurationSeconds: 3.0,
                styleTags: ["spoken-word", "clear", "friendly"],
                includePercussion: false,
                instrumentationNotes: "Use light mallet or pluck tones."
            )
        )

        let abc = ABCJingleService().generateDeterministicABC(for: card)
        let validation = try ABCJingleService().validate(abcSource: abc)

        XCTAssertTrue(abc.contains("Q:1/4="))
        XCTAssertNotNil(validation.tune.features.first)
        XCTAssertNil(ABCJingleService().structureFeedback(for: validation.tune))
    }

    func testServiceMapsAnalysisWarningsToSpeechSafetyRating() {
        let analysis = ABCJingleAnalysis(
            estimatedDurationBeats: 1,
            estimatedDurationSeconds: 0.5,
            tailDurationBeats: 0.5,
            tailDurationSeconds: 0.25,
            voiceCount: 1,
            melodicVoiceCount: 1,
            percussionVoiceCount: 1,
            soundingEventCount: 4,
            maxSimultaneousNotes: 5,
            lowestMIDINote: 24,
            highestMIDINote: 72,
            warnings: [
                ABCJingleWarning(code: .denseTexture, severity: .warning, message: "dense"),
                ABCJingleWarning(code: .busyPercussion, severity: .warning, message: "busy")
            ]
        )

        XCTAssertEqual(ABCJingleService().suggestedSpeechSafety(for: analysis), .risky)
    }
}
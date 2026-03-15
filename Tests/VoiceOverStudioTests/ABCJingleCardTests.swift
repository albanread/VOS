import XCTest
@testable import VoiceOverStudio

final class ABCJingleCardTests: XCTestCase {
    func testPromptAndABCCardSupportsBothAuthoringModes() {
        let card = ABCJingleCard(
            name: "Brand Tag",
            authoringMode: .promptAndABC,
            promptSpec: ABCJinglePromptSpec(promptText: "Create a warm outro tag."),
            abcSource: "X:1\nK:C\nC"
        )

        XCTAssertTrue(card.hasPromptAuthoring)
        XCTAssertTrue(card.hasEditableABC)
    }

    func testBuiltInPresetsIncludeSpokenWordDefaults() {
        let presets = ABCJinglePreset.builtIn
        XCTAssertTrue(presets.contains { $0.id == "podcast_intro" })
        XCTAssertTrue(presets.contains { $0.id == "soft_transition" })
        XCTAssertTrue(presets.contains { $0.defaultPromptSpec.targetDurationSeconds <= 3.0 })
    }
}
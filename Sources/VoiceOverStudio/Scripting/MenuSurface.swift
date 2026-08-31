//
//  MenuSurface.swift
//  VoiceOverStudio
//
//  A named, enumerable table of every action the UI exposes as a button or menu
//  item. `menu items` returns the names and `perform action` invokes one, so a
//  script can discover the app's command surface instead of hard-coding it.
//
//  Actions marked `presentsDialog` open an AppKit panel and will block the Apple
//  Event until a human dismisses it. For unattended automation use the dedicated
//  path-taking verbs instead: save transcript to, load transcript from,
//  export sequence to.
//

import Foundation

struct MenuAction {
    let name: String
    let summary: String
    let isAsynchronous: Bool
    let presentsDialog: Bool
    let syncBody: (@MainActor (ProjectViewModel) -> Void)?
    let asyncBody: (@MainActor (ProjectViewModel) async -> Void)?

    init(
        _ name: String,
        summary: String,
        presentsDialog: Bool = false,
        run: @escaping @MainActor (ProjectViewModel) -> Void
    ) {
        self.name = name
        self.summary = summary
        self.isAsynchronous = false
        self.presentsDialog = presentsDialog
        self.syncBody = run
        self.asyncBody = nil
    }

    init(
        _ name: String,
        summary: String,
        presentsDialog: Bool = false,
        runAsync: @escaping @MainActor (ProjectViewModel) async -> Void
    ) {
        self.name = name
        self.summary = summary
        self.isAsynchronous = true
        self.presentsDialog = presentsDialog
        self.syncBody = nil
        self.asyncBody = runAsync
    }

    @MainActor
    func run(_ model: ProjectViewModel) {
        syncBody?(model)
    }

    @MainActor
    func runAsync(_ model: ProjectViewModel) async {
        await asyncBody?(model)
    }
}

enum MenuSurface {

    static let actions: [MenuAction] = [
        // Setup and models
        MenuAction("initialize engines", summary: "Load the TTS and language models.") { model in
            model.initializeEngines()
        },
        MenuAction("auto setup", summary: "Download and configure recommended models.") { model in
            await model.autoSetup()
        },
        MenuAction("auto detect tier", summary: "Pick a compute tier from this Mac's chip and memory.") { model in
            model.autoDetectModelTier()
        },
        MenuAction("apply recommended models", summary: "Apply the recommended model URLs for the current tier.") { model in
            model.applyRecommendedModelPreset()
        },
        MenuAction("download speech model", summary: "Download the configured Qwen TTS repository.") { model in
            await model.downloadTTSModel()
        },
        MenuAction("update language model", summary: "Download the latest recommended GGUF.") { model in
            await model.updateLatestLLMModel()
        },

        // Project editing
        MenuAction("add paragraph", summary: "Append an empty paragraph.") { model in
            model.addParagraph()
        },
        MenuAction("add jingle card", summary: "Append a blank jingle card.") { model in
            model.addJingleCard()
        },

        // Generation and playback
        MenuAction("generate all", summary: "Synthesize audio for every paragraph.") { model in
            await model.generateAllAudio()
        },
        MenuAction("stop playback", summary: "Stop any audio or MIDI preview that is playing.") { model in
            model.stopPlayback()
        },

        // Panels and sheets
        MenuAction("open jingle library", summary: "Show the jingle card library sheet.") { model in
            model.openJingleLibrary()
        },
        MenuAction("open reference voice", summary: "Show the reference voice enrollment sheet.") { model in
            model.openReferenceVoiceEnrollment()
        },
        MenuAction(
            "save transcript",
            summary: "Save the transcript, asking for a location. Prefer 'save transcript to' when scripting.",
            presentsDialog: true
        ) { model in
            model.saveTranscript()
        },
        MenuAction(
            "load transcript",
            summary: "Load a transcript, asking for a file. Prefer 'load transcript from' when scripting.",
            presentsDialog: true
        ) { model in
            model.loadTranscript()
        },
        MenuAction(
            "save full recording",
            summary: "Export the stitched sequence, asking for a location. Prefer 'export sequence to' when scripting.",
            presentsDialog: true
        ) { model in
            model.saveFullRecording()
        },

        // Window
        MenuAction("show settings pane", summary: "Reveal the settings sidebar.") { _ in
            ScriptingRegistry.uiState?.showSettings()
        },
        MenuAction("toggle settings pane", summary: "Show or hide the settings sidebar.") { _ in
            ScriptingRegistry.uiState?.toggleSettingsPane()
        },
    ]

    static var actionNames: [String] {
        actions.map(\.name)
    }

    static func action(named name: String) -> MenuAction? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return actions.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

//
//  ScriptObjects.swift
//  VoiceOverStudio
//
//  Scriptable wrappers for the app's elements. Each holds only an identifier and
//  reads through to the view model on demand, so a reference obtained by a script
//  stays valid while paragraphs are added, removed, or reordered around it.
//

import AppKit
import Foundation

// MARK: - Paragraph

@objc(VOSScriptParagraph)
final class ScriptParagraph: NSObject {
    let paragraphID: UUID

    init(id: UUID) {
        self.paragraphID = id
        super.init()
    }

    private func read<T>(_ fallback: T, _ body: @MainActor (Paragraph) -> T) -> T {
        withScriptingModel(fallback: fallback) { model in
            guard let paragraph = model.paragraphs.first(where: { $0.id == self.paragraphID }) else {
                return fallback
            }
            return body(paragraph)
        }
    }

    private func mutate(_ body: @MainActor @escaping (inout Paragraph) -> Void) {
        withScriptingModel(fallback: ()) { model in
            guard let index = model.paragraphs.firstIndex(where: { $0.id == self.paragraphID }) else { return }
            body(&model.paragraphs[index])
        }
    }

    @objc var scriptUniqueID: String { paragraphID.uuidString }

    @objc var scriptIndex: Int {
        withScriptingModel(fallback: 0) { model in
            (model.paragraphs.firstIndex(where: { $0.id == self.paragraphID }) ?? -1) + 1
        }
    }

    @objc var scriptText: String {
        get { read("") { $0.text } }
        set { mutate { $0.text = newValue } }
    }

    @objc var scriptVoiceID: String {
        get { read("") { $0.voiceID } }
        set {
            withScriptingModel(fallback: ()) { model in
                guard let index = model.paragraphs.firstIndex(where: { $0.id == self.paragraphID }) else { return }
                guard model.voiceOptions.contains(where: { $0.id == newValue }) else {
                    model.statusMessage = "Unknown voice '\(newValue)'. Use the id of one of the voices elements."
                    return
                }
                model.paragraphs[index].voiceID = newValue
                model.handleVoiceSelectionChange(for: self.paragraphID, voiceID: newValue)
            }
        }
    }

    @objc var scriptSpeed: FourCharCode {
        get {
            read(ScriptingCodes.speedNormal) { paragraph in
                switch paragraph.speed {
                case .slow: return ScriptingCodes.speedSlow
                case .normal: return ScriptingCodes.speedNormal
                case .fast: return ScriptingCodes.speedFast
                }
            }
        }
        set {
            mutate { paragraph in
                switch newValue {
                case ScriptingCodes.speedSlow: paragraph.speed = .slow
                case ScriptingCodes.speedFast: paragraph.speed = .fast
                default: paragraph.speed = .normal
                }
            }
        }
    }

    @objc var scriptPitch: FourCharCode {
        get {
            read(ScriptingCodes.pitchNormal) { paragraph in
                switch paragraph.pitch {
                case .deeper: return ScriptingCodes.pitchDeeper
                case .normal: return ScriptingCodes.pitchNormal
                case .brighter: return ScriptingCodes.pitchBrighter
                }
            }
        }
        set {
            mutate { paragraph in
                switch newValue {
                case ScriptingCodes.pitchDeeper: paragraph.pitch = .deeper
                case ScriptingCodes.pitchBrighter: paragraph.pitch = .brighter
                default: paragraph.pitch = .normal
                }
            }
        }
    }

    @objc var scriptGap: Double {
        get { read(0.0) { $0.gapDuration } }
        set { mutate { $0.gapDuration = max(0, newValue) } }
    }

    /// Seconds into the attached video where this paragraph's voice clip
    /// begins; 0 when unanchored (check `anchored` to tell 0:00 from no anchor).
    @objc var scriptStartTime: Double {
        get { read(0.0) { $0.startTime ?? 0.0 } }
        set { mutate { $0.startTime = max(0, newValue) } }
    }

    /// Length of this paragraph's voice clip: the measured WAV duration once
    /// generated, otherwise an estimate from the text.
    @objc var scriptVoiceDuration: Double {
        withScriptingModel(fallback: 0.0) { model in
            model.audioDuration(forParagraphID: self.paragraphID)
        }
    }

    @objc var scriptAnchored: Bool {
        read(false) { $0.startTime != nil }
    }

    @objc var scriptOutputFilename: String {
        get { read("") { $0.outputFilename } }
        set { mutate { $0.outputFilename = newValue } }
    }

    @objc var scriptAudioPath: String {
        get { read("") { $0.audioPath ?? "" } }
        set {
            withScriptingModel(fallback: ()) { model in
                guard let index = model.paragraphs.firstIndex(where: { $0.id == self.paragraphID }) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let expanded = (trimmed as NSString).expandingTildeInPath
                if !expanded.isEmpty && !FileManager.default.fileExists(atPath: expanded) {
                    model.statusMessage = "No audio file at '\(expanded)'; audio path unchanged."
                    return
                }
                model.paragraphs[index].audioPath = expanded.isEmpty ? nil : expanded
            }
        }
    }

    @objc var scriptGenerated: Bool {
        read(false) { paragraph in
            guard let path = paragraph.audioPath else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    @objc var scriptGenerating: Bool {
        read(false) { $0.isGenerating }
    }


    // MARK: Object-first command handlers (see responds-to in the sdef)

    @objc(handleSynthesizeCommand:)
    func handleSynthesize(_ command: NSScriptCommand) -> Any? {
        let id = paragraphID
        guard withScriptingModel(fallback: false, { $0.isTTSReady }) else {
            command.scriptErrorNumber = -1708
            command.scriptErrorString = "The speech engine is not loaded. Run 'initialize engines' or 'auto setup' first."
            return nil
        }
        command.suspendExecution()
        Task { @MainActor in
            guard let model = ScriptingRegistry.viewModel else {
                command.resumeExecution(withResult: "")
                return
            }
            await model.generateAudio(for: id)
            let path = model.paragraphs.first(where: { $0.id == id })?.audioPath
            if let path {
                command.resumeExecution(withResult: path)
            } else {
                command.scriptErrorNumber = -1708
                command.scriptErrorString = model.statusMessage
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    @objc(handlePolishCommand:)
    func handlePolish(_ command: NSScriptCommand) -> Any? {
        runLLMEdit(command) { model, id in await model.improveText(for: id) }
    }

    @objc(handleRephraseCommand:)
    func handleRephrase(_ command: NSScriptCommand) -> Any? {
        runLLMEdit(command) { model, id in await model.rephraseText(for: id) }
    }

    private func runLLMEdit(
        _ command: NSScriptCommand,
        _ operation: @escaping @MainActor (ProjectViewModel, UUID) async -> Void
    ) -> Any? {
        let id = paragraphID
        guard withScriptingModel(fallback: false, { $0.isLLMReady }) else {
            command.scriptErrorNumber = -1708
            command.scriptErrorString = "The language model is not loaded. Run 'initialize engines' or 'auto setup' first."
            return nil
        }
        command.suspendExecution()
        Task { @MainActor in
            guard let model = ScriptingRegistry.viewModel else {
                command.resumeExecution(withResult: "")
                return
            }
            await operation(model, id)
            let text = model.paragraphs.first(where: { $0.id == id })?.text ?? ""
            command.resumeExecution(withResult: text)
        }
        return nil
    }

    @objc(handlePreviewCommand:)
    func handlePreview(_ command: NSScriptCommand) -> Any? {
        withScriptingModel(fallback: ()) { $0.playAudio(for: self.paragraphID) }
        return nil
    }

    @objc(handleReplicateCommand:)
    func handleReplicate(_ command: NSScriptCommand) -> Any? {
        withScriptingModel(fallback: 0 as Any) { model -> Any in
            let before = Set(model.paragraphs.map(\.id))
            model.duplicateParagraph(self.paragraphID)
            guard let created = model.paragraphs.first(where: { !before.contains($0.id) }),
                  let index = model.paragraphs.firstIndex(where: { $0.id == created.id })
            else { return 0 }
            return index + 1
        }
    }

    @objc(handleRelocateCommand:)
    func handleRelocate(_ command: NSScriptCommand) -> Any? {
        guard let destination = (command.arguments?["Destination"] as? NSNumber)?.intValue else {
            command.scriptErrorNumber = -1708
            command.scriptErrorString = "relocate requires a 'destination' parameter, for example: relocate paragraph 3 destination 1."
            return nil
        }
        withScriptingModel(fallback: ()) { model in
            do {
                try model.scriptMoveParagraph(id: self.paragraphID, toIndex: destination - 1)
            } catch {
                command.scriptErrorNumber = -1708
                command.scriptErrorString = error.localizedDescription
            }
        }
        return nil
    }

    @objc(handleAnchorCommand:)
    func handleAnchor(_ command: NSScriptCommand) -> Any? {
        guard let time = (command.arguments?["Time"] as? NSNumber)?.doubleValue else {
            command.scriptErrorNumber = -1708
            command.scriptErrorString = "anchor requires a 'time' parameter in seconds, for example: anchor narration 2 time 12.5."
            return nil
        }
        let id = paragraphID
        return withScriptingModel(fallback: 0.0 as Any) { model -> Any in
            guard let clamped = model.setParagraphStart(id, at: time) else {
                command.scriptErrorNumber = -1708
                command.scriptErrorString = model.statusMessage
                return 0.0
            }
            return clamped
        }
    }

    @objc(handleUnanchorCommand:)
    func handleUnanchor(_ command: NSScriptCommand) -> Any? {
        withScriptingModel(fallback: ()) { $0.clearParagraphStart(self.paragraphID) }
        return nil
    }


    override var objectSpecifier: NSScriptObjectSpecifier? {
        let index = scriptIndex - 1
        guard index >= 0,
              let appDescription = NSApplication.shared.classDescription as? NSScriptClassDescription
        else { return nil }

        return NSIndexSpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "scriptParagraphs",
            index: index
        )
    }
}

// MARK: - Voice

@objc(VOSScriptVoice)
final class ScriptVoice: NSObject {
    let voiceID: String

    init(id: String) {
        self.voiceID = id
        super.init()
    }

    private func read<T>(_ fallback: T, _ body: @MainActor (VoiceOption) -> T) -> T {
        withScriptingModel(fallback: fallback) { model in
            guard let option = model.voiceOptions.first(where: { $0.id == self.voiceID }) else {
                return fallback
            }
            return body(option)
        }
    }

    @objc var scriptUniqueID: String { voiceID }
    @objc var scriptName: String { read("") { $0.name } }
    @objc var scriptPrompt: String { read("") { $0.prompt } }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        let index = withScriptingModel(fallback: -1) { model in
            model.voiceOptions.firstIndex(where: { $0.id == self.voiceID }) ?? -1
        }
        guard index >= 0,
              let appDescription = NSApplication.shared.classDescription as? NSScriptClassDescription
        else { return nil }

        return NSIndexSpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "scriptVoices",
            index: index
        )
    }
}

// MARK: - Jingle

@objc(VOSScriptJingle)
final class ScriptJingle: NSObject {
    let jingleID: UUID

    init(id: UUID) {
        self.jingleID = id
        super.init()
    }

    private func read<T>(_ fallback: T, _ body: @MainActor (ABCJingleCard) -> T) -> T {
        withScriptingModel(fallback: fallback) { model in
            guard let card = model.jingleCards.first(where: { $0.id == self.jingleID }) else {
                return fallback
            }
            return body(card)
        }
    }

    private func mutate(_ body: @MainActor @escaping (inout ABCJingleCard) -> Void) {
        withScriptingModel(fallback: ()) { model in
            guard let index = model.jingleCards.firstIndex(where: { $0.id == self.jingleID }) else { return }
            body(&model.jingleCards[index])
            model.jingleCards[index].updatedAt = Date()
            model.persistJingleCardStore()
        }
    }

    @objc var scriptUniqueID: String { jingleID.uuidString }

    @objc var scriptName: String {
        get { read("") { $0.name } }
        set { mutate { $0.name = newValue } }
    }

    @objc var scriptRole: String {
        read("") { $0.promptSpec.cueRole.rawValue }
    }

    @objc var scriptABCSource: String {
        get { read("") { $0.abcSource } }
        set {
            mutate { card in
                card.abcSource = newValue
                card.cachedMIDIPath = nil
            }
        }
    }

    @objc var scriptTargetDuration: Double {
        get { read(0.0) { $0.promptSpec.targetDurationSeconds } }
        set { mutate { $0.promptSpec.targetDurationSeconds = max(0, newValue) } }
    }

    @objc var scriptSpeechSafety: String {
        read("") { $0.speechSafety.rawValue }
    }


    // MARK: Object-first command handlers (see responds-to in the sdef)

    @objc(handleVerifyCommand:)
    func handleVerify(_ command: NSScriptCommand) -> Any? {
        withScriptingModel(fallback: "" as Any) { model -> Any in
            do {
                return try model.scriptValidateJingle(id: self.jingleID)
            } catch {
                command.scriptErrorNumber = -1708
                command.scriptErrorString = error.localizedDescription
                return ""
            }
        }
    }

    @objc(handleRenderMIDICommand:)
    func handleRenderMIDI(_ command: NSScriptCommand) -> Any? {
        guard let path = command.arguments?["ToPath"] as? String, !path.isEmpty else {
            command.scriptErrorNumber = -1708
            command.scriptErrorString = "render midi requires a 'to' parameter with a destination path."
            return nil
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return withScriptingModel(fallback: "" as Any) { model -> Any in
            do {
                try model.scriptExportJingleMIDI(id: self.jingleID, to: url)
                return url.path
            } catch {
                command.scriptErrorNumber = -1708
                command.scriptErrorString = error.localizedDescription
                return ""
            }
        }
    }

    @objc(handlePreviewCommand:)
    func handlePreview(_ command: NSScriptCommand) -> Any? {
        withScriptingModel(fallback: ()) { $0.playJingleCardPreview(self.jingleID) }
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        let index = withScriptingModel(fallback: -1) { model in
            model.jingleCards.firstIndex(where: { $0.id == self.jingleID }) ?? -1
        }
        guard index >= 0,
              let appDescription = NSApplication.shared.classDescription as? NSScriptClassDescription
        else { return nil }

        return NSIndexSpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "scriptJingles",
            index: index
        )
    }
}

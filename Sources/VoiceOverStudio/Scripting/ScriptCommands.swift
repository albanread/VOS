//
//  ScriptCommands.swift
//  VoiceOverStudio
//
//  NSScriptCommand subclasses for the application-targeted verbs in
//  VoiceOverStudio.sdef. Element-targeted verbs (synthesize, polish, replicate,
//  verify, ...) dispatch object-first to the handler methods declared via
//  responds-to on VOSScriptParagraph / VOSScriptJingle instead.
//
//  Long-running verbs suspend the Apple Event and resume it when the underlying
//  async work finishes, so a script blocks until the work actually completes.
//

import AppKit
import Foundation

// MARK: - Shared plumbing

extension NSScriptCommand {

    func vosArgument<T>(_ key: String) -> T? {
        (arguments?[key]) as? T
    }

    func vosFail(_ message: String, code: Int = errOSAGeneralError) -> Any? {
        scriptErrorNumber = code
        scriptErrorString = message
        return nil
    }

    /// Suspend the event and resume it once `work` produces a result. Any thrown
    /// error becomes an AppleScript error rather than a silent nil.
    func vosRunAsync(_ work: @escaping @MainActor () async throws -> Any?) -> Any? {
        suspendExecution()
        Task { @MainActor in
            do {
                let result = try await work()
                self.resumeExecution(withResult: result)
            } catch {
                self.scriptErrorNumber = errOSAGeneralError
                self.scriptErrorString = error.localizedDescription
                self.resumeExecution(withResult: nil)
            }
        }
        return nil
    }
}

private func vosModel() -> ProjectViewModel? {
    MainActor.assumeIsolated { ScriptingRegistry.viewModel }
}

private let vosNoAppMessage = "VoiceOverStudio is still starting up; no project is available yet."

// MARK: - Engine and setup

@objc(VOSInitializeEnginesCommand)
final class VOSInitializeEnginesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        return vosRunAsync {
            // The UI starts engine init on launch; if that is in flight the
            // guarded call returns immediately. Wait for it instead of
            // duplicating the work, then run init only if still needed.
            while model.isProcessing {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if !(model.isTTSReady || model.isLLMReady) {
                await model.initializeEngines(managesProcessingState: true)
            }
            return model.statusMessage
        }
    }
}

@objc(VOSAutoSetupCommand)
final class VOSAutoSetupCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        return vosRunAsync {
            await model.autoSetup()
            return model.statusMessage
        }
    }
}

@objc(VOSWaitUntilIdleCommand)
final class VOSWaitUntilIdleCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        let timeout = (arguments?["Timeout"] as? NSNumber)?.doubleValue ?? 300

        return vosRunAsync {
            let deadline = Date().addingTimeInterval(max(0, timeout))
            while Date() < deadline {
                let busy = model.isProcessing
                    || model.isUpdatingModels
                    || model.paragraphs.contains(where: \.isGenerating)
                if !busy { return true }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            return false
        }
    }
}

// MARK: - Creation

@objc(VOSCreateNarrationCommand)
final class VOSCreateNarrationCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        let text: String? = vosArgument("WithText")
        let voice: String? = vosArgument("WithVoice")

        return MainActor.assumeIsolated {
            let id = model.scriptAddParagraph(text: text, voiceID: voice)
            return (model.scriptParagraphIndex(for: id) ?? 0) + 1
        }
    }
}

@objc(VOSCreateCueCommand)
final class VOSCreateCueCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        let presetID: String? = vosArgument("FromPreset")

        var preset: ABCJinglePreset?
        if let presetID {
            guard let match = ABCJinglePreset.builtIn.first(where: { $0.id == presetID }) else {
                let available = ABCJinglePreset.builtIn.map(\.id).joined(separator: ", ")
                return vosFail("Unknown preset '\(presetID)'. Available presets: \(available).")
            }
            preset = match
        }

        return MainActor.assumeIsolated {
            let before = Set(model.jingleCards.map(\.id))
            model.addJingleCard(from: preset)
            guard let created = model.jingleCards.first(where: { !before.contains($0.id) }),
                  let index = model.jingleCards.firstIndex(where: { $0.id == created.id })
            else { return 0 }
            return index + 1
        }
    }
}

// MARK: - Generation and playback

@objc(VOSGenerateAllCommand)
final class VOSGenerateAllCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard MainActor.assumeIsolated({ model.isTTSReady }) else {
            return vosFail("The speech engine is not loaded. Run 'initialize engines' or 'auto setup' first.")
        }

        return vosRunAsync {
            await model.generateAllAudio()
            return model.statusMessage
        }
    }
}

@objc(VOSGenerateMissingCommand)
final class VOSGenerateMissingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard MainActor.assumeIsolated({ model.isTTSReady }) else {
            return vosFail("The speech engine is not loaded. Run 'initialize engines' or 'auto setup' first.")
        }

        return vosRunAsync {
            let written = await model.generateMissingAudio()
            return "\(written) — \(model.statusMessage)"
        }
    }
}

@objc(VOSStopPlaybackCommand)
final class VOSStopPlaybackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        return MainActor.assumeIsolated {
            model.stopPlayback()
            return nil
        }
    }
}

// MARK: - Files

@objc(VOSExportSequenceCommand)
final class VOSExportSequenceCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("ToPath"), !path.isEmpty else {
            return vosFail("export sequence requires a 'to' parameter with a destination path.")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return vosRunAsync {
            let format = ProjectViewModel.ExportFormat(rawValue: model.exportFormatRaw) ?? .m4a
            try await model.scriptExportSequence(to: url, format: format)
            return url.path
        }
    }
}

// MARK: - Video timeline

@objc(VOSAttachVideoCommand)
final class VOSAttachVideoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("ToPath"), !path.isEmpty else {
            return vosFail("attach video requires a 'to' parameter with a video file path.")
        }

        return vosRunAsync {
            try await model.scriptAttachVideo(path: path)
        }
    }
}

@objc(VOSDetachVideoCommand)
final class VOSDetachVideoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        return MainActor.assumeIsolated {
            _ = model.scriptDetachVideo()
            return model.statusMessage
        }
    }
}

@objc(VOSExportVideoCommand)
final class VOSExportVideoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("ToPath"), !path.isEmpty else {
            return vosFail("export video requires a 'to' parameter with a destination path.")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return vosRunAsync {
            _ = try await model.scriptExportVideo(to: url)
            return url.path
        }
    }
}

@objc(VOSExportVoiceTrackCommand)
final class VOSExportVoiceTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("ToPath"), !path.isEmpty else {
            return vosFail("export voice track requires a 'to' parameter with a destination WAV path.")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return vosRunAsync {
            try await model.scriptExportVoiceTrack(to: url)
        }
    }
}

@objc(VOSSaveTranscriptCommand)
final class VOSSaveTranscriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("ToPath"), !path.isEmpty else {
            return vosFail("save transcript requires a 'to' parameter with a destination path.")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return MainActor.assumeIsolated {
            do {
                try model.scriptSaveTranscript(to: url)
                return url.path
            } catch {
                return vosFail(error.localizedDescription)
            }
        }
    }
}

@objc(VOSLoadTranscriptCommand)
final class VOSLoadTranscriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("FromPath"), !path.isEmpty else {
            return vosFail("load transcript requires a 'from' parameter with a source path.")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return MainActor.assumeIsolated {
            do {
                return try model.scriptLoadTranscript(from: url)
            } catch {
                return vosFail(error.localizedDescription)
            }
        }
    }
}

// MARK: - Screenshot

@objc(VOSCaptureScreenshotCommand)
final class VOSCaptureScreenshotCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let requested: String? = vosArgument("ToPath")
        return MainActor.assumeIsolated {
            do {
                let url = try WindowCapture.captureMainWindow(to: requested)
                return url.path
            } catch {
                return vosFail(error.localizedDescription)
            }
        }
    }
}

// MARK: - Projects

@objc(VOSSwitchProjectCommand)
final class VOSSwitchProjectCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        let name: String? = vosArgument("Named")
        let number: Int? = (arguments?["Number"] as? NSNumber)?.intValue

        let listings = MainActor.assumeIsolated {
            model.recentProjectListings()
        }
        guard !listings.isEmpty else {
            return vosFail("There are no projects yet. Create one first.")
        }

        var target: ProjectListing?
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let exact = listings.filter { $0.name == trimmed }
            if exact.count == 1 {
                target = exact.first
            } else {
                let prefixed = listings.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                if prefixed.count == 1 {
                    target = prefixed.first
                } else if prefixed.count > 1 {
                    let names = prefixed.map(\.name).joined(separator: ", ")
                    return vosFail("Ambiguous project '\(trimmed)' — matches: \(names).")
                }
            }
        } else if let number, number >= 1, number <= listings.count {
            target = listings[number - 1]
        }

        guard let target else {
            let names = listings.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "; ")
            return vosFail("No matching project. Known projects: \(names).")
        }

        return MainActor.assumeIsolated {
            model.openProject(target.id)
            return model.statusMessage
        }
    }
}

@objc(VOSNewProjectCommand)
final class VOSNewProjectCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        let name: String? = vosArgument("Named")
        return MainActor.assumeIsolated {
            model.startNewProject(named: name ?? "Untitled Project")
            return model.statusMessage
        }
    }
}

// MARK: - Menu surface

@objc(VOSMenuItemsCommand)
final class VOSMenuItemsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        if ProcessInfo.processInfo.environment["VOS_SCRIPT_DEBUG"] == "1" {
            MainActor.assumeIsolated { ScriptingDiagnostics.dumpRegistry() }
        }
        return MenuSurface.actionNames
    }
}

@objc(VOSPerformActionCommand)
final class VOSPerformActionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let name = directParameter as? String else {
            return vosFail("perform action requires an action name. Use 'menu items' to list them.")
        }
        guard let action = MenuSurface.action(named: name) else {
            return vosFail("Unknown action '\(name)'. Use 'menu items' to list the available names.")
        }

        if action.isAsynchronous {
            return vosRunAsync {
                await action.runAsync(model)
                return model.statusMessage
            }
        }

        return MainActor.assumeIsolated {
            action.run(model)
            return model.statusMessage
        }
    }
}

@objc(VOSDiscardCommand)
final class VOSDiscardCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let slot = (arguments?["Slot"] as? NSNumber)?.intValue else {
            return vosFail("discard requires a 'slot' parameter, for example: discard slot 2.")
        }
        return MainActor.assumeIsolated {
            guard model.paragraphs.indices.contains(slot - 1) else {
                return vosFail("No narration at position \(slot); there are \(model.paragraphs.count).")
            }
            model.removeParagraph(model.paragraphs[slot - 1].id)
            return model.paragraphs.count
        }
    }
}

// MARK: - Slideshow

@objc(VOSImportSlideshowCommand)
final class VOSImportSlideshowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("FromPath"), !path.isEmpty else {
            return vosFail("import slideshow requires a 'from' parameter with a PDF path.")
        }

        return vosRunAsync {
            try await model.scriptImportSlideshow(pdfPath: path)
        }
    }
}

@objc(VOSSlideshowInfoCommand)
final class VOSSlideshowInfoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        return MainActor.assumeIsolated {
            model.slideshowInfoText()
        }
    }
}

@objc(VOSDumpSlideshowCommand)
final class VOSDumpSlideshowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let path: String = vosArgument("ToPath"), !path.isEmpty else {
            return vosFail("dump slideshow requires a 'to' parameter with a destination folder.")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return vosRunAsync {
            try await model.scriptDumpSlideshow(to: url)
        }
    }
}

@objc(VOSNarrateSegmentCommand)
final class VOSNarrateSegmentCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let number = (arguments?["Number"] as? NSNumber)?.intValue else {
            return vosFail("narrate segment requires a 'segment' parameter, for example: narrate segment 3 with \"...\".")
        }
        guard let text: String = vosArgument("WithText"), !text.isEmpty else {
            return vosFail("narrate segment requires a 'with text' parameter holding the summary.")
        }

        return vosRunAsync {
            try await model.scriptNarrateSegment(number: number, text: text)
            return model.statusMessage
        }
    }
}

@objc(VOSSkipSegmentCommand)
final class VOSSkipSegmentCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let number = (arguments?["Number"] as? NSNumber)?.intValue else {
            return vosFail("skip segment requires a 'segment' parameter, for example: skip segment 4.")
        }

        return vosRunAsync {
            try await model.scriptSkipSegment(number: number, skipped: true)
            return model.statusMessage
        }
    }
}

@objc(VOSUnskipSegmentCommand)
final class VOSUnskipSegmentCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }
        guard let number = (arguments?["Number"] as? NSNumber)?.intValue else {
            return vosFail("unskip segment requires a 'segment' parameter, for example: unskip segment 4.")
        }

        return vosRunAsync {
            try await model.scriptSkipSegment(number: number, skipped: false)
            return model.statusMessage
        }
    }
}

@objc(VOSBakeSlideshowCommand)
final class VOSBakeSlideshowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }

        return vosRunAsync {
            try await model.scriptBakeSlideshow()
        }
    }
}

@objc(VOSReSplitSlideshowCommand)
final class VOSReSplitSlideshowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let model = vosModel() else { return vosFail(vosNoAppMessage) }

        return vosRunAsync {
            try await model.scriptReSplitSlideshow()
        }
    }
}

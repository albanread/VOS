//
//  ScriptingBridge.swift
//  VoiceOverStudio
//
//  Cocoa scripting addresses the `application` object, so the app-level
//  properties and element lists declared in VoiceOverStudio.sdef are resolved
//  by key-value coding against NSApplication. This file provides those keys and
//  the registry that lets them reach the SwiftUI view model.
//

import AppKit
import Foundation

/// Holds the live view model so `NSScriptCommand` subclasses and the KVC
/// accessors below can reach it. Set once at launch by the app delegate.
@MainActor
enum ScriptingRegistry {
    private(set) static weak var viewModel: ProjectViewModel?
    private(set) static weak var uiState: AppUIState?

    /// Identifies this process instance: launch time + pid. Read via the
    /// `build stamp` property so scripts can detect a stale instance.
    nonisolated static let processStamp: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "launched \(formatter.string(from: Date())) pid \(ProcessInfo.processInfo.processIdentifier)"
    }()

    static func register(model: ProjectViewModel, uiState state: AppUIState) {
        viewModel = model
        uiState = state
    }

    /// Cocoa scripting always dispatches on the main thread, so accessors can
    /// hop onto the main actor without awaiting.
    static func withModel<T>(_ body: (ProjectViewModel) -> T, fallback: T) -> T {
        guard let viewModel else { return fallback }
        return body(viewModel)
    }
}

/// Reads the registry from a synchronous, non-isolated Cocoa scripting callback.
/// Safe because Apple Events are delivered on the main thread.
func withScriptingModel<T>(fallback: T, _ body: @MainActor (ProjectViewModel) -> T) -> T {
    MainActor.assumeIsolated {
        guard let model = ScriptingRegistry.viewModel else { return fallback }
        return body(model)
    }
}

// MARK: - Application-level scripting keys

extension NSApplication {

    @objc var scriptApplicationName: String {
        "VoiceOverStudio"
    }

    @objc var scriptStatus: String {
        withScriptingModel(fallback: "") { $0.statusMessage }
    }

    @objc var scriptBusy: Bool {
        withScriptingModel(fallback: false) { model in
            model.isProcessing
                || model.isUpdatingModels
                || model.paragraphs.contains(where: \.isGenerating)
        }
    }

    @objc var scriptTTSReady: Bool {
        withScriptingModel(fallback: false) { $0.isTTSReady }
    }

    @objc var scriptLLMReady: Bool {
        withScriptingModel(fallback: false) { $0.isLLMReady }
    }

    @objc var scriptReferenceVoiceEnrolled: Bool {
        withScriptingModel(fallback: false) { $0.referenceVoiceProfile != nil }
    }

    @objc var scriptSetupProgress: Double {
        withScriptingModel(fallback: 0.0) { $0.modelUpdateProgress }
    }

    @objc var scriptSetupNarrative: String {
        withScriptingModel(fallback: "") { $0.modelUpdateNarrative }
    }

    /// Stamped at process start; lets a test harness confirm which binary answers.
    @objc var scriptBuildStamp: String {
        ScriptingRegistry.processStamp
    }

    @objc var scriptTTSModelRepo: String {
        get { withScriptingModel(fallback: "") { $0.ttsModelRepo } }
        set { withScriptingModel(fallback: ()) { $0.ttsModelRepo = newValue } }
    }

    @objc var scriptLLMModelPath: String {
        get { withScriptingModel(fallback: "") { $0.modelPathLLM } }
        set { withScriptingModel(fallback: ()) { $0.modelPathLLM = newValue } }
    }

    @objc var scriptDefaultGap: Double {
        get { withScriptingModel(fallback: 0.5) { $0.defaultGap } }
        set { withScriptingModel(fallback: ()) { $0.defaultGap = max(0, newValue) } }
    }

    /// Enumerations cross the Apple Event boundary as their four-char codes.
    @objc var scriptComputeTier: FourCharCode {
        get {
            withScriptingModel(fallback: ScriptingCodes.tierSmall) { model in
                switch model.modelComputeTier {
                case .small: return ScriptingCodes.tierSmall
                case .medium: return ScriptingCodes.tierMedium
                case .high: return ScriptingCodes.tierHigh
                }
            }
        }
        set {
            withScriptingModel(fallback: ()) { model in
                switch newValue {
                case ScriptingCodes.tierMedium: model.modelComputeTier = .medium
                case ScriptingCodes.tierHigh: model.modelComputeTier = .high
                default: model.modelComputeTier = .small
                }
            }
        }
    }

    @objc var scriptExportFormat: FourCharCode {
        get {
            withScriptingModel(fallback: ScriptingCodes.formatM4A) { model in
                let format = ProjectViewModel.ExportFormat(rawValue: model.exportFormatRaw) ?? .m4a
                return format == .wav ? ScriptingCodes.formatWAV : ScriptingCodes.formatM4A
            }
        }
        set {
            withScriptingModel(fallback: ()) { model in
                model.exportFormatRaw = (newValue == ScriptingCodes.formatWAV)
                    ? ProjectViewModel.ExportFormat.wav.rawValue
                    : ProjectViewModel.ExportFormat.m4a.rawValue
            }
        }
    }

}

extension NSApplication {
    // NSDeleteCommand probes the receiving application object directly for the
    // removal accessor; the delegate-forwarding path does not cover removal.
    @objc(removeObjectFromScriptParagraphsAtIndex:)
    func removeObjectFromScriptParagraphs(at index: Int) {
        withScriptingModel(fallback: ()) { model in
            guard model.paragraphs.indices.contains(index) else { return }
            model.removeParagraph(model.paragraphs[index].id)
        }
    }
}

// MARK: - Four-character codes shared with the sdef

enum ScriptingCodes {
    static let tierSmall: FourCharCode = fourCharCode("Etsm")
    static let tierMedium: FourCharCode = fourCharCode("Etmd")
    static let tierHigh: FourCharCode = fourCharCode("Ethi")

    static let formatM4A: FourCharCode = fourCharCode("Efm4")
    static let formatWAV: FourCharCode = fourCharCode("Efwv")

    static let speedSlow: FourCharCode = fourCharCode("Espl")
    static let speedNormal: FourCharCode = fourCharCode("Espn")
    static let speedFast: FourCharCode = fourCharCode("Espf")

    static let pitchDeeper: FourCharCode = fourCharCode("Epdp")
    static let pitchNormal: FourCharCode = fourCharCode("Epnm")
    static let pitchBrighter: FourCharCode = fourCharCode("Epbr")
}

func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + FourCharCode(scalar.value & 0xFF)
    }
    return result
}

// MARK: - Registry ground truth

/// Dump what NSScriptSuiteRegistry actually registered. The registry's strict
/// sdef parser silently drops definitions it rejects (complaints go to the
/// unified log), so this is the authoritative list of dispatchable commands.
@MainActor
enum ScriptingDiagnostics {
    static func dumpRegistry() {
        let registry = NSScriptSuiteRegistry.shared()
        for suite in registry.suiteNames {
            debugLog("DEBUG:: [Registry] suite '\(suite)'")
            for command in registry.commandDescriptions(inSuite: suite) ?? [:] {
                let d = command.value
                debugLog("DEBUG:: [Registry]   command '\(command.key)' class=\(fourCC(d.appleEventClassCode)) id=\(fourCC(d.appleEventCode)) impl=\(d.commandClassName)")
            }
            for cls in registry.classDescriptions(inSuite: suite) ?? [:] {
                let c = cls.value
                debugLog("DEBUG:: [Registry]   class '\(cls.key)' code=\(fourCC(c.appleEventCode)) impl=\(c.implementationClassName ?? "-")")
            }
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { Character(UnicodeScalar((code >> $0) & 0xFF) ?? "?") }
        return String(bytes)
    }
}

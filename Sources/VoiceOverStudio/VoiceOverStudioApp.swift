//
//  VoiceOverStudioApp.swift
//  VoiceOverStudio
//

import SwiftUI
import AppKit

@MainActor
final class AppUIState: ObservableObject {
    @Published var splitVisibility: NavigationSplitViewVisibility = .all

    init() {
        ScriptingRegistry.registerUIState(self)
    }

    func showSettings() {
        splitVisibility = .all
    }

    func toggleSettingsPane() {
        splitVisibility = (splitVisibility == .detailOnly) ? .all : .detailOnly
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: ProjectViewModel?

    // MARK: Cocoa scripting elements
    //
    // The documented pattern for application-level scripting keys: NSApplication
    // asks its delegate via application(_:delegateHandlesKey:), and standard-suite
    // machinery (count, delete, every-element) resolves through the delegate.

    private static let scriptElementKeys: Set<String> = [
        "scriptParagraphs", "scriptVoices", "scriptJingles",
    ]

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        Self.scriptElementKeys.contains(key)
    }

    @objc var scriptParagraphs: [ScriptParagraph] {
        withScriptingModel(fallback: []) { model in
            model.paragraphs.map { ScriptParagraph(id: $0.id) }
        }
    }

    @objc var scriptVoices: [ScriptVoice] {
        withScriptingModel(fallback: []) { model in
            model.voiceOptions.map { ScriptVoice(id: $0.id) }
        }
    }

    @objc var scriptJingles: [ScriptJingle] {
        withScriptingModel(fallback: []) { model in
            model.jingleCards.map { ScriptJingle(id: $0.id) }
        }
    }

    @objc(countOfScriptParagraphs)
    var countOfScriptParagraphs: Int {
        withScriptingModel(fallback: 0) { $0.paragraphs.count }
    }

    @objc(objectInScriptParagraphsAtIndex:)
    func objectInScriptParagraphs(at index: Int) -> ScriptParagraph? {
        withScriptingModel(fallback: nil) { model in
            guard model.paragraphs.indices.contains(index) else { return nil }
            return ScriptParagraph(id: model.paragraphs[index].id)
        }
    }

    @objc(removeObjectFromScriptParagraphsAtIndex:)
    func removeObjectFromScriptParagraphs(at index: Int) {
        withScriptingModel(fallback: ()) { model in
            guard model.paragraphs.indices.contains(index) else { return }
            model.removeParagraph(model.paragraphs[index].id)
        }
    }

    @objc(countOfScriptVoices)
    var countOfScriptVoices: Int {
        withScriptingModel(fallback: 0) { $0.voiceOptions.count }
    }

    @objc(objectInScriptVoicesAtIndex:)
    func objectInScriptVoices(at index: Int) -> ScriptVoice? {
        withScriptingModel(fallback: nil) { model in
            guard model.voiceOptions.indices.contains(index) else { return nil }
            return ScriptVoice(id: model.voiceOptions[index].id)
        }
    }

    @objc(countOfScriptJingles)
    var countOfScriptJingles: Int {
        withScriptingModel(fallback: 0) { $0.jingleCards.count }
    }

    @objc(objectInScriptJinglesAtIndex:)
    func objectInScriptJingles(at index: Int) -> ScriptJingle? {
        withScriptingModel(fallback: nil) { model in
            guard model.jingleCards.indices.contains(index) else { return nil }
            return ScriptJingle(id: model.jingleCards[index].id)
        }
    }

    /// Scripted launches should not steal focus from whatever the user is doing.
    /// Set VOS_BACKGROUND_LAUNCH=1, or pass --background, to come up unfocused.
    private static var launchesInBackground: Bool {
        ProcessInfo.processInfo.environment["VOS_BACKGROUND_LAUNCH"] == "1"
            || CommandLine.arguments.contains("--background")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !Self.launchesInBackground {
            NSApp.activate(ignoringOtherApps: true)
        }
        debugLog("DEBUG:: ============================================")
        debugLog("DEBUG:: VoiceOverStudio launched \(Date())")
        debugLog("DEBUG:: ============================================")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Immediately exit the process. Touching any @MainActor-isolated
        // object (viewModel, TTS, LLM) from this delegate callback causes
        // crashes — either actor-isolation traps or C-library teardown races.
        // The OS reclaims all resources on process exit.
        debugLog("DEBUG:: applicationWillTerminate - calling _exit(0).")
        _exit(0)
    }
}

@main
struct VoiceOverStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var uiState = AppUIState()
    @StateObject private var viewModel = ProjectViewModel()

    init() {
        // No-op here, binding in body
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    appDelegate.viewModel = viewModel
                    // Apple Events resolve against these; see Scripting/.
                    ScriptingRegistry.register(model: viewModel, uiState: uiState)
                }
                .environmentObject(viewModel)
                .environmentObject(uiState)
        }
        .commands {
            CommandMenu("Project") {
                Button("New Project…") {
                    viewModel.isNewProjectSheetPresented = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Open Project…") {
                    viewModel.isOpenProjectSheetPresented = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Manage Clips…") {
                    viewModel.openClipManager()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Import Slideshow from PDF…") {
                    viewModel.importSlideshowViaPanel()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Menu("Open Recent") {
                    if viewModel.recentProjects.isEmpty {
                        Text("No Projects Yet")
                    }
                    ForEach(viewModel.recentProjects, id: \.id) { listing in
                        Button {
                            viewModel.openProject(listing.id)
                        } label: {
                            HStack {
                                if listing.id == viewModel.activeProjectID {
                                    Image(systemName: "checkmark")
                                }
                                Text(listing.name)
                            }
                        }
                    }
                }

                Menu("Clip") {
                    if viewModel.clipSummaries.isEmpty {
                        Text("No Clips in This Project")
                    }
                    ForEach(viewModel.clipSummaries, id: \.id) { clip in
                        Button {
                            viewModel.switchToClip(clip.id)
                        } label: {
                            HStack {
                                if clip.id == viewModel.activeClip?.id {
                                    Image(systemName: "checkmark")
                                }
                                Text(clip.displayName)
                            }
                        }
                    }
                }
            }

            CommandGroup(after: .newItem) {
                Button("Save Transcript…") {
                    viewModel.saveTranscript()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Load Transcript…") {
                    viewModel.loadTranscript()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Save Full Recording…") {
                    viewModel.saveFullRecording()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            // Extend the system View menu instead of adding a second one.
            CommandGroup(after: .sidebar) {
                Button(uiState.splitVisibility == .detailOnly ? "Show Settings Pane" : "Hide Settings Pane") {
                    uiState.toggleSettingsPane()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}

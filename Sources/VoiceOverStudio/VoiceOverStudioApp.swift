//
//  VoiceOverStudioApp.swift
//  VoiceOverStudio
//

import SwiftUI
import AppKit

@MainActor
final class AppUIState: ObservableObject {
    @Published var splitVisibility: NavigationSplitViewVisibility = .all

    func showSettings() {
        splitVisibility = .all
    }

    func toggleSettingsPane() {
        splitVisibility = (splitVisibility == .detailOnly) ? .all : .detailOnly
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: ProjectViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
                .onAppear { appDelegate.viewModel = viewModel }
                .environmentObject(viewModel)
                .environmentObject(uiState)
        }
        .commands {
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

            CommandMenu("View") {
                Button("Settings") {
                    uiState.showSettings()
                }

                Button(uiState.splitVisibility == .detailOnly ? "Show Settings Pane" : "Hide Settings Pane") {
                    uiState.toggleSettingsPane()
                }
            }
        }
    }
}

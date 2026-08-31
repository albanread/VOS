//
//  WindowCapture.swift
//  VoiceOverStudio
//
//  Screenshots for scripted control. This renders the app's own view hierarchy
//  rather than reading the screen, so it needs no Screen Recording permission
//  and captures the window even when it is behind another app.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
enum WindowCapture {

    enum CaptureError: LocalizedError {
        case noWindow
        case noContentView
        case emptyBounds
        case bitmapUnavailable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noWindow:
                return "VoiceOverStudio has no visible window to capture."
            case .noContentView:
                return "The window has no content view to capture."
            case .emptyBounds:
                return "The window content has zero size."
            case .bitmapUnavailable:
                return "Could not allocate a bitmap for the window contents."
            case .encodingFailed:
                return "Could not encode the captured window as PNG."
            }
        }
    }

    /// Write a PNG of the app's UI. Renders the SwiftUI hierarchy directly with
    /// ImageRenderer against the live view model — cacheDisplay cannot composite
    /// SwiftUI's layer tree, and window-server captures need Screen Recording
    /// permission. Returns the file that was written.
    @discardableResult
    static func captureMainWindow(to requestedPath: String?) throws -> URL {
        guard let model = ScriptingRegistry.viewModel, let uiState = ScriptingRegistry.uiState else {
            throw CaptureError.noWindow
        }

        let window = NSApplication.shared.mainWindow
            ?? NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil })
        let size = window?.contentView.map { CGSize(width: $0.bounds.width, height: $0.bounds.height) }
            ?? CGSize(width: 1280, height: 820)
        guard size.width >= 1, size.height >= 1 else { throw CaptureError.emptyBounds }

        let root = ContentView()
            .environmentObject(model)
            .environmentObject(uiState)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: root)
        renderer.scale = window?.backingScaleFactor ?? 2.0

        guard let cgImage = renderer.cgImage else {
            throw CaptureError.bitmapUnavailable
        }

        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }

        let url = resolveDestination(requestedPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private static func resolveDestination(_ requestedPath: String?) -> URL {
        if let requestedPath, !requestedPath.isEmpty {
            let expanded = (requestedPath as NSString).expandingTildeInPath
            var url = URL(fileURLWithPath: expanded)
            if url.pathExtension.isEmpty {
                url.appendPathExtension("png")
            }
            return url
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "voiceoverstudio-\(formatter.string(from: Date())).png"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: false)
    }
}

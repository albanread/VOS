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

    /// Write a PNG of the app's main window. Returns the file that was written.
    @discardableResult
    static func captureMainWindow(to requestedPath: String?) throws -> URL {
        let app = NSApplication.shared
        let window = app.mainWindow
            ?? app.keyWindow
            ?? app.windows.first(where: { $0.isVisible && $0.contentView != nil })

        guard let window else { throw CaptureError.noWindow }
        guard let contentView = window.contentView else { throw CaptureError.noContentView }

        let bounds = contentView.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { throw CaptureError.emptyBounds }

        // Layer-backed SwiftUI content may not have painted while the window
        // is in the background; force a display pass before caching.
        window.displayIfNeeded()
        contentView.displayIfNeeded()

        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CaptureError.bitmapUnavailable
        }
        representation.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: representation)

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

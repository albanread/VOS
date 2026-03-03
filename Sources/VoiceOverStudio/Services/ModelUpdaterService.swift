//
//  ModelUpdaterService.swift
//  VoiceOverStudio
//

import Foundation

struct ModelUpdaterService {
    enum ModelUpdaterError: LocalizedError {
        case invalidHTTPResponse
        case emptyFile
        case extractionFailed(String)
        case missingTTSFiles

        var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse:
                return "Invalid server response during model download."
            case .emptyFile:
                return "Downloaded file is empty."
            case .extractionFailed(let details):
                return "Failed to extract model archive: \(details)"
            case .missingTTSFiles:
                return "Could not find required TTS files (.onnx, tokens.txt, espeak-ng-data) after extraction."
            }
        }
    }

    func downloadFile(from sourceURL: URL, into directory: URL, preferredFilename: String? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ModelUpdaterError.invalidHTTPResponse
        }

        let filename: String
        if let preferredFilename, !preferredFilename.isEmpty {
            filename = preferredFilename
        } else if let suggested = response.suggestedFilename, !suggested.isEmpty {
            filename = suggested
        } else {
            filename = sourceURL.lastPathComponent.isEmpty ? "model.bin" : sourceURL.lastPathComponent
        }

        let destinationURL = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            throw ModelUpdaterError.emptyFile
        }

        return destinationURL
    }

    func extractTarBz2(archiveURL: URL, into directory: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archiveURL.path, "-C", directory.path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown tar error"
            throw ModelUpdaterError.extractionFailed(message)
        }

        let extractedName = archiveURL.deletingPathExtension().deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(extractedName, isDirectory: true)
    }

    func findTTSFiles(in root: URL) throws -> (model: URL, tokens: URL, dataDir: URL?, lexicon: URL?) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ModelUpdaterError.missingTTSFiles
        }

        var modelURL: URL?
        var tokensURL: URL?
        var dataDirURL: URL?
        var lexiconURL: URL?

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "espeak-ng-data" {
                dataDirURL = fileURL
            } else if fileURL.pathExtension.lowercased() == "onnx", modelURL == nil {
                // Prefer non-int8 model; fall back to int8 if that's all we have
                let name = fileURL.lastPathComponent
                if !name.contains(".int8.") {
                    modelURL = fileURL
                } else if modelURL == nil {
                    modelURL = fileURL
                }
            } else if fileURL.lastPathComponent == "tokens.txt", tokensURL == nil {
                tokensURL = fileURL
            } else if fileURL.lastPathComponent == "lexicon.txt", lexiconURL == nil {
                lexiconURL = fileURL
            }
        }

        // If we never set modelURL due to the int8 guard, do a second pass for int8
        if modelURL == nil {
            if let enumerator2 = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator2 where fileURL.pathExtension.lowercased() == "onnx" {
                    modelURL = fileURL
                    break
                }
            }
        }

        guard let model = modelURL, let tokens = tokensURL else {
            throw ModelUpdaterError.missingTTSFiles
        }

        // A model is usable if it has either espeak-ng-data OR a lexicon
        guard dataDirURL != nil || lexiconURL != nil else {
            throw ModelUpdaterError.missingTTSFiles
        }

        return (model: model, tokens: tokens, dataDir: dataDirURL, lexicon: lexiconURL)
    }
}

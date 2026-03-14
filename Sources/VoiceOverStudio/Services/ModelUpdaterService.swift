//
//  ModelUpdaterService.swift
//  VoiceOverStudio
//

import Foundation

struct ModelUpdaterService {
    enum ModelUpdaterError: LocalizedError {
        case invalidHTTPResponse
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse:
                return "Invalid server response during model download."
            case .emptyFile:
                return "Downloaded file is empty."
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
}

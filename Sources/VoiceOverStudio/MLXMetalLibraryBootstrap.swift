import Foundation

enum MLXMetalLibraryBootstrap {
    static func stageIfNeeded() throws {
        guard let bundledLibrary = Bundle.module.url(forResource: "default", withExtension: "metallib") else {
            throw BootstrapError.missingBundledLibrary
        }

        let executableURL = try executableDirectory()
        let fileManager = FileManager.default
        let targets = [
            executableURL.appendingPathComponent("mlx.metallib", isDirectory: false),
            executableURL.appendingPathComponent("default.metallib", isDirectory: false),
        ]

        for targetURL in targets {
            if needsCopy(from: bundledLibrary, to: targetURL, fileManager: fileManager) {
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
                try fileManager.copyItem(at: bundledLibrary, to: targetURL)
            }
        }
    }

    private static func executableDirectory() throws -> URL {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.deletingLastPathComponent()
        }

        let executablePath = CommandLine.arguments[0]
        guard !executablePath.isEmpty else {
            throw BootstrapError.missingExecutablePath
        }

        return URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    }

    private static func needsCopy(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return true
        }

        let sourceDate = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let destinationDate = (try? destinationURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return sourceDate > destinationDate
    }

    enum BootstrapError: LocalizedError {
        case missingBundledLibrary
        case missingExecutablePath

        var errorDescription: String? {
            switch self {
            case .missingBundledLibrary:
                return "Bundled MLX metallib is missing. Run Scripts/build-mlx-metallib.sh before launching the app."
            case .missingExecutablePath:
                return "Unable to determine the executable path for MLX metallib staging."
            }
        }
    }
}
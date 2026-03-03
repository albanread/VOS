// DebugLog.swift — writes directly to /tmp/vos.log, bypassing stdout buffering
import Foundation

private let debugLogPath = "/tmp/vos.log"
private let debugLogQueue = DispatchQueue(label: "debuglog", qos: .utility)

func debugLog(_ msg: String) {
    let line = msg + "\n"
    let data = Data(line.utf8)
    debugLogQueue.sync {
        // Open, append, flush synchronously so even a crash leaves the log.
        do {
            if !FileManager.default.fileExists(atPath: debugLogPath) {
                FileManager.default.createFile(atPath: debugLogPath, contents: nil)
            }
            guard let fh = FileHandle(forWritingAtPath: debugLogPath) else { return }
            try fh.seekToEnd()
            try fh.write(contentsOf: data)
            try fh.synchronize()  // Flush to disk now
            try fh.close()
        } catch {
            // Last-resort fallback: ignore logging errors
        }
    }
}

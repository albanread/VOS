import Foundation

struct UserVoiceTag: Codable {
    var gender: String? // "M", "F"
    var accent: String? // "English", "Scottish", "Irish", "American", "Indian"
    var region: String? // "North", "South", "East", "West"
    var quality: Int?   // 0-10 subjective quality slider
}

class VoiceTagService {
    static let shared = VoiceTagService()
    private let tagFileURL: URL
    private var tags: [Int32: UserVoiceTag] = [:]

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/vos2026", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tagFileURL = root.appendingPathComponent("tags.json")
        loadTags()
    }

    private func loadTags() {
        guard let data = try? Data(contentsOf: tagFileURL),
              let decoded = try? JSONDecoder().decode([String: UserVoiceTag].self, from: data) else { return }
        
        // Convert string keys back to Int32
        for (key, value) in decoded {
            if let sid = Int32(key) {
                tags[sid] = value
            }
        }
    }

    func saveTags() {
        // Convert Int32 keys to String for JSON
        var toSave: [String: UserVoiceTag] = [:]
        for (sid, tag) in tags {
            toSave["\(sid)"] = tag
        }
        if let data = try? JSONEncoder().encode(toSave) {
            try? data.write(to: tagFileURL)
        }
    }

    func getTag(for sid: Int32) -> UserVoiceTag? {
        return tags[sid]
    }

    func setTag(for sid: Int32, tag: UserVoiceTag) {
        tags[sid] = tag
        saveTags()
    }
}

//
//  ProjectStore.swift
//  VoiceOverStudio
//
//  SQLite persistence for narration work. One database under
//  ~/Library/vos2026/store.sqlite is the single source of truth:
//
//    projects    a named body of work ("Mojo review")
//    clips       video attachments within a project ("" = free transcript)
//    narrations  voice-overs keyed to a clip: text, voice, start time
//    voice_takes the actual WAV bytes + measured duration per voice-over
//
//  Project <-many-> clips <-many-> voice-overs. Both the transcript editor
//  and the video timeline read and write the active clip through this store,
//  so they cannot disagree. Writes are transactional; deletes cascade.
//

import Foundation
import SQLite3

struct ProjectSummary {
    let id: Int64
    let name: String
}

struct ProjectListing {
    let id: Int64
    let name: String
    let updatedAt: Date
    let clipCount: Int
    let voiceOverCount: Int
}

struct ClipSummary {
    let id: Int64
    let videoPath: String
    var isTranscript: Bool { videoPath.isEmpty }
    var displayName: String {
        isTranscript ? "Transcript (voice only)" : URL(fileURLWithPath: videoPath).lastPathComponent
    }
}

/// A clip with its working statistics, for the clip manager.
struct ClipListing {
    let id: Int64
    let videoPath: String
    let workspacePath: String?
    let voiceOverCount: Int
    let voicedSeconds: Double
    let recordedCount: Int
    let updatedAt: Date

    var isTranscript: Bool { videoPath.isEmpty }
    var displayName: String {
        isTranscript ? "Transcript (voice only)" : URL(fileURLWithPath: videoPath).lastPathComponent
    }
}

struct ClipRecord {
    var clipID: Int64?
    var videoPath: String
    var workspacePath: String?
    var originalAudioVolume: Double
    var paragraphs: [Paragraph]
    /// Measured voice durations straight from voice_takes.
    var voiceDurations: [UUID: Double] = [:]
}

final class ProjectStore {
    private var db: OpaquePointer?

    static let databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/vos2026/store.sqlite", isDirectory: false)

    init?(databaseURL: URL = ProjectStore.databaseURL) {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle
        else {
            debugLog("DEBUG:: [Store] Could not open \(databaseURL.path)")
            return nil
        }
        db = opened
        sqlite3_busy_timeout(db, 5_000)
        guard execute("PRAGMA journal_mode=WAL;"),
              execute("PRAGMA foreign_keys=ON;"),
              migrateIfNeeded()
        else {
            sqlite3_close_v2(db)
            db = nil
            return nil
        }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Schema (v2: projects -> clips -> narrations -> voice_takes)

    private func createSchema() -> Bool {
        execute("""
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS clips (
            id                    INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id            INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            video_path            TEXT NOT NULL,
            workspace_path        TEXT,
            original_audio_volume REAL NOT NULL DEFAULT 0,
            created_at            REAL NOT NULL,
            updated_at            REAL NOT NULL,
            UNIQUE(project_id, video_path)
        );
        CREATE TABLE IF NOT EXISTS narrations (
            id              TEXT PRIMARY KEY,
            clip_id         INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            position        INTEGER NOT NULL,
            text            TEXT NOT NULL DEFAULT '',
            voice_id        TEXT NOT NULL DEFAULT 'narrator_clear',
            gap_duration    REAL NOT NULL DEFAULT 0.5,
            start_time      REAL,
            is_recorded     INTEGER NOT NULL DEFAULT 0,
            speed           TEXT NOT NULL DEFAULT 'normal',
            pitch           TEXT NOT NULL DEFAULT 'normal',
            output_filename TEXT NOT NULL DEFAULT '',
            audio_path      TEXT,
            created_at      REAL NOT NULL,
            updated_at      REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS narrations_by_clip ON narrations(clip_id, position);
        CREATE TABLE IF NOT EXISTS voice_takes (
            narration_id TEXT PRIMARY KEY REFERENCES narrations(id) ON DELETE CASCADE,
            format       TEXT NOT NULL DEFAULT 'wav',
            sample_rate  REAL NOT NULL DEFAULT 24000,
            duration     REAL NOT NULL,
            byte_count   INTEGER NOT NULL,
            file_mtime   REAL NOT NULL DEFAULT 0,
            wav          BLOB NOT NULL,
            created_at   REAL NOT NULL,
            updated_at   REAL NOT NULL
        );
        """)
    }

    // MARK: - Meta / active state

    private func metaGet(_ key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?1", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement,
              sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW
        else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    private func metaSet(_ key: String, _ value: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        stepDone(stmt)
    }

    var currentProjectID: Int64? {
        metaGet("currentProjectId").flatMap(Int64.init)
    }

    var currentClipID: Int64? {
        metaGet("currentClipId").flatMap(Int64.init)
    }

    func setActive(projectID: Int64?, clipID: Int64?) {
        metaSet("currentProjectId", projectID.map(String.init) ?? "")
        metaSet("currentClipId", clipID.map(String.init) ?? "")
    }

    // MARK: - Projects

    func project(id: Int64) -> ProjectSummary? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id, name FROM projects WHERE id = ?1", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return nil }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ProjectSummary(id: sqlite3_column_int64(stmt, 0), name: columnText(stmt, 1) ?? "Untitled")
    }

    @discardableResult
    func newProject(name: String) -> Int64 {
        let now = Date().timeIntervalSince1970
        execute("INSERT INTO projects(name, created_at, updated_at) VALUES(?1, ?2, ?2);", bindings: { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now)
        })
        let id = queryInt64("SELECT last_insert_rowid();") ?? 0
        setActive(projectID: id, clipID: nil)
        return id
    }

    /// All projects, most recently touched first — the Open dialog and the
    /// Recent submenu.
    func listProjects() -> [ProjectListing] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT p.id, p.name, p.updated_at,
               (SELECT COUNT(*) FROM clips c WHERE c.project_id = p.id),
               (SELECT COUNT(*) FROM narrations n JOIN clips c ON n.clip_id = c.id WHERE c.project_id = p.id)
        FROM projects p
        ORDER BY p.updated_at DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return [] }
        var result: [ProjectListing] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ProjectListing(
                id: sqlite3_column_int64(stmt, 0),
                name: columnText(stmt, 1) ?? "Untitled",
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                clipCount: Int(sqlite3_column_int64(stmt, 3)),
                voiceOverCount: Int(sqlite3_column_int64(stmt, 4))
            ))
        }
        return result
    }

    /// Bump a project to the top of the recency order.
    func touchProject(id: Int64) {
        execute("UPDATE projects SET updated_at = ?1 WHERE id = ?2;", bindings: { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, id)
        })
    }

    func renameProject(id: Int64, name: String) {
        execute("UPDATE projects SET name = ?1, updated_at = ?2 WHERE id = ?3;", bindings: { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, id)
        })
    }

    /// The clips of a project, transcript clip first.
    func clips(inProject projectID: Int64) -> [ClipSummary] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT id, video_path FROM clips WHERE project_id = ?1 ORDER BY (video_path = '') DESC, video_path", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return [] }
        sqlite3_bind_int64(stmt, 1, projectID)
        var result: [ClipSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ClipSummary(id: sqlite3_column_int64(stmt, 0), videoPath: columnText(stmt, 1) ?? ""))
        }
        return result
    }

    // MARK: - Clips

    /// Clips of a project with counts and voiced durations, transcript first.
    func clipListings(projectID: Int64) -> [ClipListing] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT c.id, c.video_path, c.workspace_path, c.updated_at,
               (SELECT COUNT(*) FROM narrations n WHERE n.clip_id = c.id),
               (SELECT COALESCE(SUM(t.duration), 0) FROM narrations n
                  LEFT JOIN voice_takes t ON t.narration_id = n.id
                  WHERE n.clip_id = c.id),
               (SELECT COUNT(*) FROM narrations n WHERE n.clip_id = c.id AND n.is_recorded = 1)
        FROM clips c
        WHERE c.project_id = ?1
        ORDER BY (c.video_path = '') DESC, c.video_path;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return [] }
        sqlite3_bind_int64(stmt, 1, projectID)
        var result: [ClipListing] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(ClipListing(
                id: sqlite3_column_int64(stmt, 0),
                videoPath: columnText(stmt, 1) ?? "",
                workspacePath: columnText(stmt, 2),
                voiceOverCount: Int(sqlite3_column_int64(stmt, 4)),
                voicedSeconds: sqlite3_column_double(stmt, 5),
                recordedCount: Int(sqlite3_column_int64(stmt, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            ))
        }
        return result
    }

    /// Delete a clip; its narrations and voice blobs cascade.
    func deleteClip(id: Int64) {
        execute("DELETE FROM clips WHERE id = ?1;", bindings: { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        })
    }

    func findClipID(projectID: Int64, videoPath: String) -> Int64? {
        queryInt64("SELECT id FROM clips WHERE project_id = ?1 AND video_path = ?2", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, projectID)
            sqlite3_bind_text(stmt, 2, videoPath, -1, SQLITE_TRANSIENT)
        })
    }

    /// Insert-or-update a clip (row + narrations + voice blobs, removing
    /// narrations that vanished) in one transaction. Returns the clip id.
    @discardableResult
    func upsertClip(projectID: Int64, record: ClipRecord) -> Int64? {
        let now = Date().timeIntervalSince1970
        execute("BEGIN IMMEDIATE;")
        execute("""
        INSERT INTO clips(project_id, video_path, workspace_path, original_audio_volume, created_at, updated_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?5)
        ON CONFLICT(project_id, video_path) DO UPDATE SET
            workspace_path = excluded.workspace_path,
            original_audio_volume = excluded.original_audio_volume,
            updated_at = excluded.updated_at;
        """, bindings: { stmt in
            sqlite3_bind_int64(stmt, 1, projectID)
            sqlite3_bind_text(stmt, 2, record.videoPath, -1, SQLITE_TRANSIENT)
            record.workspacePath.map { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 3)
            sqlite3_bind_double(stmt, 4, record.originalAudioVolume)
            sqlite3_bind_double(stmt, 5, now)
        })
        guard let clipId = queryInt64("SELECT id FROM clips WHERE project_id = ?1 AND video_path = ?2", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, projectID)
            sqlite3_bind_text(stmt, 2, record.videoPath, -1, SQLITE_TRANSIENT)
        }) else {
            execute("ROLLBACK;")
            return nil
        }

        // An empty save must not wipe a populated clip (delete-all will get
        // its own explicit path); bail instead.
        let existingCount = queryInt64("SELECT COUNT(*) FROM narrations WHERE clip_id = ?1", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, clipId)
        }) ?? 0
        if record.paragraphs.isEmpty && existingCount > 0 {
            execute("ROLLBACK;")
            debugLog("DEBUG:: [Store] Refused to empty clip \(clipId) (had \(existingCount) narrations)")
            return clipId
        }

        // Narration ids belong to the clip that created them: a paragraph
        // whose id already lives in ANOTHER clip is a copy carried between
        // clips — give it a fresh id here instead of re-homing the original.
        let foreignIDs = queryStringSet("SELECT id FROM narrations WHERE clip_id != ?1", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, clipId)
        })

        var seenIDs = Set<String>()
        for (index, paragraph) in record.paragraphs.enumerated() {
            var working = paragraph
            var idString = paragraph.id.uuidString
            if foreignIDs.contains(idString) {
                let fresh = UUID()
                if working.outputFilename.isEmpty || working.outputFilename.hasPrefix("clip_") {
                    working.outputFilename = "clip_\(fresh.uuidString).wav"
                }
                idString = fresh.uuidString
            }
            seenIDs.insert(idString)
            upsertNarration(working, idString: idString, clipId: clipId, position: index, now: now)
            syncVoiceTake(working, idString: idString, now: now)
        }
        let existingIDs = queryStringSet("SELECT id FROM narrations WHERE clip_id = ?1", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, clipId)
        })
        for removed in existingIDs.subtracting(seenIDs) {
            execute("DELETE FROM narrations WHERE id = ?1", bindings: { stmt in
                sqlite3_bind_text(stmt, 1, removed, -1, SQLITE_TRANSIENT)
            })
        }
        execute("COMMIT;")
        return clipId
    }

    private func upsertNarration(_ paragraph: Paragraph, idString: String, clipId: Int64, position: Int, now: Double) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        INSERT INTO narrations(id, clip_id, position, text, voice_id, gap_duration, start_time,
                               is_recorded, speed, pitch, output_filename, audio_path, created_at, updated_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13)
        ON CONFLICT(id) DO UPDATE SET
            position = excluded.position, text = excluded.text,
            voice_id = excluded.voice_id, gap_duration = excluded.gap_duration, start_time = excluded.start_time,
            is_recorded = excluded.is_recorded, speed = excluded.speed, pitch = excluded.pitch,
            output_filename = excluded.output_filename, audio_path = excluded.audio_path,
            updated_at = excluded.updated_at;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return }
        sqlite3_bind_text(stmt, 1, idString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, clipId)
        sqlite3_bind_int64(stmt, 3, Int64(position))
        sqlite3_bind_text(stmt, 4, paragraph.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, paragraph.voiceID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, paragraph.gapDuration)
        paragraph.startTime.map { sqlite3_bind_double(stmt, 7, $0) } ?? sqlite3_bind_null(stmt, 7)
        sqlite3_bind_int(stmt, 8, paragraph.isRecorded ? 1 : 0)
        sqlite3_bind_text(stmt, 9, paragraph.speed.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, paragraph.pitch.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, paragraph.outputFilename, -1, SQLITE_TRANSIENT)
        paragraph.audioPath.map { sqlite3_bind_text(stmt, 12, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, 12)
        sqlite3_bind_double(stmt, 13, now)
        stepDone(stmt)
    }

    /// Store the WAV bytes for a narration when its file is new or changed.
    /// The byte_count + file_mtime pair keeps repeated saves cheap.
    private func syncVoiceTake(_ paragraph: Paragraph, idString: String, now: Double) {
        guard let path = paragraph.audioPath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return }

        if let storedSize = queryInt64("SELECT byte_count FROM voice_takes WHERE narration_id = ?1", bind: {
            sqlite3_bind_text($0, 1, idString, -1, SQLITE_TRANSIENT)
        }), let storedMtime = queryOptionalDouble("SELECT file_mtime FROM voice_takes WHERE narration_id = ?1", bind: {
            sqlite3_bind_text($0, 1, idString, -1, SQLITE_TRANSIENT)
        }), storedSize == fileSize, abs(storedMtime - mtime) < 0.001 {
            return // unchanged take
        }

        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return }
        let info = Self.wavInfo(data)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        INSERT INTO voice_takes(narration_id, format, sample_rate, duration, byte_count, file_mtime, wav, created_at, updated_at)
        VALUES(?1, 'wav', ?2, ?3, ?4, ?5, ?6, ?7, ?7)
        ON CONFLICT(narration_id) DO UPDATE SET
            sample_rate = excluded.sample_rate, duration = excluded.duration,
            byte_count = excluded.byte_count, file_mtime = excluded.file_mtime,
            wav = excluded.wav, updated_at = excluded.updated_at;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return }
        sqlite3_bind_text(stmt, 1, idString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, info?.sampleRate ?? 24000)
        sqlite3_bind_double(stmt, 3, info?.duration ?? 0)
        sqlite3_bind_int64(stmt, 4, fileSize)
        sqlite3_bind_double(stmt, 5, mtime)
        data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(stmt, 7, now)
        stepDone(stmt)
    }

    /// Load a clip: its narrations (blob takes materialized back out as WAV
    /// files in the workspace cache) and measured durations.
    func loadClip(clipID: Int64) -> ClipRecord? {
        var videoPath = ""
        var workspacePath: String?
        var volume: Double = 0
        var header: OpaquePointer?
        defer { sqlite3_finalize(header) }
        guard sqlite3_prepare_v2(db, "SELECT video_path, workspace_path, original_audio_volume FROM clips WHERE id = ?1", -1, &header, nil) == SQLITE_OK,
              let hdr = header
        else { return nil }
        sqlite3_bind_int64(hdr, 1, clipID)
        guard sqlite3_step(hdr) == SQLITE_ROW else { return nil }
        videoPath = columnText(hdr, 0) ?? ""
        workspacePath = columnText(hdr, 1)
        volume = sqlite3_column_double(hdr, 2)
        if let recorded = workspacePath, !FileManager.default.fileExists(atPath: recorded) {
            workspacePath = nil
        }

        var paragraphs: [Paragraph] = []
        var durations: [UUID: Double] = [:]
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT n.id, n.text, n.voice_id, n.gap_duration, n.start_time, n.is_recorded, n.speed, n.pitch,
               n.output_filename, n.audio_path, t.duration, t.wav
        FROM narrations n LEFT JOIN voice_takes t ON t.narration_id = n.id
        WHERE n.clip_id = ?1
        ORDER BY n.position;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return nil }
        sqlite3_bind_int64(stmt, 1, clipID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idString = columnText(stmt, 0) ?? UUID().uuidString
            let text = columnText(stmt, 1) ?? ""
            let voiceID = columnText(stmt, 2) ?? "narrator_clear"
            let gap = sqlite3_column_double(stmt, 3)
            let startTime = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4)
            let recorded = sqlite3_column_int(stmt, 5) != 0
            let speed = Paragraph.SpeedPreset(rawValue: columnText(stmt, 6) ?? "normal") ?? .normal
            let pitch = Paragraph.PitchPreset(rawValue: columnText(stmt, 7) ?? "normal") ?? .normal
            let outputFilename = columnText(stmt, 8) ?? ""
            var audioPath = columnText(stmt, 9)
            let takeDuration = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10)

            // The blob is the truth; the file is a cache.
            if sqlite3_column_type(stmt, 11) == SQLITE_BLOB {
                let blobLength = Int(sqlite3_column_bytes(stmt, 11))
                if blobLength > 0, let bytes = sqlite3_column_blob(stmt, 11) {
                    let data = Data(bytes: bytes, count: blobLength)
                    let cacheURL = materializationURL(idString: idString, videoPath: videoPath, workspacePath: workspacePath, fallback: audioPath)
                    let cachedSize = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.size] as? NSNumber
                    if cachedSize?.int64Value != Int64(blobLength) {
                        try? data.write(to: cacheURL, options: .atomic)
                    }
                    audioPath = cacheURL.path
                }
            } else if let path = audioPath, !FileManager.default.fileExists(atPath: path) {
                audioPath = nil
            }

            let id = UUID(uuidString: idString) ?? UUID()
            if let takeDuration, takeDuration > 0 {
                durations[id] = takeDuration
            }
            paragraphs.append(Paragraph(
                id: id,
                text: text,
                voiceID: voiceID,
                gapDuration: gap,
                startTime: startTime,
                isRecorded: recorded,
                speed: speed,
                pitch: pitch,
                audioPath: audioPath,
                isGenerating: false,
                outputFilename: outputFilename
            ))
        }

        return ClipRecord(
            clipID: clipID,
            videoPath: videoPath,
            workspacePath: workspacePath,
            originalAudioVolume: volume,
            paragraphs: paragraphs,
            voiceDurations: durations
        )
    }

    /// Deterministic cache location for a stored take.
    private func materializationURL(idString: String, videoPath: String, workspacePath: String?, fallback: String?) -> URL {
        let fileName = "clip_\(idString).wav"
        if let workspacePath {
            let directory = URL(fileURLWithPath: workspacePath)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
        if videoPath.isEmpty {
            // Voice-only clip: cache beside the app's own store.
            let directory = Self.databaseURL.deletingLastPathComponent().appendingPathComponent("transcript-audio", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
        if let fallback, !fallback.isEmpty {
            return URL(fileURLWithPath: fallback)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Migration

    private func migrateIfNeeded() -> Bool {
        let version = metaGet("schemaVersion")
        if version == "2" {
            // Schema creation must come after any v1 rename: CREATE TABLE IF
            // NOT EXISTS would silently keep the old table shapes and the new
            // indexes would then fail against missing columns.
            return createSchema()
        }
        if version == "1" {
            guard migrateV1ToV2() else { return false }
        } else {
            guard createSchema() else { return false }
            migrateLegacyJSON()
        }
        metaSet("schemaVersion", "2")
        return true
    }

    /// v1 keyed projects by video path with no project entity. Each v1
    /// project becomes a named project with one clip. The v1 "" default
    /// project held the newest working set, so when the current video's rows
    /// were lost (a known v1 wipe bug) they are recovered from it.
    private func migrateV1ToV2() -> Bool {
        guard !tableExists("v1_projects") else { return true }
        execute("PRAGMA foreign_keys=OFF;")
        execute("ALTER TABLE voice_takes RENAME TO v1_takes;")
        execute("ALTER TABLE narrations RENAME TO v1_narrations;")
        execute("ALTER TABLE projects RENAME TO v1_projects;")
        createSchema()

        let currentVideoPath = metaGet("currentVideoPath") ?? ""
        var projectForVideoPath: [String: Int64] = [:]
        var clipForVideoPath: [String: Int64] = [:]
        var defaultParagraphs: [Paragraph] = []

        func v1Paragraphs(projectRowID: Int64) -> [Paragraph] {
            var paragraphs: [Paragraph] = []
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
            SELECT id, text, voice_id, gap_duration, start_time, is_recorded, speed, pitch,
                   output_filename, audio_path
            FROM v1_narrations WHERE project_id = ?1 ORDER BY position;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else { return [] }
            sqlite3_bind_int64(stmt, 1, projectRowID)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idString = columnText(stmt, 0) ?? UUID().uuidString
                paragraphs.append(Paragraph(
                    id: UUID(uuidString: idString) ?? UUID(),
                    text: columnText(stmt, 1) ?? "",
                    voiceID: columnText(stmt, 2) ?? "narrator_clear",
                    gapDuration: sqlite3_column_double(stmt, 3),
                    startTime: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4),
                    isRecorded: sqlite3_column_int(stmt, 5) != 0,
                    speed: Paragraph.SpeedPreset(rawValue: columnText(stmt, 6) ?? "normal") ?? .normal,
                    pitch: Paragraph.PitchPreset(rawValue: columnText(stmt, 7) ?? "normal") ?? .normal,
                    audioPath: columnText(stmt, 9),
                    isGenerating: false,
                    outputFilename: columnText(stmt, 8) ?? ""
                ))
            }
            return paragraphs
        }

        var rows: OpaquePointer?
        defer { sqlite3_finalize(rows) }
        guard sqlite3_prepare_v2(db, "SELECT id, video_path, workspace_path, original_audio_volume FROM v1_projects", -1, &rows, nil) == SQLITE_OK,
              let cursor = rows
        else {
            execute("PRAGMA foreign_keys=ON;")
            return true
        }
        var pending: [(videoPath: String, workspace: String?, volume: Double, paragraphs: [Paragraph])] = []
        while sqlite3_step(cursor) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(cursor, 0)
            let videoPath = columnText(cursor, 1) ?? ""
            let workspace = columnText(cursor, 2)
            let volume = sqlite3_column_double(cursor, 3)
            let paragraphs = v1Paragraphs(projectRowID: rowID)
            if videoPath.isEmpty {
                if paragraphs.count > defaultParagraphs.count {
                    defaultParagraphs = paragraphs
                }
            } else if FileManager.default.fileExists(atPath: videoPath) {
                pending.append((videoPath, workspace, volume, paragraphs))
            }
        }

        for entry in pending {
            let name = URL(fileURLWithPath: entry.videoPath).deletingPathExtension().lastPathComponent
            execute("INSERT INTO projects(name, created_at, updated_at) VALUES(?1, ?2, ?2);", bindings: { stmt in
                sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            })
            guard let projectID = queryInt64("SELECT last_insert_rowid();") else { continue }
            projectForVideoPath[entry.videoPath] = projectID
            if let clipID = upsertClip(projectID: projectID, record: ClipRecord(
                clipID: nil,
                videoPath: entry.videoPath,
                workspacePath: entry.workspace,
                originalAudioVolume: entry.volume,
                paragraphs: entry.paragraphs
            )) {
                clipForVideoPath[entry.videoPath] = clipID
            }
        }

        // Recover the "" default rows into the current video's clip when they
        // carry more than what survived there.
        var recovered = false
        if !currentVideoPath.isEmpty,
           let clipID = clipForVideoPath[currentVideoPath],
           let projectID = projectForVideoPath[currentVideoPath],
           !defaultParagraphs.isEmpty {
            let existing = queryInt64("SELECT COUNT(*) FROM narrations WHERE clip_id = ?1", bind: { sqlite3_bind_int64($0, 1, clipID) }) ?? 0
            if existing < Int64(defaultParagraphs.count) {
                _ = upsertClip(projectID: projectID, record: ClipRecord(
                    clipID: clipID,
                    videoPath: currentVideoPath,
                    workspacePath: nil,
                    originalAudioVolume: 0,
                    paragraphs: defaultParagraphs
                ))
                recovered = true
            }
        }
        if !recovered, !defaultParagraphs.isEmpty {
            let projectID = newProject(name: "Transcript")
            _ = upsertClip(projectID: projectID, record: ClipRecord(
                clipID: nil,
                videoPath: "",
                workspacePath: nil,
                originalAudioVolume: 0,
                paragraphs: defaultParagraphs
            ))
        }

        // Voice blobs carry over unchanged; narration ids are stable.
        execute("INSERT OR IGNORE INTO voice_takes SELECT * FROM v1_takes WHERE narration_id IN (SELECT id FROM narrations);")
        execute("DROP TABLE v1_takes;")
        execute("DROP TABLE v1_narrations;")
        execute("DROP TABLE v1_projects;")
        execute("PRAGMA foreign_keys=ON;")

        if !currentVideoPath.isEmpty, let projectID = projectForVideoPath[currentVideoPath] {
            setActive(projectID: projectID, clipID: clipForVideoPath[currentVideoPath])
        } else if let first = queryInt64("SELECT id FROM projects ORDER BY id LIMIT 1;") {
            setActive(projectID: first, clipID: nil)
        }
        debugLog("DEBUG:: [Store] v1 database migrated to projects/clips/v2")
        return true
    }

    /// Import the pre-SQLite JSON era. Runs once on a pristine database.
    private func migrateLegacyJSON() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let workspacesRoot = home.appendingPathComponent("Documents/voiceover", isDirectory: true)
        var latest: (path: String, savedAt: Date)?

        if let folders = try? FileManager.default.contentsOfDirectory(at: workspacesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let jsonURL = folder.appendingPathComponent("project.json", isDirectory: false)
                guard let data = try? Data(contentsOf: jsonURL),
                      let legacy = try? JSONDecoder().decode(LegacyVideoProject.self, from: data),
                      FileManager.default.fileExists(atPath: legacy.videoPath)
                else { continue }
                let projectID = newProject(name: URL(fileURLWithPath: legacy.videoPath).deletingPathExtension().lastPathComponent)
                _ = upsertClip(projectID: projectID, record: ClipRecord(
                    clipID: nil,
                    videoPath: legacy.videoPath,
                    workspacePath: folder.path,
                    originalAudioVolume: legacy.originalAudioVolume,
                    paragraphs: legacy.paragraphs
                ))
                if let best = latest, best.savedAt >= legacy.savedAt {
                    // keep the latest
                } else {
                    latest = (legacy.videoPath, legacy.savedAt)
                }
            }
        }

        let referenceURL = home.appendingPathComponent("Library/vos2026/video-reference.json", isDirectory: false)
        var currentPath: String?
        if let data = try? Data(contentsOf: referenceURL),
           let reference = try? JSONDecoder().decode(LegacyVideoReference.self, from: data),
           let path = reference.videoPath, FileManager.default.fileExists(atPath: path) {
            currentPath = path
        } else {
            currentPath = latest?.path
        }

        if let currentPath,
           let projectID = queryInt64("SELECT p.id FROM projects p JOIN clips c ON c.project_id = p.id WHERE c.video_path = ?1", bind: { sqlite3_bind_text($0, 1, currentPath, -1, SQLITE_TRANSIENT) }) {
            setActive(projectID: projectID, clipID: findClipID(projectID: projectID, videoPath: currentPath))
        } else if let first = queryInt64("SELECT id FROM projects ORDER BY id LIMIT 1;") {
            setActive(projectID: first, clipID: nil)
        }
        debugLog("DEBUG:: [Store] Legacy JSON data migrated into \(Self.databaseURL.path) (voice blobs included)")
    }

    private func tableExists(_ name: String) -> Bool {
        queryInt64("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1", bind: {
            sqlite3_bind_text($0, 1, name, -1, SQLITE_TRANSIENT)
        }) ?? 0 > 0
    }

    // MARK: - WAV header parsing (blob metadata)

    /// (sample rate, duration in seconds) from a RIFF/WAVE header.
    static func wavInfo(_ data: Data) -> (sampleRate: Double, duration: Double)? {
        func u16(_ offset: Int) -> Int {
            Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int {
            u16(offset) | (u16(offset + 2) << 16)
        }
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8)
        else { return nil }

        var sampleRate = 0.0
        var channels = 1
        var bits = 16
        var dataSize = 0
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = data[data.startIndex + offset..<data.startIndex + offset + 4]
            let size = u32(offset + 4)
            if chunkID == Data("fmt ".utf8), offset + 8 + 16 <= data.count {
                channels = max(1, u16(offset + 10))
                sampleRate = Double(u32(offset + 12))
                bits = max(8, u16(offset + 22))
            } else if chunkID == Data("data".utf8) {
                dataSize = size > 0 ? size : max(0, data.count - offset - 8)
            }
            offset += 8 + size + (size & 1)
        }
        guard sampleRate > 0, dataSize > 0 else { return nil }
        let bytesPerFrame = max(1, channels * bits / 8)
        return (sampleRate, Double(dataSize) / (sampleRate * Double(bytesPerFrame)))
    }

    // MARK: - SQLite plumbing

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement else { return nil }
        return sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    @discardableResult
    private func execute(_ sql: String, bindings: ((OpaquePointer) -> Void)? = nil) -> Bool {
        guard bindings == nil else {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let prepared = statement
            else {
                debugLog("DEBUG:: [Store] Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            bindings?(prepared)
            guard sqlite3_step(prepared) == SQLITE_DONE else {
                debugLog("DEBUG:: [Store] Step failed: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(100))")
                return false
            }
            return true
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            debugLog("DEBUG:: [Store] Exec failed: \(message) — \(sql.prefix(100))")
            sqlite3_free(errorPointer)
            return false
        }
        return true
    }

    private func stepDone(_ statement: OpaquePointer?) {
        guard let statement, sqlite3_step(statement) == SQLITE_DONE else {
            debugLog("DEBUG:: [Store] Statement failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    private func queryInt64(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return nil }
        bind?(stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func queryOptionalDouble(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) -> Double? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return nil }
        bind?(stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : nil
    }

    private func queryStringSet(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let stmt = statement
        else { return [] }
        bind?(stmt)
        var result = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = columnText(stmt, 0) {
                result.insert(text)
            }
        }
        return result
    }
}

// MARK: - Legacy JSON shapes (migration only; the files stay behind as backups)

struct LegacyVideoProject: Codable {
    var videoPath: String
    var originalAudioVolume: Double
    var paragraphs: [Paragraph]
    var savedAt: Date
}

struct LegacyVideoReference: Codable {
    var videoPath: String?
    var originalAudioVolume: Double?
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

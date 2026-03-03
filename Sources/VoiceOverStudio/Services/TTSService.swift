//
//  TTSService.swift
//  VoiceOverStudio
//

import Foundation
import SherpaOnnxC
import UniformTypeIdentifiers

/// Helper: convert Swift String to UnsafePointer<CChar> that stays valid
/// for the lifetime of the enclosing scope (backed by NSString).
private func cstr(_ s: String) -> UnsafePointer<CChar> {
    return (s as NSString).utf8String!
}

/// Wrapper to shuttle the OpaquePointer across sendability boundaries.
/// Safety: the TTS pointer is allocated once and never freed during the
/// lifetime of TTSService, so this is effectively safe.
private struct UncheckedSendableTTS: @unchecked Sendable {
    let value: OpaquePointer
}

@MainActor
class TTSService: ObservableObject {
    private var tts: OpaquePointer?  // SherpaOnnxOfflineTts*
    /// Keep strong refs to NSStrings used in the config so their .utf8String
    /// pointers remain valid for the lifetime of the TTS engine.
    private var configStrings: [NSString] = []
    private var speakerOptions: [VoiceOption] = []
    private let voiceTagService = VoiceTagService.shared
    private let fileManager = FileManager.default

    deinit {
        // Do NOT call SherpaOnnxDestroyOfflineTts here.
        // During process teardown the ONNX runtime is already partially
        // deallocated, so touching the pointer triggers SIGABRT.
        // The OS reclaims all memory on exit.
    }
    
    func shutdown() {
        if let tts = tts {
            SherpaOnnxDestroyOfflineTts(tts)
            self.tts = nil
        }
        configStrings.removeAll()
        speakerOptions.removeAll()
    }

    /// Pin a String and return its C pointer.  The NSString is retained in
    /// `configStrings` so the pointer stays valid until the engine is destroyed.
    private func pin(_ s: String) -> UnsafePointer<CChar> {
        let ns = s as NSString
        configStrings.append(ns)
        return ns.utf8String!
    }

    /// Initialize the TTS engine with model paths.
    /// modelPath  = path to the VITS .onnx file
    /// tokensPath = path to tokens.txt
    /// dataDir    = optional espeak-ng-data directory
    func initializeTTS(modelPath: String, tokensPath: String, dataDir: String = "", lexicon: String = "") async throws {
        // Clean up previous instance
        if let prev = tts { SherpaOnnxDestroyOfflineTts(prev); self.tts = nil }
        configStrings.removeAll()
        speakerOptions.removeAll()

        // Use lexicon-based approach (e.g. vits-vctk) or espeak-ng-data approach
        let resolvedDataDir: String
        if !lexicon.isEmpty && FileManager.default.fileExists(atPath: lexicon) {
            resolvedDataDir = ""  // lexicon model; no espeak needed
        } else {
            resolvedDataDir = resolveDataDir(modelPath: modelPath, providedDataDir: dataDir)
        }
        let resolvedLexicon = (!lexicon.isEmpty && FileManager.default.fileExists(atPath: lexicon)) ? lexicon : ""

        // Build VITS sub-config
        let vits = SherpaOnnxOfflineTtsVitsModelConfig(
            model:        pin(modelPath),
            lexicon:      pin(resolvedLexicon),
            tokens:       pin(tokensPath),
            data_dir:     pin(resolvedDataDir),
            noise_scale:  0.667,
            noise_scale_w: 0.8,
            length_scale: 1.0,
            dict_dir:     pin("")
        )

        // Model config – only VITS populated; others stay zeroed
        let e = pin("")
        let emptyMatcha = SherpaOnnxOfflineTtsMatchaModelConfig(
            acoustic_model: e, vocoder: e, lexicon: e, tokens: e, data_dir: e,
            noise_scale: 0, length_scale: 0, dict_dir: e
        )
        let emptyKokoro = SherpaOnnxOfflineTtsKokoroModelConfig(
            model: e, voices: e, tokens: e, data_dir: e,
            length_scale: 0, dict_dir: e, lexicon: e, lang: e
        )
        let emptyKitten = SherpaOnnxOfflineTtsKittenModelConfig(
            model: e, voices: e, tokens: e, data_dir: e, length_scale: 0
        )
        let emptyZipvoice = SherpaOnnxOfflineTtsZipvoiceModelConfig(
            tokens: e, encoder: e, decoder: e, vocoder: e,
            data_dir: e, lexicon: e, feat_scale: 0, t_shift: 0,
            target_rms: 0, guidance_scale: 0
        )
        let emptyPocket = SherpaOnnxOfflineTtsPocketModelConfig(
            lm_flow: e, lm_main: e, encoder: e, decoder: e,
            text_conditioner: e, vocab_json: e, token_scores_json: e,
            voice_embedding_cache_capacity: 0
        )

        let modelConfig = SherpaOnnxOfflineTtsModelConfig(
            vits: vits,
            num_threads: 4,
            debug: 1,
            provider: pin("cpu"),
            matcha: emptyMatcha,
            kokoro: emptyKokoro,
            kitten: emptyKitten,
            zipvoice: emptyZipvoice,
            pocket: emptyPocket
        )

        var config = SherpaOnnxOfflineTtsConfig(
            model: modelConfig,
            rule_fsts: pin(""),
            max_num_sentences: 1,
            rule_fars: pin(""),
            silence_scale: 0.2
        )

        self.tts = SherpaOnnxCreateOfflineTts(&config)
        guard self.tts != nil else {
            throw NSError(domain: "TTSService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create TTS engine"])
        }

        let sr = SherpaOnnxOfflineTtsSampleRate(self.tts)
        let ns = SherpaOnnxOfflineTtsNumSpeakers(self.tts)
        print("[TTS] Initialized – sample rate: \(sr), speakers: \(ns)")

        // Attempt to load speaker metadata and build user-friendly voice options
        speakerOptions = await loadSpeakerMetadata(modelPath: modelPath)
        seedVoiceTags(from: speakerOptions)
    }

    private func resolveDataDir(modelPath: String, providedDataDir: String) -> String {
        // If provided data dir exists and has espeak voices, use it
        if !providedDataDir.isEmpty,
           fileManager.fileExists(atPath: providedDataDir) {
            return providedDataDir
        }

        // Try sibling espeak-ng-data next to model
        let modelURL = URL(fileURLWithPath: modelPath)
        let candidate = modelURL.deletingLastPathComponent().appendingPathComponent("espeak-ng-data").path
        if fileManager.fileExists(atPath: candidate) {
            return candidate
        }

        // Try parent/espeak-ng-data (in case model is inside a subfolder)
        let parentCandidate = modelURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("espeak-ng-data").path
        if fileManager.fileExists(atPath: parentCandidate) {
            return parentCandidate
        }

        // Fall back to provided (even if empty) to keep API contract
        return providedDataDir
    }

    func generateAudio(text: String, outputFile: String, sid: Int32 = 0, speed: Float = 1.0, callback: ((Float) -> Void)? = nil) async -> Bool {
        // Apple voices removed; any negative sid is unsupported.
        if sid < 0 { return false }
        
        guard let tts = self.tts else {
            debugLog("DEBUG:: [TTS] Not initialized")
            return false
        }

        let actualNumSpeakers = SherpaOnnxOfflineTtsNumSpeakers(tts)
        debugLog("DEBUG:: ─────────────────────────────────────")
        debugLog("DEBUG:: [TTS] generateAudio called")
        debugLog("DEBUG:: [TTS]   sid passed to C API   : \(sid)")
        debugLog("DEBUG:: [TTS]   numSpeakers in model  : \(actualNumSpeakers)")
        debugLog("DEBUG:: [TTS]   speed                 : \(speed)")
        debugLog("DEBUG:: [TTS]   text (first 80)       : \(text.prefix(80))")
        debugLog("DEBUG:: [TTS]   outputFile            : \(outputFile)")

        // Run the heavy C work on a background thread to keep the UI responsive.
        let ttsPtr = UncheckedSendableTTS(value: tts)
        let result = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let audio = SherpaOnnxOfflineTtsGenerate(ttsPtr.value, text, sid, speed) else {
                debugLog("DEBUG:: [TTS] Generation returned nil")
                return false
            }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }

            let n = audio.pointee.n
            let sampleRate = audio.pointee.sample_rate
            debugLog("DEBUG:: [TTS]   result: \(n) samples @ \(sampleRate) Hz")
            guard n > 0, let samples = audio.pointee.samples else {
                debugLog("DEBUG:: [TTS] Empty audio generated")
                return false
            }

            let rc = SherpaOnnxWriteWave(samples, n, sampleRate, outputFile)
            debugLog("DEBUG:: [TTS]   wrote \(n) samples → \(outputFile) rc=\(rc)")
            return rc == 1
        }.value

        return result
    }

    var sampleRate: Int32 {
        guard let tts = tts else { return 22050 }
        return SherpaOnnxOfflineTtsSampleRate(tts)
    }

    var numSpeakers: Int32 {
        guard let tts = tts else { return 0 }
        return SherpaOnnxOfflineTtsNumSpeakers(tts)
    }

    /// SherpaOnnx C API doesn't expose a "get speaker name by ID" function for VITS models easily
    /// unless using a specific config, but some models (like VITS) might carry it. 
    /// However, typically for Vist-Piper models, it's just ID based. 
    /// If there was a speaker map file, we could parse it, but for now we'll just return generated names.
    func getAvailableVoices() -> [Dictionary<String, Any>] {
        let count = numSpeakers
        if !speakerOptions.isEmpty {
            return speakerOptions.map { ["id": $0.id, "name": $0.name, "sid": $0.sid] }
        }
        guard count > 0 else {
            return [["id": "narrator_f", "name": "Narrator F", "sid": Int32(0)]]
        }
        // Fallback: cap to first 120 to avoid unusable dropdowns
        let cap = min(count, Int32(120))
        return (0..<cap).map { i in ["id": "voice_\(i)", "name": "Voice \(i)", "sid": i] }
    }

    /// Direct accessor — avoids the fragile [String:Any] roundtrip in initializeEngines.
    var voiceOptionsList: [VoiceOption] {
          let count = max(numSpeakers, Int32(speakerOptions.count))
        guard count > 0 else {
              return [VoiceOption(id: "voice_0", name: "Voice 0", sid: 0)]
        }
        let cap = min(count, Int32(120))
        return (0..<cap).map { i in VoiceOption(id: "voice_\(i)", name: "Voice \(i)", sid: i) }
    }

    // MARK: - Speaker Metadata

    private func loadSpeakerMetadata(modelPath: String) async -> [VoiceOption] {
        let modelURL = URL(fileURLWithPath: modelPath)
        let isVCTK = modelURL.lastPathComponent.lowercased().contains("vctk")

        if isVCTK {
            return Self.vctkVoices
        }

        // Generic path: try to read a .json sidecar with speaker_id_map
        var voices: [VoiceOption] = []
        let jsonURL = modelURL.appendingPathExtension("json")
        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let speakerMap = json["speaker_id_map"] as? [String: Any] else {
            return voices
        }
        let speakerIds = speakerMap.keys.sorted { a, b in
            if let ai = Int(a), let bi = Int(b) { return ai < bi }
            return a < b
        }
        for (idx, sidStr) in speakerIds.enumerated() {
            voices.append(VoiceOption(id: sidStr, name: "Voice \(sidStr)", sid: Int32(idx)))
        }
        return voices
    }

    /// Pre-seed user voice tags (gender/accent) from model metadata if absent.
    private func seedVoiceTags(from options: [VoiceOption]) {
        for opt in options {
            // Skip if user already tagged this sid
            if voiceTagService.getTag(for: opt.sid) != nil { continue }

            // Expect names like "73: M · American — Indiana" from vctk table.
            guard let colon = opt.name.firstIndex(of: ":") else { continue }
            let meta = opt.name[opt.name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let parts = meta.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty else { continue }
            let gender = parts.first ?? ""
            let accent = parts.count > 1 ? parts[1] : ""

            var tag = UserVoiceTag()
            tag.gender = gender.isEmpty ? nil : gender
            tag.accent = accent.isEmpty ? nil : accent
            if tag.gender != nil || tag.accent != nil {
                voiceTagService.setTag(for: opt.sid, tag: tag)
            }
        }
    }

    // MARK: - Hardcoded VCTK speaker table (109 speakers, sid 0-108)
    // SIDs and metadata from the ground-truth vctk_audio_sid_text_train_filelist.txt.cleaned
    // used to train this exact model. Do NOT re-derive from sort order.
    static let vctkVoices: [VoiceOption] = {
        // (id, gender, region, sid)
        let table: [(String, String, String, Int32)] = [
            // ── Recommended ──────────────────────────────────────────────────
            ("★p225", "F", "★ S.England — clean prosody",    0),
            ("★p360", "M", "★ American — studio quality",   97),
            ("★p361", "F", "★ American — high fidelity",    98),
            ("★vctk", "–", "★ Averaged — stable default",  105),
            ("★p311", "M", "★ American — Indiana",          73),
            // ── All voices ───────────────────────────────────────────────────
            ("p225","F","S.England",        0), ("p226","M","Surrey",           1),
            ("p227","M","Cumbria",          2), ("p228","F","S.England",        3),
            ("p229","F","S.England",        4), ("p230","F","Stockton",         5),
            ("p231","F","S.England",        6), ("p232","M","S.England",        7),
            ("p233","F","Staffordshire",    8), ("p234","F","W.Dumfries",       9),
            ("p236","F","Manchester",      10), ("p237","M","Fife",            11),
            ("p238","F","Belfast",         12), ("p239","F","SW England",      13),
            ("p240","M","S.England",       14), ("p241","M","Perth",           15),
            ("p243","M","London",          16), ("p244","F","Manchester",      17),
            ("p245","M","Dublin",          18), ("p246","M","Selkirk",         19),
            ("p247","M","Argyll",          20), ("p248","F","India",           21),
            ("p250","F","SE England",      22), ("p251","M","India",           23),
            ("p252","M","Edinburgh",       24), ("p253","F","Cardiff",         25),
            ("p254","M","Surrey",          26), ("p255","M","Galloway",        27),
            ("p256","M","Birmingham",      28), ("p257","F","S.England",       29),
            ("p258","M","S.England",       30), ("p259","M","Nottingham",      31),
            ("p260","M","Orkney",          32), ("p261","F","Belfast",         33),
            ("p262","F","Edinburgh",       34), ("p263","M","Aberdeen",        35),
            ("p264","F","W.Lothian",       36), ("p265","F","Ross",            37),
            ("p266","M","Athlone",         38), ("p267","F","Yorkshire",       39),
            ("p268","F","S.England",       40), ("p269","F","Newcastle",       41),
            ("p270","M","Yorkshire",       42), ("p273","M","Suffolk",         43),
            ("p274","M","Essex",           44), ("p275","M","Midlothian",      45),
            ("p276","F","Oxford",          46), ("p277","F","NE England",      47),
            ("p278","M","Cheshire",        48), ("p279","M","Leicester",       49),
            ("p280","M","English",         50), ("p281","M","Edinburgh",       51),
            ("p282","F","Newcastle",       52), ("p283","F","Cork",            53),
            ("p284","M","Fife",            54), ("p285","M","Edinburgh",       55),
            ("p286","M","Newcastle",       56), ("p287","M","York",            57),
            ("p288","F","Dublin",          58), ("p292","M","Belfast",         59),
            ("p293","F","Belfast",         60), ("p294","F","San Francisco",   61),
            ("p295","F","Dublin",          62), ("p297","F","New York",        63),
            ("p298","M","Tipperary",       64), ("p299","F","California",      65),
            ("p303","F","Toronto",         66), ("p304","M","Belfast",         67),
            ("p305","F","Philadelphia",    68), ("p306","F","New York",        69),
            ("p307","F","Ontario",         70), ("p308","F","New Jersey",      71),
            ("p310","F","Virginia",        72), ("p311","M","Indiana",         73),
            ("p312","F","Maryland",        74), ("p313","F","N.Carolina",      75),
            ("p314","F","California",      76), ("p316","M","New Jersey",      77),
            ("p317","F","Georgia",         78), ("p318","M","Texas",           79),
            ("p323","F","Pretoria",        80), ("p326","M","Fife",            81),
            ("p329","F","New Jersey",      82), ("p330","M","California",      83),
            ("p333","F","Alabama",         84), ("p334","M","Ohio",            85),
            ("p315","M","California",      86), ("p319","F","New York",        87),
            ("p335","F","New York",        88), ("p336","F","California",      89),
            ("p339","F","Indiana",         90), ("p340","F","Illinois",        91),
            ("p341","F","California",      92), ("p343","M","New York",        93),
            ("p345","M","California",      94), ("p347","M","California",      95),
            ("p351","M","California",      96), ("p360","M","California",      97),
            ("p361","F","New York",        98), ("p362","F","California",      99),
            ("p363","M","California",     100), ("p364","M","California",     101),
            ("p374","M","California",     102), ("p376","M","California",     103),
            ("s5",  "M","Auxiliary",      104), ("vctk","–","Averaged",       105),
            ("p315b","M","California",    106), ("p319b","F","New York",      107),
            ("p326b","M","Fife",          108),
        ]
        return table.map { (id, gender, region, sid) in
            VoiceOption(id: id, name: "\(sid): \(gender) · \(region)", sid: sid)
        }
    }()

    // Legacy stubs kept so nothing else breaks
    private func ensureVCTKSpeakerInfo(near modelURL: URL) async -> URL? { return nil }

    private func parseVCTKSpeakerInfo(from url: URL) -> [String: (gender: String?, accent: String?)] {
        guard let text = try? String(contentsOf: url) else { return [:] }
        var result: [String: (String?, String?)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard !parts.isEmpty else { continue }
            let id = String(parts[0])
            let genderToken = parts.first(where: { $0 == "M" || $0 == "F" })
            let gender = genderToken.map { String($0) }
            var accent: String? = nil
            if let genderToken, let idx = parts.firstIndex(of: genderToken), idx + 1 < parts.count {
                accent = parts[(idx+1)...].joined(separator: " ")
            }
            result[id] = (gender, accent)
        }
        return result
    }

}

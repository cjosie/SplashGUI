import Foundation

struct RunConfig: Codable, Equatable {
    // The app's default serve port; Splash's own default is 8000.
    static let defaultPort = 8095

    var modelID: String = "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS"
    var port: Int = defaultPort
    // Auto sizes context, memory and KV from the Metal ceiling and the weights, leaving the SSD
    // cache to the engine. Off restores the typed values below.
    var auto: Bool = true
    var maxContext: String = "auto"
    var maxMemory: String = "auto"
    var kvFormat: String = "auto"
    var maxCacheDisk: String = "10G"
    var languageOnly: Bool = false
    var decodeShare: Double = 0.5
    var showWebUI: Bool = true
    // Bind every IPv4 interface (0.0.0.0) so other machines on the LAN can connect; off leaves the engine's 127.0.0.1 default.
    var lanAccess: Bool = false
    var defaultReasoningEffort: String? = nil
    // How long the engine keeps its memory wired without a request. Its own default is 10m:
    // the first request after an idle minute pays a weight restore and a slower first prefill,
    // which on a 48 GB Mac is a poor trade for the memory it gives back.
    var idleRelease: String = "60m"
    // Keep the SSD KV/state tier across restarts, so a project you come back to restores its
    // prefix instead of prefilling it again.
    var persistentCache: Bool = true
    // Start without contacting the Hugging Face Hub: the installed weights load straight from
    // the local cache. For air-gapped or flaky-network starts; a never-downloaded model fails.
    var offline: Bool = false
    // Thinking tokens for requests that set no budget of their own; blank = no cap (the engine
    // default). A serve-wide guard for clients that ask for thinking but say no length.
    var thinkingTokenBudget: String = ""
    // Decode-verify every row of each draft block. A MoE model's greedy and seeded outputs
    // then repeat run to run like a dense model's, at some decode speed. Off leaves the
    // engine's learned verify budget.
    var verifyRowsAll: Bool = false
    // An additional API model name (e.g. qwen27) so client configs stay short and stable across
    // quants. It names this model, so it swaps with the profile like the serve fields.
    var servedModelName: String = ""
    // Report the served name in responses and /v1/models; off keeps the loaded model ID.
    var announceServedName: Bool = false
    // The arch-specific memory knobs: PLE and sparse-KV belong to Qwen3.8-Flash-Next GGUFs, expert
    // slots to MoE rows. The Run tab shows only what the selected model has, and the launch path
    // clears the rest, so a typed value never reaches a model without that memory.
    var pleMemory: String = ""
    var expertMemory: String = ""
    var sparseKvMemory: String = ""
    var schemaVersion: Int? = 6

    // The memberwise initializer goes away with any custom initializer; defaults below back missing keys.
    init() {}

    // Explicit decoder: a config.json written by an older build lacks the fields added since,
    // and the synthesized one throws on a missing key, which would drop the whole config —
    // per-model profiles with it — back to factory defaults.
    enum CodingKeys: String, CodingKey {
        case modelID, port, auto, maxContext, maxMemory, kvFormat, maxCacheDisk
        case languageOnly, decodeShare, showWebUI, lanAccess, defaultReasoningEffort
        case idleRelease, persistentCache, offline, thinkingTokenBudget, verifyRowsAll
        case servedModelName, announceServedName, pleMemory, expertMemory, sparseKvMemory
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RunConfig()
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? d.modelID
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? d.auto
        maxContext = try c.decodeIfPresent(String.self, forKey: .maxContext) ?? d.maxContext
        maxMemory = try c.decodeIfPresent(String.self, forKey: .maxMemory) ?? d.maxMemory
        kvFormat = try c.decodeIfPresent(String.self, forKey: .kvFormat) ?? d.kvFormat
        maxCacheDisk = try c.decodeIfPresent(String.self, forKey: .maxCacheDisk) ?? d.maxCacheDisk
        languageOnly = try c.decodeIfPresent(Bool.self, forKey: .languageOnly) ?? d.languageOnly
        decodeShare = try c.decodeIfPresent(Double.self, forKey: .decodeShare) ?? d.decodeShare
        showWebUI = try c.decodeIfPresent(Bool.self, forKey: .showWebUI) ?? d.showWebUI
        lanAccess = try c.decodeIfPresent(Bool.self, forKey: .lanAccess) ?? d.lanAccess
        defaultReasoningEffort = try c.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
            ?? d.defaultReasoningEffort
        idleRelease = try c.decodeIfPresent(String.self, forKey: .idleRelease) ?? d.idleRelease
        persistentCache = try c.decodeIfPresent(Bool.self, forKey: .persistentCache) ?? d.persistentCache
        offline = try c.decodeIfPresent(Bool.self, forKey: .offline) ?? d.offline
        thinkingTokenBudget = try c.decodeIfPresent(String.self, forKey: .thinkingTokenBudget)
            ?? d.thinkingTokenBudget
        verifyRowsAll = try c.decodeIfPresent(Bool.self, forKey: .verifyRowsAll) ?? d.verifyRowsAll
        servedModelName = try c.decodeIfPresent(String.self, forKey: .servedModelName) ?? d.servedModelName
        announceServedName = try c.decodeIfPresent(Bool.self, forKey: .announceServedName) ?? d.announceServedName
        pleMemory = try c.decodeIfPresent(String.self, forKey: .pleMemory) ?? d.pleMemory
        expertMemory = try c.decodeIfPresent(String.self, forKey: .expertMemory) ?? d.expertMemory
        sparseKvMemory = try c.decodeIfPresent(String.self, forKey: .sparseKvMemory) ?? d.sparseKvMemory
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
    }

    static func isAuto(_ value: String) -> Bool {
        let v = value.lowercased()
        return v == "auto" || v.isEmpty
    }

    // Resolves what actually launches. Auto on: the covered fields come from the profile (or
    // Splash's own sizing for a custom ID), the SSD cache stays the engine's, typed values stay saved.
    // Auto off: a field still reading "auto" (the pre-switch spelling) falls back to the profile, so
    // SplashServer never sees "auto" for --kv-format.
    func effective(using profile: AutoProfile?) -> RunConfig {
        var out = self
        if auto {
            if let p = profile {
                out.maxContext = String(p.contextTokens)
                out.maxMemory = String(p.maxMemoryBytes)
                out.kvFormat = p.kvFormat
            } else {
                out.maxContext = "auto"
                out.maxMemory = "auto"
                if Self.isAuto(out.kvFormat) { out.kvFormat = "bf16" }
            }
            out.maxCacheDisk = "auto"
            return out
        }
        if let p = profile {
            if Self.isAuto(maxContext) { out.maxContext = String(p.contextTokens) }
            if Self.isAuto(maxMemory) { out.maxMemory = String(p.maxMemoryBytes) }
            if Self.isAuto(kvFormat) { out.kvFormat = p.kvFormat }
        } else if Self.isAuto(kvFormat) {
            out.kvFormat = "bf16"
        }
        return out
    }

    // Launch-copy policy: memory knobs the selected arch lacks are dropped, so the engine never
    // sees them for a model that cannot use them. The saved config keeps the typed values.
    mutating func clearingUnsupportedMemoryKnobs(forModelID id: String) {
        let k = CatalogModel.memoryKnobs(forID: id)
        if !k.ple { pleMemory = "" }
        if !k.expert { expertMemory = "" }
        if !k.sparseKv { sparseKvMemory = "" }
    }
}

// The app's shipped starting point: the thinking-mode sampling every model in the catalog's card
// recommends (both cards publish 1.0 / 0.95 / 20 / min_p 0 / presence 0, and the GGUFs carry it
// as general.sampling.*). These values reach Splash through the client configs the Provider
// tab writes — the app itself sends no requests.
struct SamplingDefaults: Codable, Equatable {
    var temperature: Double = 1.0
    var topP: Double = 0.95
    var topK: Int = 20
    // Engine 1.5.0 accepts and applies both (server/frontend.py SAMPLING_NUMBERS); only
    // logit_bias is refused. The Qwen card asks presence 1.5 with thinking off; the Bonsai
    // card asks min_p 0.05 in thinking mode.
    var presencePenalty: Double = 0
    var minP: Double = 0
    var maxTokens: Int? = nil
    var seed: UInt64? = nil
    var reasoningEffort: String? = nil

    init() {}

    // The model card's thinking-mode set (both cards publish the same defaults).
    mutating func applyCard(_ e: CatalogModel) {
        temperature = e.cardTemperature
        topP = e.cardTopP
        topK = e.cardTopK
        presencePenalty = e.cardPresencePenalty
        minP = e.cardMinP
    }

    mutating func applyCardOff(_ e: CatalogModel) {
        temperature = e.cardOffTemperature
        topP = e.cardOffTopP
        topK = e.cardOffTopK
        presencePenalty = e.cardOffPresencePenalty
        minP = e.cardOffMinP
    }

    // Tolerant decoder (the Codable trap): configs saved before presencePenalty/minP existed
    // must decode with them defaulted, not throw.
    enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, presencePenalty, minP, maxTokens, seed, reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SamplingDefaults()
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        topP = try c.decodeIfPresent(Double.self, forKey: .topP) ?? d.topP
        topK = try c.decodeIfPresent(Int.self, forKey: .topK) ?? d.topK
        presencePenalty = try c.decodeIfPresent(Double.self, forKey: .presencePenalty) ?? d.presencePenalty
        minP = try c.decodeIfPresent(Double.self, forKey: .minP) ?? d.minP
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }
}

// What one model keeps its settings as, so switching models in the picker swaps each model's own
// sampling and serve fields back in. `reasoningEffort` lives in `sampling`; applying a profile also
// mirrors it into `run.defaultReasoningEffort`, which is the serve flag.
struct ModelProfile: Codable, Equatable {
    var sampling = SamplingDefaults()
    var auto: Bool = true
    var maxContext: String = "auto"
    var maxMemory: String = "auto"
    var kvFormat: String = "auto"
    var languageOnly = false
    // The served API name names this model, so it belongs to the profile: switching models
    // must not carry "qwen27" over to a different model's client configs.
    var servedModelName: String = ""
    var announceServedName: Bool = false

    // Tolerant decoder (the Codable trap): profiles saved before `auto` existed must decode
    // with it at its default, not throw — a nested failure drops the whole config to factory.
    init() {}

    init(sampling: SamplingDefaults, auto: Bool, maxContext: String,
         maxMemory: String, kvFormat: String, languageOnly: Bool,
         servedModelName: String, announceServedName: Bool) {
        self.sampling = sampling
        self.auto = auto
        self.maxContext = maxContext
        self.maxMemory = maxMemory
        self.kvFormat = kvFormat
        self.languageOnly = languageOnly
        self.servedModelName = servedModelName
        self.announceServedName = announceServedName
    }

    enum CodingKeys: String, CodingKey {
        case sampling, auto, maxContext, maxMemory, kvFormat, languageOnly
        case servedModelName, announceServedName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ModelProfile()
        sampling = try c.decodeIfPresent(SamplingDefaults.self, forKey: .sampling) ?? d.sampling
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? d.auto
        maxContext = try c.decodeIfPresent(String.self, forKey: .maxContext) ?? d.maxContext
        maxMemory = try c.decodeIfPresent(String.self, forKey: .maxMemory) ?? d.maxMemory
        kvFormat = try c.decodeIfPresent(String.self, forKey: .kvFormat) ?? d.kvFormat
        languageOnly = try c.decodeIfPresent(Bool.self, forKey: .languageOnly) ?? d.languageOnly
        servedModelName = try c.decodeIfPresent(String.self, forKey: .servedModelName) ?? d.servedModelName
        announceServedName = try c.decodeIfPresent(Bool.self, forKey: .announceServedName) ?? d.announceServedName
    }

    // Snapshot of the live settings, for archiving the model you are switching away from.
    static func snapshot(of config: AppConfig) -> ModelProfile {
        ModelProfile(sampling: config.sampling, auto: config.run.auto,
                     maxContext: config.run.maxContext,
                     maxMemory: config.run.maxMemory, kvFormat: config.run.kvFormat,
                     languageOnly: config.run.languageOnly,
                     servedModelName: config.run.servedModelName,
                     announceServedName: config.run.announceServedName)
    }
}

// What Splash actually granted a custom model (no app-side profile): the window and memory
// budget from /status, shown as Auto's values on the next launch without waiting for a serve.
struct GrantedSettings: Codable, Equatable {
    var contextTokens: Int
    var memoryBytes: Int
}

// A model the user keeps in the picker: a saved Hub ID or a local GGUF/MLX file. The id IS the
// model ID the app already flows everywhere — profile key, picker selection, client configs —
// so per-model settings keep working without special cases. Local entries carry the paths as
// plain strings: the app is not sandboxed, so no bookmarks.
struct SavedModel: Codable, Identifiable, Equatable {
    var id: String = ""         // "owner/repo[:variant]" or "local/<name>[:variant]"
    var label: String = ""      // picker display name
    var path: String = ""     // "" = Hub entry; else local GGUF file or model directory
    var mmproj: String = ""   // local only, optional vision projector file
    var isLocal: Bool { !path.isEmpty }

    init() {}

    init(id: String, label: String, path: String = "", mmproj: String = "") {
        self.id = id
        self.label = label
        self.path = path
        self.mmproj = mmproj
    }

    enum CodingKeys: String, CodingKey {
        case id, label, path, mmproj
    }

    // Tolerant decoder (the Codable trap): it applies per element, so one entry written by a
    // future build must not throw the whole saved list — and with it the config — to factory.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        mmproj = try c.decodeIfPresent(String.self, forKey: .mmproj) ?? ""
    }

    // Mirrors the engine's parse_model_id (server/serve_options.py): owner/repo[:variant],
    // segments of [A-Za-z0-9._-] starting and ending alphanumeric-or-underscore (repo ≤ 96,
    // variant ≤ 64), no "--" or ".." and no ".git" ending in the repo part, ".." refused in
    // the variant too. The engine never contacts a local/ owner, but the shape still applies.
    static func validID(_ id: String) -> Bool {
        var repo = id
        var variant: String?
        if let colon = id.firstIndex(of: ":") {
            repo = String(id[id.startIndex..<colon])
            variant = String(id[id.index(after: colon)...])
        }
        let segs = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard segs.count == 2,
              isRepoSegment(String(segs[0]), maxCount: nil),
              isRepoSegment(String(segs[1]), maxCount: 96),
              !repo.contains("--"), !repo.contains(".."), !repo.hasSuffix(".git")
        else { return false }
        if let v = variant {
            guard v.count >= 1, v.count <= 64, !v.contains(".."), isVariantSegment(v) else { return false }
        }
        return true
    }

    private static func isRepoSegment(_ s: String, maxCount: Int?) -> Bool {
        guard !s.isEmpty, s.count <= (maxCount ?? Int.max) else { return false }
        guard isSegmentEdge(s.first!), isSegmentEdge(s.last!) else { return false }
        return s.allSatisfy { isSegmentMiddle($0) }
    }

    // Variants start alphanumeric (no leading underscore) and may end on any middle char.
    private static func isVariantSegment(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return s.allSatisfy { isSegmentMiddle($0) }
    }

    private static func isSegmentEdge(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_")
    }

    private static func isSegmentMiddle(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
    }

    // The auto API ID for a local file or directory: local/<name>[:variant], sanitized to the
    // repo-ID shape. The variant is the part after the last "-" when it reads like a quant name
    // (no lowercase, with a digit or underscore), e.g. UD-IQ3_XXS's IQ3_XXS.
    static func localID(forPath path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(".gguf".count)) }
        var variant = ""
        if let dash = name.lastIndex(of: "-") {
            let tail = String(name[name.index(after: dash)...])
            if tail.count >= 2, !tail.contains(where: \.isLowercase),
               tail.contains(where: \.isNumber) || tail.contains("_"),
               isVariantSegment(tail) {
                variant = tail
                name = String(name[..<dash])
            }
        }
        let clean = sanitizeSegment(name)
        let base = clean.isEmpty ? "model" : clean
        return "local/\(base)" + (variant.isEmpty ? "" : ":\(variant)")
    }

    // Keeps [A-Za-z0-9._-], maps everything else to "-", collapses runs of "-" and ".", trims to
    // an alphanumeric-or-underscore on both ends, and drops a ".git" ending — the exact refusals
    // validID checks, so a sanitized segment is always a valid repo segment.
    static func sanitizeSegment(_ s: String) -> String {
        var out = ""
        for c in s {
            let mapped = isSegmentMiddle(c) ? c : "-"
            if (mapped == "-" || mapped == ".") && out.last == mapped { continue }
            out.append(mapped)
        }
        while let f = out.first, !isSegmentEdge(f) { out.removeFirst() }
        while let l = out.last, !isSegmentEdge(l) { out.removeLast() }
        if out.hasSuffix(".git") {
            out = String(out.dropLast(4))
            while let l = out.last, !isSegmentEdge(l) { out.removeLast() }
        }
        return out
    }
}

struct AppConfig: Codable, Equatable {
    var run = RunConfig()
    var sampling = SamplingDefaults()
    // Archive of per-model settings, keyed by the full model ID including its `:variant` (part of
    // Splash's selection-link name, so never strip it). The live editing state stays in `sampling`/`run`.
    var modelProfiles: [String: ModelProfile] = [:]
    var grantedAuto: [String: GrantedSettings] = [:]
    // The user's kept models shown under "Saved" in the picker: saved Hub IDs and local
    // files, in the order added (see SavedModel). Removing an entry keeps its profile.
    var savedModels: [SavedModel] = []
    var engineVersionOverride: String = ""
    var engineURLOverride: String = ""
    var engineSHA256Override: String = ""
    var checkEngineUpdate: Bool = true
    // Which build to run: the compiled-in pin, the newest release, or a hand-set pin. The override
    // fields above are the custom pin; they decode in every mode so a switch back restores them.
    var engineMode: EngineMode = .pinned
    // Launch = start: serves the saved model on the saved port without a click. Skips when
    // something already owns the port (the adopt path wins), or when SPLASHGUI_TEST is set.
    var startOnLaunch: Bool = false
    // Session logging via the fronting proxy. Applies on the next Start: the proxy can only
    // take the public port while the app launches the serve itself. LAN clients are piped but
    // NOT recorded unless loggingLanClients is on.
    var loggingEnabled: Bool = false
    var loggingLanClients: Bool = false
    var loggingRetentionDays: Int = 90
    // Performance samples ride the existing /status poll (no extra requests). The interval is
    // in seconds and the poll ticks once a second; 1/5/10 are the offered choices.
    var performanceLoggingEnabled: Bool = false
    var performanceLogInterval: Int = 5
    // Hardware stats (macmon module) — OFF by default and never auto-installed: flipping this
    // true only ever comes from the Status tab's Enable/Install button, which is the consent
    // action (see Macmon.swift's OPTIONAL MODULE rule). Launching with it true re-starts the
    // sampler from an already-installed binary; it cannot download.
    var hardwareStatsEnabled: Bool = false

    init() {}

    // Explicit decoder so an older config.json (written before a field existed) still loads with
    // that field at its default. The synthesized one throws on a missing key, which would drop
    // the whole config back to factory defaults and lose the user's settings.
    enum CodingKeys: String, CodingKey {
        case run, sampling, modelProfiles, grantedAuto, savedModels
        case engineVersionOverride, engineURLOverride, engineSHA256Override, checkEngineUpdate
        case engineMode
        case startOnLaunch
        case loggingEnabled, loggingLanClients, loggingRetentionDays
        case performanceLoggingEnabled, performanceLogInterval
        case hardwareStatsEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decodeIfPresent(RunConfig.self, forKey: .run) ?? RunConfig()
        sampling = try c.decodeIfPresent(SamplingDefaults.self, forKey: .sampling) ?? SamplingDefaults()
        modelProfiles = try c.decodeIfPresent([String: ModelProfile].self, forKey: .modelProfiles) ?? [:]
        grantedAuto = try c.decodeIfPresent([String: GrantedSettings].self, forKey: .grantedAuto) ?? [:]
        savedModels = try c.decodeIfPresent([SavedModel].self, forKey: .savedModels) ?? []
        engineVersionOverride = try c.decodeIfPresent(String.self, forKey: .engineVersionOverride) ?? ""
        engineURLOverride = try c.decodeIfPresent(String.self, forKey: .engineURLOverride) ?? ""
        engineSHA256Override = try c.decodeIfPresent(String.self, forKey: .engineSHA256Override) ?? ""
        checkEngineUpdate = try c.decodeIfPresent(Bool.self, forKey: .checkEngineUpdate) ?? true
        // Decoded as a string and mapped, never as the enum directly: a value written by a
        // future build must fall back to .pinned, not throw and drop the whole config to
        // factory defaults (the Codable trap).
        engineMode = EngineMode(rawValue: try c.decodeIfPresent(String.self, forKey: .engineMode) ?? "pinned") ?? .pinned
        startOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? false
        loggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? false
        loggingLanClients = try c.decodeIfPresent(Bool.self, forKey: .loggingLanClients) ?? false
        loggingRetentionDays = try c.decodeIfPresent(Int.self, forKey: .loggingRetentionDays) ?? 90
        performanceLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .performanceLoggingEnabled) ?? false
        performanceLogInterval = try c.decodeIfPresent(Int.self, forKey: .performanceLogInterval) ?? 5
        hardwareStatsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hardwareStatsEnabled) ?? false
    }

    func enginePinOverride() -> EnginePin? {
        guard !engineVersionOverride.isEmpty, !engineURLOverride.isEmpty,
              !engineSHA256Override.isEmpty else { return nil }
        return EnginePin(version: engineVersionOverride, sha256: engineSHA256Override,
                         url: engineURLOverride)
    }

    // Writes a model's saved profile into the live fields. reasoningEffort is also the serve
    // flag, so it lands in both places, exactly as the reasoning-effort control writes them.
    mutating func apply(profile: ModelProfile) {
        sampling = profile.sampling
        run.auto = profile.auto
        run.maxContext = profile.maxContext
        run.maxMemory = profile.maxMemory
        run.kvFormat = profile.kvFormat
        run.languageOnly = profile.languageOnly
        run.servedModelName = profile.servedModelName
        run.announceServedName = profile.announceServedName
        run.defaultReasoningEffort = profile.sampling.reasoningEffort
    }
}

struct CatalogModel: Identifiable, Equatable {
    static let windowTokens = 262_144  // Qwen3.8 native window (no YaRN); Splash's own ceiling

    let id: String
    let label: String
    let note: String
    // Whole assembly (target + draft + vision), used to size the auto-profile before a download.
    var approxBytes: Int? = nil
    // The tsv's MEMORY column: the smallest Mac RAM the vendor says the variant is meant for.
    // The picker's too-large warning gates on this, so note and warning agree by construction.
    var memoryGB: Int? = nil
    // Immutable HF commit the pull is pinned to, so an entry always names one exact set of bytes;
    // nil = the repository's default branch (unpinned). Passed as serve --revision.
    var revision: String? = nil
    // The GGUF the engine links into assembly target/, and the sha256 Hugging Face publishes for
    // it (the LFS oid) — the same digest the engine records in model.json, which the pre-flight
    // check compares against.
    var targetFile: String? = nil
    var sha256: String? = nil
    // Sampling the model's own card recommends, so defaults come from the card instead of being
    // guessed from the model name. Read from the HF cards 2026-10-29 (unsloth/Qwen3.8-27B-GGUF
    // and prism-ml/Ternary-Bonsai-2-27B-gguf Best Practices): both publish the thinking-mode set
    // below; the GGUFs carry temp/top_p/top_k as general.sampling.*. Engine 1.5.0 accepts every
    // card value — presence penalty and min_p are applied; only logit_bias is refused.
    var cardTemperature: Double = 1.0
    var cardTopP: Double = 0.95
    var cardTopK: Int = 20
    var cardPresencePenalty: Double = 0
    var cardMinP: Double = 0
    // The same card's non-thinking set, relevant when reasoning effort is `none`. Offered as a
    // link, never applied automatically — effort is a serve-wide flag while sampling is per-request.
    var cardOffTemperature: Double = 0.7
    var cardOffTopP: Double = 0.80
    var cardOffTopK: Int = 20
    var cardOffPresencePenalty: Double = 1.5
    var cardOffMinP: Double = 0
    // Reasoning levels this model accepts; nil = all of them. Bonsai's card: defaults to xhigh,
    // medium for shorter answers, and `low` is NOT supported (it behaves like xhigh).
    var supportedEfforts: [String]? = nil
    var cardEffortNote: String = "The card recommends thinking mode; leave the effort at model default unless answers run long."
    // Auto's KV-per-token and window constants are measured on this arch only; other rows get
    // nil from autoProfile and the engine sizes itself.
    var qwen27BArch: Bool = false
    // Which arch-specific serve memory knobs this row's model actually has: the PLE n-gram table
    // and block-sparse KV are Qwen3.8-Flash-Next features; routed experts are the A3B MoE rows.
    // The Run tab shows a knob only where its row (or the ID heuristics below) says true.
    var supportsPleMemory: Bool = false
    var supportsExpertMemory: Bool = false
    var supportsSparseKvMemory: Bool = false

    // The knobs that apply to a model ID: the catalog row's flags when the ID is a row, else
    // name heuristics for hand-typed IDs (A3B marks an MoE; Flash-Next marks the PLE table and
    // the block-sparse KV). An ID matching neither gets no knobs.
    static func memoryKnobs(forID id: String) -> (ple: Bool, expert: Bool, sparseKv: Bool) {
        if let e = catalog.first(where: { $0.id == id }) {
            return (e.supportsPleMemory, e.supportsExpertMemory, e.supportsSparseKvMemory)
        }
        let lower = id.lowercased()
        let flashNext = lower.contains("flash-next")
        return (flashNext, lower.contains("a3b"), flashNext)
    }

    // Every level Splash's API accepts. A model's supportedEfforts filters this list.
    static let allEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    // The card as a starting profile: the model's card sampling, model-default reasoning effort,
    // and auto serve fields.
    func cardProfile() -> ModelProfile {
        var p = ModelProfile()
        p.sampling.applyCard(self)
        return p
    }

    var owner: String { id.split(separator: "/").first.map(String.init) ?? "" }
    // Includes the :variant suffix, which is how Splash names its selection link.
    var repo: String {
        let parts = id.split(separator: "/")
        return parts.count > 1 ? String(parts[1]) : id
    }
    // The bare repository, which is what Hugging Face names its cache directory by.
    var hfRepo: String { String(repo.split(separator: ":").first ?? Substring(repo)) }

    var downloadURL: String? {
        guard let revision, let targetFile else { return nil }
        return "https://huggingface.co/\(owner)/\(hfRepo)/resolve/\(revision)/\(targetFile)"
    }

    var onDisk: Bool { MachineInfo.weightsDir(for: id) != nil }

    // The one disk-size-or-catalog-estimate rule: the live launch path, the headless probe, and
    // the auto-profile all read this so they cannot drift apart.
    var weightsBytes: Int? { MachineInfo.cachedModelSize(id) ?? approxBytes }

    var fitsThisMac: Bool {
        guard let memoryGB else { return true }
        return MachineInfo.physicalRAM >= memoryGB * 1_073_741_824
    }

    // The catalog IS Splash's own suggested list (install/suggested-models.tsv as shipped by
    // engine 1.7.3): same order (best first), same facts. The note line carries the tsv's
    // MEMORY / SIZE / ABOUT columns verbatim in meaning — SIZE is the vendor's download figure
    // including the vision projector and DFlash2 draft (the auto-profile's weight basis), and
    // MEMORY feeds fitsThisMac directly, so note and the too-large warning agree by
    // construction. Re-sync on every engine pin bump; the profile-test harness diffs IDs,
    // order and MEMORY against the installed engine's tsv. Hand-verified revision pins and
    // digests are kept only for entries actually measured on hardware (IQ3_XXS, Bonsai);
    // everything else is unpinned, and the free-form Custom slot (see README "Confirmed
    // models") covers the rest.
    static let catalog: [CatalogModel] = [
        CatalogModel(id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M", label: "Qwen3.6-35B-A3B Q4_K_M",
                     note: "for 36 GB Macs · 24 GB download · Fast all-rounder",
                     approxBytes: 24_000_000_000, memoryGB: 36, supportsExpertMemory: true),
        CatalogModel(id: "mlx-community/Qwen3.6-35B-A3B-4bit", label: "Qwen3.6-35B-A3B MLX 4-bit",
                     note: "for 36 GB Macs · 21 GB download · Fast all-rounder",
                     approxBytes: 21_000_000_000, memoryGB: 36, supportsExpertMemory: true),
        CatalogModel(id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL", label: "Qwen3.6-35B-A3B Q2_K_XL",
                     note: "for 24 GB Macs · 14 GB download · Fast all-rounder",
                     approxBytes: 14_000_000_000, memoryGB: 24, supportsExpertMemory: true),
        CatalogModel(id: "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", label: "Qwen3.8-27B Q4_K_M",
                     note: "for 36 GB Macs · 21 GB download · Strongest at this size, slower",
                     approxBytes: 21_000_000_000, memoryGB: 36, qwen27BArch: true),
        CatalogModel(id: "mlx-community/Qwen3.8-27B-4bit", label: "Qwen3.8-27B MLX 4-bit",
                     note: "for 36 GB Macs · 20 GB download · Strongest at this size, slower",
                     approxBytes: 20_000_000_000, memoryGB: 36, qwen27BArch: true),
        CatalogModel(id: "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS", label: "Qwen3.8-27B IQ3_XXS",
                     note: "for 24 GB Macs · 16 GB download · Strongest at this size, slower",
                     approxBytes: 16_000_000_000, memoryGB: 24, revision: "4ca720788d1e01f1bff70c033e0d0028fd02e502",
                     targetFile: "Qwen3.8-27B-UD-IQ3_XXS.gguf",
                     sha256: "c0b7c3038681ed2e3040456c1dd45f9858b6c2290bed172c70388a94874f3eee",
                     qwen27BArch: true),
        CatalogModel(id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S", label: "Qwen3.8-Flash-Next IQ3_S",
                     note: "for 96 GB Macs · 86 GB download · Most capable",
                     approxBytes: 86_000_000_000, memoryGB: 96,
                     supportsPleMemory: true, supportsSparseKvMemory: true),
        CatalogModel(id: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0", label: "Qwen3.8-Flash-Next Q2_0",
                     note: "for 64 GB Macs · 69 GB download · Most capable",
                     approxBytes: 69_000_000_000, memoryGB: 64,
                     supportsPleMemory: true, supportsSparseKvMemory: true),
        CatalogModel(id: "mlx-community/Qwen3.8-Flash-Next-4bit", label: "Qwen3.8-Flash-Next MLX 4-bit",
                     note: "for 96 GB Macs · 113 GB download · Most capable",
                     approxBytes: 113_000_000_000, memoryGB: 96,
                     supportsPleMemory: true, supportsSparseKvMemory: true),
        CatalogModel(id: "unsloth/flint-GGUF:UD-Q4_K_XL", label: "Flint Q4_K_XL",
                     note: "for 48 GB Macs · 26 GB download · Text only",
                     approxBytes: 26_000_000_000, memoryGB: 48),
        CatalogModel(id: "mlx-community/flint-mixed-3-4bit", label: "Flint MLX 3-4bit",
                     note: "for 36 GB Macs · 18 GB download · Text only",
                     approxBytes: 18_000_000_000, memoryGB: 36),
        CatalogModel(id: "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M", label: "Inkling-2-Mini Q4_K_M",
                     note: "for 36 GB Macs · 18 GB download · Agentic all-rounder",
                     approxBytes: 18_000_000_000, memoryGB: 36),
        CatalogModel(id: "mlx-community/Inkling-2-Mini-4bit", label: "Inkling-2-Mini MLX 4-bit",
                     note: "for 36 GB Macs · 18 GB download · Agentic all-rounder",
                     approxBytes: 18_000_000_000, memoryGB: 36),
        CatalogModel(id: "unsloth/Inkling-2-Mini-GGUF:UD-IQ3_XXS", label: "Inkling-2-Mini IQ3_XXS",
                     note: "for 24 GB Macs · 13 GB download · Agentic all-rounder",
                     approxBytes: 13_000_000_000, memoryGB: 24),
        CatalogModel(id: "unsloth/Ornith-1.5-122B-GGUF:UD-Q4_K_XL", label: "Ornith-1.5-122B Q4_K_XL",
                     note: "for 128 GB Macs · 82 GB download · Largest model",
                     approxBytes: 82_000_000_000, memoryGB: 128),
        CatalogModel(id: "ornith-ai/Ornith-1.5-122B-MLX-4bit", label: "Ornith-1.5-122B MLX 4-bit",
                     note: "for 128 GB Macs · 71 GB download · Largest model",
                     approxBytes: 71_000_000_000, memoryGB: 128),
        CatalogModel(id: "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0", label: "Bonsai 2 27B (PQ2_0)",
                     note: "for 24 GB Macs · 12 GB download · Smallest download",
                     approxBytes: 12_000_000_000, memoryGB: 24, revision: "b072e1d3b35a0a630cece372c2127528e0994386",
                     targetFile: "Ternary-Bonsai-2-27B-PQ2_0.gguf",
                     sha256: "3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1",
                     cardMinP: 0.05,
                     supportedEfforts: ["none", "minimal", "medium", "high", "xhigh", "max"],
                     cardEffortNote: "Card: thinking by default at xhigh effort; medium for shorter answers; `low` is NOT supported (it behaves like xhigh). The card also recommends min_p 0.05 in thinking mode, which the sampling fields carry."),
        CatalogModel(id: "custom", label: "Custom…", note: "owner/repo[:variant]")
    ]
}

enum AppPaths {
    // ~/Library/Application Support/SplashGUI. Builds before 1.0 were named Splashpad; their
    // folder (config, engine) is moved here on the first launch that finds no SplashGUI
    // folder. The engine's `current` symlink is relative, so the move keeps it valid.
    static let dataDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("SplashGUI", isDirectory: true)
        let old = base.appendingPathComponent("Splashpad", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

final class ConfigStore {
    static let shared = ConfigStore()

    private let dir: URL
    private let fileURL: URL

    init() {
        dir = AppPaths.dataDir
        fileURL = dir.appendingPathComponent("config.json")
    }

    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AppConfig()
        }
        if let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            var cfg = decoded
            if (cfg.run.schemaVersion ?? 1) < 2 {
                if cfg.run.kvFormat == "int8" { cfg.run.kvFormat = "bf16" }
                cfg.run.schemaVersion = 2
            }
            if (cfg.run.schemaVersion ?? 1) < 3 {
                if cfg.run.kvFormat == "bf16" { cfg.run.kvFormat = "auto" }
                cfg.run.schemaVersion = 3
            }
            if (cfg.run.schemaVersion ?? 1) < 4 {
                // Give the model already selected a profile entry, so its shipped-or-tuned
                // settings survive the first switch away from it and are editable on disk.
                let id = cfg.run.modelID
                if !id.isEmpty && cfg.modelProfiles[id] == nil {
                    cfg.modelProfiles[id] = ModelProfile.snapshot(of: cfg)
                }
                cfg.run.schemaVersion = 4
            }
            if (cfg.run.schemaVersion ?? 1) < 5 {
                // 1.0 shipped with the SSD tier off. A 64K context costs 2.0 GiB of KV pages
                // there (33,280 bytes a token) plus a 152 MiB state, so 10 GB holds about
                // five of them, and the tier only pays for itself if it survives a restart.
                if cfg.run.maxCacheDisk == "0" { cfg.run.maxCacheDisk = "10G" }
                cfg.run.schemaVersion = 5
            }
            if (cfg.run.schemaVersion ?? 1) < 6 {
                // The Auto switch: on only when every field it covers was still "auto".
                // Otherwise off, with the existing values as the typed ones.
                let allAuto = RunConfig.isAuto(cfg.run.maxContext) && RunConfig.isAuto(cfg.run.maxMemory)
                    && RunConfig.isAuto(cfg.run.kvFormat) && RunConfig.isAuto(cfg.run.maxCacheDisk)
                cfg.run.auto = allAuto
                if !allAuto && RunConfig.isAuto(cfg.run.kvFormat) {
                    // The KV picker no longer has an Auto segment — resolve what Auto would
                    // have picked once, so the typed set is complete.
                    let id = cfg.run.modelID
                    let weights = CatalogModel.catalog.first { $0.id == id }?.weightsBytes
                        ?? MachineInfo.cachedModelSize(id)
                    let p = MachineInfo.autoProfile(modelID: id, languageOnly: cfg.run.languageOnly,
                                                    weightsBytes: weights)
                    cfg.run.kvFormat = p?.kvFormat ?? "bf16"
                }
                cfg.run.schemaVersion = 6
            }
            if (cfg.run.schemaVersion ?? 1) < 7 {
                // Prefer a Homebrew-installed engine when one is present: it updates with
                // `brew upgrade splash` and needs no duplicate download. Only the untouched
                // default (.pinned) flips; an explicit .latest/.custom choice stays.
                if cfg.engineMode == .pinned, EngineInstaller.externalEngineVersion() != nil {
                    cfg.engineMode = .homebrew
                }
                cfg.run.schemaVersion = 7
            }
            return cfg
        }
        return AppConfig()
    }

    func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
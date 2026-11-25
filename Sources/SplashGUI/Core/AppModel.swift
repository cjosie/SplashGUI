import SwiftUI
import Combine

enum ServerPhase: Equatable {
    case stopped
    case starting
    case ready
    case stopping
    case exited(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            ConfigStore.shared.save(config)
            // The Logging tab's LAN toggle is live: the proxy reads its policy per request.
            proxy?.updatePolicy(.init(logLocal: true, logLAN: config.loggingLanClients))
        }
    }
    @Published var phase: ServerPhase = .stopped
    @Published var logTail: [String] = []
    @Published var status: StatusSnapshot?
    @Published var draftAcceptance: Double?
    @Published var lastError: String?
    @Published var effectiveModel: String?
    @Published var history: [StatusSample] = []
    @Published var adoptedPID: Int?
    @Published var loadProgress: Double?
    @Published var loadStage: String = ""
    @Published var currentStage: SampleStage?
    @Published var engineStep: EngineInstaller.Step = .idle
    @Published var engineProgress: Double = 0
    @Published var engineVersion: String?
    @Published var engineResolvedVersion: String?
    // The Homebrew-casked engine's version, if one is installed. Read on demand: `brew
    // upgrade`/`uninstall` can change it while the app runs, and the picker should follow.
    var homebrewEngineVersion: String? { EngineInstaller.externalEngineVersion() }
    private var engineCancels: Set<AnyCancellable> = []
    // Depth of the 27B arch every catalog model shares; used only to scale the load-progress bar.
    private static let modelLayerCount = 66.0
    private var weightsSizeModelID: String?
    private var weightsRefreshedThisRun = false
    private var loadStartedAt: Date?

    private func updateLoadProgress() {
        guard phase == .starting else {
            if loadProgress != nil { loadProgress = nil }
            loadStartedAt = nil
            return
        }
        if loadStartedAt == nil { loadStartedAt = Date() }
        let lines = server.logLines
        var base = 0.06
        var stage = "starting server…"

        if let layer = preparingLayer(from: lines) {
            // Every catalog model is Qwen3.8-27B-shaped (66 layers). The engine prints the layer
            // index but not its total, so the fraction is scaled to that depth — a different arch
            // would only misshape the progress bar, never the load.
            let frac = min(1.0, Double(layer) / Self.modelLayerCount)
            base = 0.78 + 0.17 * frac
            stage = "preparing weights (one-time): \(Int(frac * 100))%"
            loadProgress = base
            loadStage = stage
            return
        }

        if let fetch = downloadFraction(from: lines, since: loadStartedAt) {
            stage = "downloading model: \(Int(fetch * 100))%"
            base = 0.03 + 0.55 * fetch
            loadProgress = min(0.95, base)
            loadStage = stage
            return
        }

        if lines.contains(where: { $0.contains("Loading ·") }) {
            base = 0.22
            stage = "loading weights…"
        }
        if lines.contains(where: { $0.contains("Chat template") }) {
            base = 0.45
            stage = "configuring chat template…"
        }
        if lines.contains(where: { $0.contains("Kernel policy") }) {
            base = 0.68
            stage = "preparing Metal kernels…"
        }
        if let started = loadStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            let creep = min(0.26, elapsed * 0.012)
            loadProgress = min(0.95, base + creep)
        }
        loadStage = stage
    }

    private func preparingLayer(from lines: [String]) -> Int? {
        for line in lines.reversed() {
            guard line.contains("Preparing weights") else { continue }
            guard let range = line.range(of: "layer-") else { continue }
            let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
            if let n = Int(digits) { return n }
        }
        return nil
    }

    // Done = in-flight .incomplete files plus blobs completed since this load started. HF renames
    // a blob off its .incomplete name when it finishes, so counting only incomplete files drops
    // each finished shard and the bar jumps backward on multi-blob models.
    private func downloadFraction(from lines: [String], since: Date?) -> Double? {
        var totalBytes: Double?
        for line in lines {
            guard let r = line.range(of: "file(s), ") else { continue }
            let digits = line[r.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
            if let gb = Double(digits) { totalBytes = gb * 1e9 }
        }
        guard let totalBytes, totalBytes > 0 else { return nil }

        guard let cache = MachineInfo.hfCacheDir(for: config.run.modelID) else { return nil }
        let blobsDir = cache.appendingPathComponent("blobs")
        var doneBytes: Int64 = 0
        if let en = FileManager.default.enumerator(at: blobsDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]) {
            for case let f as URL in en {
                guard let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
                      vals.isRegularFile == true else { continue }
                if f.lastPathComponent.contains(".incomplete") {
                    doneBytes += Int64(vals.fileSize ?? 0)
                } else if let mtime = vals.contentModificationDate, let since, mtime >= since {
                    doneBytes += Int64(vals.fileSize ?? 0)
                }
            }
        }
        guard doneBytes > 0 else { return nil }
        let frac = Double(doneBytes) / totalBytes
        let tqdm = tqdmPercent(from: lines).map { Double($0) / 100.0 }
        return min(1.0, max(frac, tqdm ?? 0))
    }

    private func tqdmPercent(from lines: [String]) -> Int? {
        for line in lines.reversed() {
            guard let marker = line.range(of: "%|") else { continue }
            let before = line[..<marker.lowerBound]
            let digits = before.reversed().prefix(while: { $0.isNumber }).reversed()
            if let value = Int(String(digits)), (0...100).contains(value) {
                return value
            }
        }
        return nil
    }

    var modelFootprint: Int? {
        guard let pid = status?.instancePID else { return nil }
        return MachineInfo.serverFootprint(parentPID: pid)
    }

    var prefillGaugeValue: Double? {
        guard let last = history.last else { return nil }
        if last.stage == nil { return 0 }
        return last.prefillTps ?? 0
    }

    var decodeGaugeValue: Double? {
        guard let last = history.last else { return nil }
        if last.stage == nil { return 0 }
        return last.decodeTps ?? 0
    }

    var lastRequestTTFT: Double? {
        for sample in history.reversed() {
            if let v = sample.ttftP50 { return v }
        }
        return nil
    }

    private func maxTps(_ keyPath: KeyPath<StatusSample, Double?>, within seconds: Double? = nil) -> Double? {
        let source: [StatusSample]
        if let seconds {
            let cutoff = Date().addingTimeInterval(-seconds)
            source = history.filter { $0.time >= cutoff }
        } else {
            source = history
        }
        return source.compactMap { $0[keyPath: keyPath] }.max()
    }

    var prefillMax5m: Double? { maxTps(\.prefillTps, within: 300) }
    var decodeMax5m: Double? { maxTps(\.decodeTps, within: 300) }
    var prefillMaxSession: Double? { maxTps(\.prefillTps) }
    var decodeMaxSession: Double? { maxTps(\.decodeTps) }

    var reasoningEffortBinding: Binding<String?> {
        Binding(
            get: { self.config.sampling.reasoningEffort ?? self.config.run.defaultReasoningEffort },
            set: {
                self.config.sampling.reasoningEffort = $0
                self.config.run.defaultReasoningEffort = $0
            }
        )
    }

    let server = SplashServer()
    let engine = EngineInstaller()
    @Published var launchedRunConfig: RunConfig?
    var hasPendingChanges: Bool {
        guard let launched = launchedRunConfig else { return false }
        return phase == .ready && launched != config.run
    }
    private var client: SplashClient { SplashClient(port: frontedEnginePort ?? config.run.port) }
    private var pollTask: Task<Void, Never>?
    private var pollTick = 0
    private var logTimer: Timer?
    // Session logging. When the serve is fronted, the proxy holds the PUBLIC port and the
    // engine runs on `frontedEnginePort`; status polling goes direct.
    let sessionLog = SessionLog()
    let performanceLog = PerformanceLog()
    @Published var frontedEnginePort: Int?
    private var proxy: SessionProxy?
    // The Logging tab's "applies on next Start" hint: what the running serve was started with.
    @Published var launchedLoggingEnabled = false

    // Pure fronting rule: front only when logging is on AND the app is launching the serve
    // itself onto a picked free internal port. An adopted external serve never gets fronted —
    // its port is already bound by someone else.
    nonisolated static func frontingPlan(enabled: Bool, adopted: Bool, pickedInternalPort: Int?)
        -> (front: Bool, enginePort: Int?) {
        guard enabled, !adopted, let p = pickedInternalPort else { return (false, nil) }
        return (true, p)
    }

    init() {
        config = ConfigStore.shared.load()
        logTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let new = self.server.logLines
                if new != self.logTail { self.logTail = new }
                self.updateLoadProgress()
            }
        }
        RunLoop.main.add(logTimer!, forMode: .common)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            if let pid = AppModel.serverKillPID {
                kill(Int32(pid), SIGTERM)
                var waited = 0
                while waited < 12 {
                    if kill(Int32(pid), 0) != 0 { break }
                    usleep(100_000)
                    waited += 1
                }
                if kill(Int32(pid), 0) == 0 { kill(Int32(pid), SIGKILL) }
            }
        }
        Task { @MainActor in
            // Launch = start (when enabled): wait for the adopt probe first so a server already
            // on the port wins and auto-start never double-launches into a port conflict.
            if !(await self.adoptExistingServer()) { self.autoStartIfNeeded() }
        }
        refreshModelSizeCache()
        // Retention sweep on launch; day-file names older than the window are deleted.
        SessionLog.purge(dir: sessionLog.dir, retentionDays: config.loggingRetentionDays)
        SessionLog.purge(dir: performanceLog.dir, retentionDays: config.loggingRetentionDays)

        engineVersion = engine.installedVersion
        engine.step = EngineInstaller.isInstalled ? .ready : .idle
        // [weak self]: the cancellables are stored on self, so a strong capture here would be a
        // self ↔ cancellable retain cycle.
        engine.$step.receive(on: RunLoop.main).sink { [weak self] v in
            Task { @MainActor in self?.engineStep = v }
        }.store(in: &engineCancels)
        engine.$progress.receive(on: RunLoop.main).sink { [weak self] v in
            Task { @MainActor in self?.engineProgress = v }
        }.store(in: &engineCancels)
        engine.$installedVersion.receive(on: RunLoop.main).sink { [weak self] v in
            Task { @MainActor in self?.engineVersion = v }
        }.store(in: &engineCancels)
        engine.$resolvedVersion.receive(on: RunLoop.main).sink { [weak self] v in
            Task { @MainActor in self?.engineResolvedVersion = v }
        }.store(in: &engineCancels)
    }

    // Drops the cached on-disk size when a model has just finished downloading, so the
    // auto-profile and the download-progress bar re-read it instead of a stale nil. The
    // non-force call on a model switch just re-arms the guard for the next download.
    func refreshModelSizeCache(force: Bool = false) {
        let id = config.run.modelID
        guard force || weightsSizeModelID != id else { return }
        if force { MachineInfo.invalidateModelSize(id) }
        weightsSizeModelID = id
    }

    private func failureHint() -> String {
        let lines = server.logLines
        for line in lines.reversed() {
            if line.contains("already serving") {
                return "Another Splash server already owns this port (possibly from an earlier session). Stop it or pick a different port in Advanced."
            }
            if line.contains("Address already in use") || line.contains("failed to bind") {
                return "Port \(config.run.port) is taken by another process. Pick a different port in Advanced."
            }
            if line.lowercased().contains("handshake") || line.contains("_ssl")
                || line.lowercased().contains("cannot resolve") || line.lowercased().contains("timed out")
                || line.lowercased().contains("connection refused") {
                return "Couldn't reach Hugging Face to download or resolve this model (network/SSL timeout). Check the connection and try again."
            }
            if line.contains("model download or verification failed") {
                return "The model download failed partway. Check the connection and try again. Partially downloaded files resume."
            }
            if line.contains("cannot prepare") || line.contains("local model preparation failed") {
                return "The engine refused the local model files. Check the entry's path and projector; the reason is in the log below."
            }
            if line.lowercased().contains("out of memory") || line.lowercased().contains("not enough memory") {
                return "Not enough free memory to load this model. Close other apps, or lower Max memory in Advanced."
            }
        }
        return "splash exited before becoming ready; see the details below."
    }

    nonisolated(unsafe) static var serverKillPID: Int?


    @discardableResult
    private func adoptExistingServer() async -> Bool {
        guard canStart else { return false }
        let probe = await client.probePort()
        guard probe.open, let pid = probe.pid else { return false }
        guard canStart else { return false }
        adoptedPID = pid
        launchedRunConfig = config.run
        server.note("- attached to existing splash on port \(config.run.port) (pid \(pid))")
        if config.loggingEnabled {
            server.note("- session logging inactive while attached to an externally started serve")
        }
        // Never arm a kill path or watchdog for a server we did not launch: the user owns
        // it, and killing it on app quit/stop/restart would reach past the app's own serve.
        phase = await client.ready() ? .ready : .starting
        startPolling()
        return true
    }

    private func autoStartIfNeeded() {
        guard config.startOnLaunch,
              ProcessInfo.processInfo.environment["SPLASHGUI_TEST"] == nil else { return }
        start()
    }

    var effectiveModelID: String { config.run.modelID }

    // The catalog row for the selected model, nil for a Custom ID.
    var catalogEntry: CatalogModel? {
        CatalogModel.catalog.first { $0.id == config.run.modelID }
    }

    // The user's saved entry for the selected model (Hub or local), nil for a catalog row or
    // unsaved custom text.
    var savedEntry: SavedModel? {
        config.savedModels.first { $0.id == config.run.modelID }
    }

    // The local entry being served, if the selection is one.
    var localEntry: SavedModel? {
        guard let e = savedEntry, e.isLocal else { return nil }
        return e
    }

    // Add or update the saved entry for an ID — a duplicate ID updates in place and keeps its
    // position. False when the engine would refuse the ID as no model ID at all.
    @discardableResult
    func saveModel(id: String, label: String, path: String = "", mmproj: String = "") -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard SavedModel.validID(trimmed) else { return false }
        let name = label.trimmingCharacters(in: .whitespaces)
        let entry = SavedModel(id: trimmed, label: name.isEmpty ? trimmed : name,
                               path: path, mmproj: mmproj)
        if let i = config.savedModels.firstIndex(where: { $0.id == trimmed }) {
            config.savedModels[i] = entry
        } else {
            config.savedModels.append(entry)
        }
        return true
    }

    // Removing a saved entry leaves its ModelProfile (and grantedAuto) in place, exactly like
    // a catalog row you stop showing: re-adding by the same ID restores the tuned settings.
    func removeSavedModel(id: String) {
        config.savedModels.removeAll { $0.id == id }
    }

    // Renames a saved entry in place, as typed (the Run tab's field writes every keystroke).
    func renameSavedModel(id: String, to label: String) {
        guard let i = config.savedModels.firstIndex(where: { $0.id == id }) else { return }
        config.savedModels[i].label = label
    }

    // The engine's local-mode refusals, applied before the launch so the message lands in the
    // footer instead of a process that dies in the log: a missing file, and the projector +
    // language-only pair the engine's parser rejects.
    nonisolated static func localStartBlocker(path: String, mmproj: String,
                                              languageOnly: Bool) -> String? {
        if !FileManager.default.fileExists(atPath: path) {
            return "The local model path no longer exists: \(path). Re-point it with Add local model."
        }
        if !mmproj.isEmpty, !FileManager.default.fileExists(atPath: mmproj) {
            return "The vision projector no longer exists: \(mmproj). Re-attach it or clear it."
        }
        if !mmproj.isEmpty, languageOnly {
            return "Language only refuses a vision projector — the engine rejects the pair. Turn Language only off or detach the projector."
        }
        return nil
    }

    // Switching models swaps profiles: the model being left keeps its current settings, the model
    // being entered restores its saved ones, or starts on its card if it has none. Also re-reads
    // the on-disk weights size the auto-profile needs.
    func selectModelID(_ id: String) {
        guard config.run.modelID != id else { return }
        let outgoing = config.run.modelID
        if !outgoing.isEmpty { config.modelProfiles[outgoing] = ModelProfile.snapshot(of: config) }
        config.run.modelID = id
        if let saved = config.modelProfiles[id] {
            config.apply(profile: saved)
        } else {
            applyCardProfile()
        }
        refreshModelSizeCache()
    }

    // A model with no saved profile starts on its own card — card sampling, model-default reasoning
    // effort, auto serve fields — rather than keeping the model you came from.
    private func applyCardProfile() {
        config.apply(profile: catalogEntry?.cardProfile() ?? ModelProfile())
    }

    // Forget this model's saved profile and go back to its card. Global fields (port, storage
    // cache, decode share, web chat) are untouched.
    func resetModelProfile() {
        config.modelProfiles[config.run.modelID] = nil
        applyCardProfile()
    }

    // Reasoning levels this model accepts — its card's list, or every level for a hand-typed ID.
    var supportedEfforts: [String] { catalogEntry?.supportedEfforts ?? CatalogModel.allEfforts }

    // The card's non-thinking sampling set, applied only when the user asks for it. Deliberately
    // not automatic: effort is a serve-wide flag while sampling is per-request, and an automatic
    // rewrite would clobber numbers the user tuned for this model.
    func applyCardOffSampling() {
        guard let e = catalogEntry else { return }
        config.sampling.applyCardOff(e)
    }

    // The context limit to write into client configs: the window Splash actually granted while
    // the server runs; otherwise the configured/Auto value — the tab flags that as an estimate.
    var providerContextTokens: (tokens: Int, estimate: Bool) {
        if phase == .ready, let granted = status?.maxContextTokens { return (granted, false) }
        if config.run.auto {
            if let p = currentAutoProfile { return (p.contextTokens, true) }
            if let g = config.grantedAuto[config.run.modelID] { return (g.contextTokens, true) }
            return (CatalogModel.windowTokens, true)
        }
        return (Self.parseContext(config.run.maxContext) ?? CatalogModel.windowTokens, true)
    }

    // "100K" → 102_400, "131072" → 131_072; nil for "auto"/garbage.
    static func parseContext(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "auto" { return nil }
        if t.hasSuffix("k"), let n = Int(t.dropLast()) { return n * 1024 }
        return Int(t)
    }

    func clientConfigText(for client: ProviderClient, useLAN: Bool = false) -> String {
        let (tokens, _) = providerContextTokens
        let modalities = phase == .ready
            ? status?.inputModalities ?? (config.run.languageOnly ? ["text"] : ["text", "image", "pdf"])
            : (config.run.languageOnly ? ["text"] : ["text", "image", "pdf"])
        // LAN configs are for another machine on this network; without a leased address (or
        // with LAN serving off) they fall back to loopback rather than write a broken URL.
        let host = useLAN && config.run.lanAccess
            ? (MachineInfo.lanIPv4Address ?? "127.0.0.1") : "127.0.0.1"
        // The served name, when set, is the name clients should use: the API answers to it and,
        // with announce, reports it. The full Hub ID stays the profile key and the /status name.
        let apiName = config.run.servedModelName.isEmpty ? config.run.modelID : config.run.servedModelName
        let off: SamplingDefaults? = catalogEntry.map { e in
            var s = SamplingDefaults()
            s.applyCardOff(e)
            return s
        }
        let ctx = ClientConfigContext(client: client, modelID: apiName,
                                      label: catalogEntry?.label ?? savedEntry?.label ?? config.run.modelID,
                                      host: host, port: config.run.port, contextTokens: tokens,
                                      inputModalities: modalities,
                                      sampling: config.sampling,
                                      offSampling: off,
                                      efforts: supportedEfforts,
                                      laterSystem: status?.rendersLaterSystem ?? false)
        return ClientConfigs.text(for: ctx)
    }

    // Any ID outside the catalog and the saved list reads as Custom… so the popup never goes
    // blank on a hand-typed ID.
    var modelPickerSelection: Binding<String> {
        Binding(
            get: { self.catalogEntry?.id ?? self.savedEntry?.id ?? "custom" },
            set: { newValue in
                if newValue != "custom" { self.selectModelID(newValue) }
                else if self.catalogEntry != nil || self.savedEntry != nil { self.selectModelID("") }
            }
        )
    }

    // Typing a Custom ID: no profile swap (that would clobber edits mid-keystroke), just a size
    // refresh so the auto-profile caption tracks what's being typed.
    var customIDBinding: Binding<String> {
        Binding(
            get: { self.config.run.modelID },
            set: {
                self.config.run.modelID = $0
                self.refreshModelSizeCache()
            }
        )
    }

    // Which arch memory knobs the Run tab shows for the selected model.
    var memoryKnobs: (ple: Bool, expert: Bool, sparseKv: Bool) {
        CatalogModel.memoryKnobs(forID: config.run.modelID)
    }

    // Resolved run profile for the current model, using the catalog weight estimate when the
    // model hasn't downloaded yet. Cheap: weights size is cached, Metal ceiling read once.
    // Local entries size from their files (and get no Auto profile — the arch gate returns
    // nil for a non-catalog ID and the engine sizes itself).
    var currentAutoProfile: AutoProfile? {
        let id = config.run.modelID
        let weights = localEntry.map { MachineInfo.localWeightsSize(path: $0.path) }
            ?? catalogEntry?.weightsBytes ?? MachineInfo.cachedModelSize(id)
        return MachineInfo.autoProfile(modelID: id, languageOnly: config.run.languageOnly, weightsBytes: weights)
    }

    // What the four Auto-covered fields show while Auto is on: the profile's values, or for a
    // custom ID the last Splash-granted ones — blank until the first serve fills them.
    var autoContextText: String {
        if let p = currentAutoProfile { return "\(p.contextTokens / 1024)K" }
        if let g = config.grantedAuto[config.run.modelID] { return "\(g.contextTokens / 1024)K" }
        return ""
    }

    var autoMemoryText: String {
        let bytes = currentAutoProfile?.maxMemoryBytes ?? config.grantedAuto[config.run.modelID]?.memoryBytes
        guard let bytes else { return "" }
        return "\(bytes / 1_073_741_824)G"
    }

    var autoKVFormat: String { currentAutoProfile?.kvFormat ?? "bf16" }

    // The engine's own SSD-cache default: a quarter of the volume's free space, up to 32G.
    var autoCacheText: String {
        guard let free = MachineInfo.freeDisk else { return "engine default" }
        return "\(min(free / 4, 34_359_738_368) / 1_073_741_824)G"
    }

    var canStart: Bool {
        if case .exited = phase { return true }
        return phase == .stopped
    }

    var portValid: Bool {
        (1...65535).contains(config.run.port)
    }

    var isInstallingEngine: Bool {
        switch engineStep {
        case .checking, .downloading, .verifying, .extracting, .validating, .switching: return true
        default: return false
        }
    }

    // A start that never launched: the footer carries the message until the next Start, and the
    // log tail gets a line in SplashServer's note style, so the failure survives in both places.
    private func startBlocked(_ message: String) {
        lastError = message
        server.note("- start blocked: \(message)")
    }

    // Which engine build start() installs, as a pure decision: the custom pin applies only
    // in .custom (complete fields install regardless of the update toggle; partial fields keep
    // the pre-picker pinned behavior), .pinned never sees the override fields, and .latest
    // keeps the installed engine on a failed check — the compiled-in pin would silently
    // DOWNGRADE — while nothing-installed falls back to the compiled pin.
    // `externalVersion` (Homebrew, if present) satisfies .pinned/.latest without a download
    // when it is at or above the wanted build; .homebrew takes it at ANY version (that is the
    // point: brew can lag the pin) and falls back to pinned behavior when brew is absent.
    // .custom names an explicit payload and never accepts a stand-in. When external is true,
    // start() adopts it (points `current` at the brew libexec) instead of calling ensureInstalled.
    nonisolated static func enginePlan(mode: EngineMode, customOverride: EnginePin?, installed: Bool,
                                       checkUpdate: Bool, latest: EnginePin?,
                                       pinnedVersion: String, externalVersion: String?)
        -> (ensure: Bool, override: EnginePin?, external: Bool) {
        var ensure = !installed || checkUpdate
        var override: EnginePin?
        switch mode {
        case .pinned, .homebrew:
            break
        case .custom:
            override = customOverride
            if override != nil { ensure = true }
        case .latest:
            ensure = true
            if let newest = latest {
                override = newest
            } else if installed {
                ensure = false
            }
        }
        var external = false
        if mode == .homebrew {
            external = externalVersion != nil
        } else if mode != .custom, let ext = externalVersion {
            let wanted = override?.version ?? pinnedVersion
            if EngineInstaller.versionOrder(ext, wanted) != .orderedAscending { external = true }
        }
        if external { ensure = false }
        return (ensure, override, external)
    }

    func start() {
        lastError = nil
        guard canStart else { return }
        weightsRefreshedThisRun = false
        if config.run.modelID.isEmpty {
            startBlocked("No model ID set. Pick one from the Model popup, or Custom… and type owner/repo[:variant].")
            return
        }
        if let mismatch = MachineInfo.modelHashMismatch(config.run.modelID) {
            startBlocked(mismatch)
            return
        }
        let local = localEntry
        if let entry = local,
           let blocked = Self.localStartBlocker(path: entry.path, mmproj: entry.mmproj,
                                                languageOnly: config.run.languageOnly) {
            startBlocked(blocked)
            return
        }
        Task {
            let probe = await client.probePort()
            if probe.open {
                let pidPart = probe.pid.map { " (pid \($0))" } ?? ""
                self.startBlocked("Port \(self.config.run.port) is taken\(pidPart) by \(probe.detail ?? "unknown process"). Stop it or change the port.")
                self.phase = .stopped
                return
            }
            let installed = EngineInstaller.isInstalled
            // The resolver is only consulted in latest mode; the mode table itself is pure
            // (enginePlan).
            var resolved: EnginePin?
            if case .latest = self.config.engineMode { resolved = await EngineResolver.latest() }
            let externalVersion = EngineInstaller.externalEngineVersion()
            let (ensure, override, external) = Self.enginePlan(
                mode: self.config.engineMode, customOverride: self.config.enginePinOverride(),
                installed: installed, checkUpdate: self.config.checkEngineUpdate, latest: resolved,
                pinnedVersion: EngineInstaller.defaultPin.version, externalVersion: externalVersion)
            if !ensure, !external, case .latest = self.config.engineMode {
                self.server.note("- engine update check: GitHub unreachable, keeping the installed engine")
            }
            if !external, case .homebrew = self.config.engineMode {
                self.server.note("- engine: no Homebrew install found; using the pinned engine")
            }
            if external {
                // Skip the download: point `current` at the Homebrew payload.
                do {
                    try EngineInstaller.adoptExternalEngine()
                } catch {
                    self.startBlocked((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    self.phase = .stopped
                    return
                }
                self.server.note("- engine: using the Homebrew install (\(externalVersion ?? "?")) — no download")
            } else if ensure {
                do {
                    try await self.engine.ensureInstalled(
                        port: self.config.run.port,
                        override: override)
                } catch {
                    self.startBlocked((error as? LocalizedError)?.errorDescription
                        ?? "Engine install failed: \(error)")
                    self.phase = .stopped
                    return
                }
            }
            self.phase = .starting
            let profile = self.currentAutoProfile
            do {
                var run = self.config.run.effective(using: profile)
                run.clearingUnsupportedMemoryKnobs(forModelID: self.config.run.modelID)
                // Fronted mode: the proxy takes the public port; the engine gets an
                // auto-picked loopback port behind it. No free port → serve starts
                // unfronted with a note rather than failing the Start.
                let picked = self.config.loggingEnabled
                    ? SessionProxy.pickInternalPort(publicPort: self.config.run.port) : nil
                let plan = Self.frontingPlan(enabled: self.config.loggingEnabled,
                                             adopted: false, pickedInternalPort: picked)
                // The engine's Host allow-list is its bind address plus loopback; a LAN client
                // reaches this Mac by its LAN address, so name that address explicitly.
                let lanHosts = self.config.run.lanAccess
                    ? [MachineInfo.lanIPv4Address].compactMap { $0 } : []
                if plan.front, let internalPort = plan.enginePort {
                    run.port = internalPort
                    // The proxy is the only LAN-facing listener; keep the engine on loopback.
                    run.lanAccess = false
                } else if self.config.loggingEnabled, picked == nil {
                    self.server.note("- session logging: no free internal port near \(self.config.run.port); serving directly")
                }
                try self.server.launch(config: run,
                                       revision: self.catalogEntry?.revision,
                                       local: local.map {
                                           SplashServer.LocalLaunch(modelDir: $0.path, mmproj: $0.mmproj)
                                       },
                                       allowedHosts: lanHosts)
                if plan.front, let internalPort = plan.enginePort {
                    let px = try SessionProxy(
                        publicPort: self.config.run.port, internalPort: internalPort,
                        lanBind: self.config.run.lanAccess,
                        policy: .init(logLocal: true, logLAN: self.config.loggingLanClients),
                        log: self.sessionLog)
                    px.onNote = { msg in Task { @MainActor in self.server.note(msg) } }
                    px.start()
                    self.proxy = px
                    self.frontedEnginePort = internalPort
                    self.server.note("- session logging: proxy :\(self.config.run.port) → engine :\(internalPort)" +
                                     (self.config.loggingLanClients ? " (LAN clients recorded)" : " (loopback clients only)"))
                }
                self.launchedRunConfig = self.config.run
                self.launchedLoggingEnabled = self.config.loggingEnabled
                if let pid = self.server.childPID {
                    AppModel.serverKillPID = pid
                    self.server.spawnWatchdog(serverPID: pid,
                                              appPID: Int(ProcessInfo.processInfo.processIdentifier))
                }
                self.startPolling()
            } catch {
                self.startBlocked(error.localizedDescription)
                self.phase = .stopped
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        proxy?.stop()
        proxy = nil
        frontedEnginePort = nil
        launchedLoggingEnabled = false
        phase = .stopping
        launchedRunConfig = nil
        if adoptedPID != nil {
            // Adopted servers belong to the user — detach and leave them running.
            adoptedPID = nil
            AppModel.serverKillPID = nil
            phase = .stopped
            status = nil
            draftAcceptance = nil
            effectiveModel = nil
            currentStage = nil
            return
        }
        server.stop()
        Task { @MainActor in
            for _ in 0..<40 {
                if !self.server.isRunning { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if self.server.isRunning { self.server.terminateHard() }
            AppModel.serverKillPID = nil
            self.phase = .stopped
            self.status = nil
            self.draftAcceptance = nil
            self.effectiveModel = nil
            self.currentStage = nil
        }
    }

    func restart() {
        guard phase == .ready || phase == .starting else { return }
        stop()
        Task { @MainActor in
            // Wait for stop() to settle rather than a fixed delay: it flips to .stopped
            // asynchronously once the engine process has actually exited (up to ~10s).
            for _ in 0..<120 {
                if self.phase == .stopped { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if self.phase == .stopped { self.start() }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTick = 0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isReady = await self.client.ready()
                if isReady {
                    self.phase = .ready
                    // A model that just finished downloading now has a real on-disk size; re-read
                    // it once per run so the weights line and card stop showing the estimate.
                    if !self.weightsRefreshedThisRun {
                        self.weightsRefreshedThisRun = true
                        self.refreshModelSizeCache(force: true)
                    }
                    let snap = await self.client.fetchStatus()
                    self.status = snap
                    if let model = snap?.instanceModel { self.effectiveModel = model }
                    // Custom IDs have no app-side profile — remember what Splash granted so the
                    // Auto fields show it on the next launch at once. Only write on change:
                    // every config write rewrites config.json.
                    if self.catalogEntry == nil, self.config.run.auto,
                       let ctx = snap?.maxContextTokens, let mem = snap?.hardBudgetBytes {
                        let g = GrantedSettings(contextTokens: ctx, memoryBytes: mem)
                        if self.config.grantedAuto[self.config.run.modelID] != g {
                            self.config.grantedAuto[self.config.run.modelID] = g
                        }
                    }
                    let draft = await self.client.fetchMetric("splash_draft_acceptance_ratio")
                    self.draftAcceptance = draft

                    let pre = snap?.prefilling ?? 0
                    let dec = snap?.decoding ?? 0
                    let stage: SampleStage? = pre > 0 ? .prefill : (dec > 0 ? .decode : nil)
                    let decodeTps: Double?
                    let prefillTps: Double?
                    if stage != nil {
                        decodeTps = await self.client.fetchMetric("splash_decode_tokens_per_second")
                        prefillTps = await self.client.fetchMetric("splash_prefill_tokens_per_second")
                    } else {
                        decodeTps = nil
                        prefillTps = nil
                    }
                    let sample = StatusSample(
                        time: Date(),
                        ttftP50: stage == nil ? nil : snap?.ttftP50,
                        draftAcceptance: stage == nil ? nil : draft,
                        cacheHitRate: stage == nil ? nil : snap?.cacheHitRate,
                        decodeTps: decodeTps,
                        prefillTps: prefillTps,
                        stage: stage
                    )
                    self.history.append(sample)
                    if self.history.count > 480 { self.history.removeFirst(self.history.count - 480) }
                    self.currentStage = stage
                    // Performance logging rides this poll: the same /status data the Status
                    // tab shows, written every Nth tick. No extra requests to the engine.
                    self.pollTick += 1
                    if self.config.performanceLoggingEnabled, stage != nil,
                       PerformanceLog.shouldSample(tick: self.pollTick,
                                                   interval: self.config.performanceLogInterval) {
                        self.performanceLog.write(PerformanceSample(
                            ts: sample.time,
                            model: self.effectiveModel ?? self.config.run.modelID,
                            engine: self.engineVersion,
                            stage: stage.map { $0 == .prefill ? "prefill" : "decode" },
                            ttftP50: snap?.ttftP50,
                            ttftP95: snap?.ttftP95,
                            itlP50: snap?.itlP50,
                            itlP95: snap?.itlP95,
                            decodeTps: decodeTps,
                            prefillTps: prefillTps,
                            draftAcceptance: draft,
                            cacheHitRate: snap?.cacheHitRate,
                            reusedTokens: snap?.reusedTokens,
                            cacheLookups: snap?.cacheLookups,
                            queued: snap?.queued,
                            prefilling: snap?.prefilling,
                            decoding: snap?.decoding,
                            kvPagesActive: snap?.kvPagesActive,
                            kvBlockTokens: snap?.kvBlockTokens,
                            hardBudgetBytes: snap?.hardBudgetBytes,
                            contextTokens: snap?.maxContextTokens,
                            physicalRAM: MachineInfo.physicalRAM,
                            metalMaxWorkingSet: MachineInfo.metalMaxWorkingSet))
                    }
                } else if self.phase == .starting {
                    let alive = self.adoptedPID.map { kill(Int32($0), 0) == 0 } ?? self.server.isRunning
                    if !alive {
                        self.phase = .stopped
                        self.lastError = self.failureHint()
                        return
                    }
                } else if self.phase == .ready {
                    self.phase = .exited("lost /ready; engine may be recovering or stopped")
                    let snap = await self.client.fetchStatus()
                    self.status = snap
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

enum SampleStage: Equatable {
    case prefill
    case decode
}

struct StatusSample {
    let time: Date
    let ttftP50: Double?
    let draftAcceptance: Double?
    let cacheHitRate: Double?
    let decodeTps: Double?
    let prefillTps: Double?
    let stage: SampleStage?
}
// Headless assertions for SplashGUI's config store and per-model profiles — no GUI, no Xcode.
// Run via ./run.sh (it handles the config.json backup/fixture dance). Exits non-zero on any failure.
import Foundation
import SwiftUI
import Network

let A = "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS"
let B = "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0"
let C = "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"

var failures = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "PASS  " : "FAIL  ") + label + (detail.isEmpty ? "" : "  — " + detail))
    if !cond { failures += 1 }
}

@MainActor
func runTests() {
    // A: a pre-profiles config still decodes (no fallback to factory) and migrates.
    let cfg = ConfigStore.shared.load()
    check("old config decodes — typed values survived",
          cfg.run.maxContext == "100K" && cfg.sampling.temperature == 0.23,
          "\(cfg.run.maxContext) / \(cfg.sampling.temperature)")
    check("schemaVersion migrated to 7", cfg.run.schemaVersion == 7, "\(cfg.run.schemaVersion ?? -1)")
    let brew = EngineInstaller.externalEngineVersion()
    check("schema 7 prefers a Homebrew engine when one is installed",
          brew == nil ? cfg.engineMode == .pinned : cfg.engineMode == .homebrew,
          "\(cfg.engineMode) brew \(brew ?? "none")")
    // v2 flipped int8→bf16, v3 flipped bf16→auto; v6 then resolved the still-auto KV because
    // the typed maxContext keeps Auto off. The endpoint that matters: a concrete KV pick.
    check("typed serve fields migrate to Auto off", cfg.run.auto == false)
    check("auto KV resolved on the Auto-off migration",
          cfg.run.kvFormat == "bf16" || cfg.run.kvFormat == "int8", cfg.run.kvFormat)
    check("v4->v5 turned the SSD tier on", cfg.run.maxCacheDisk == "10G", cfg.run.maxCacheDisk)
    check("idle release defaults to 60m", cfg.run.idleRelease == "60m", cfg.run.idleRelease)
    check("persistent cache defaults on", cfg.run.persistentCache == true)
    check("current model got a seeded profile", cfg.modelProfiles[A] != nil)
    check("seed keeps tuned temp 0.23", cfg.modelProfiles[A]?.sampling.temperature == 0.23)
    check("key keeps the :variant suffix", cfg.modelProfiles.keys.contains { $0.contains(":UD-IQ3_XXS") })

    // B: switching to an untuned model starts it on its CARD — the thinking-mode set both cards
    // publish (1.0 / 0.95 / 20, reasoning left at model default).
    let m = AppModel()
    m.config.sampling.temperature = 0.42
    m.config.sampling.reasoningEffort = "low"
    m.config.run.defaultReasoningEffort = "low"
    m.config.run.maxContext = "100K"
    m.config.run.languageOnly = true
    m.selectModelID(B)
    check("modelID switched", m.config.run.modelID == B)
    check("outgoing temp archived", m.config.modelProfiles[A]?.sampling.temperature == 0.42)
    check("outgoing maxContext archived", m.config.modelProfiles[A]?.maxContext == "100K")
    check("Bonsai card temp 1.0", m.config.sampling.temperature == 1.0, "\(m.config.sampling.temperature)")
    check("Bonsai card topP 0.95", m.config.sampling.topP == 0.95, "\(m.config.sampling.topP)")
    check("Bonsai card topK 20", m.config.sampling.topK == 20, "\(m.config.sampling.topK)")
    check("card leaves reasoning effort at model default",
          m.config.sampling.reasoningEffort == nil && m.config.run.defaultReasoningEffort == nil)
    check("untuned model: maxContext back to auto", m.config.run.maxContext == "auto", m.config.run.maxContext)
    check("untuned model: languageOnly off", m.config.run.languageOnly == false)

    // C: switching back restores the saved profile.
    m.selectModelID(A)
    check("restored temp 0.42", m.config.sampling.temperature == 0.42, "\(m.config.sampling.temperature)")
    check("restored maxContext 100K", m.config.run.maxContext == "100K")
    check("restored reasoning effort (both places)",
          m.config.sampling.reasoningEffort == "low" && m.config.run.defaultReasoningEffort == "low")

    // The served name names the model, so it swaps with the profile, and a model entered
    // without a saved name starts blank rather than keeping the name of the one left.
    m.config.run.servedModelName = "qwen27"
    m.config.run.announceServedName = true
    m.selectModelID(B)
    check("served name archived with the outgoing profile",
          m.config.modelProfiles[A]?.servedModelName == "qwen27"
            && m.config.modelProfiles[A]?.announceServedName == true)
    check("switching restores a blank served name for a model without one",
          m.config.run.servedModelName.isEmpty && m.config.run.announceServedName == false)
    m.selectModelID(A)
    check("served name restored with the profile",
          m.config.run.servedModelName == "qwen27" && m.config.run.announceServedName == true)

    // D: a second Qwen row is also card-driven, and card data is per row.
    m.selectModelID(C)
    check("Qwen Q4_K_M card temp 1.0", m.config.sampling.temperature == 1.0, "\(m.config.sampling.temperature)")
    check("Qwen Q4_K_M card topP 0.95", m.config.sampling.topP == 0.95)
    let bonsai = CatalogModel.catalog.first { $0.id == B }!
    check("Bonsai hides the unsupported 'low' effort",
          bonsai.supportedEfforts?.contains("low") == false
            && bonsai.supportedEfforts?.contains("xhigh") == true,
          "\(bonsai.supportedEfforts ?? [])")
    m.config.run.modelID = B
    check("model exposes the filtered effort list", m.supportedEfforts == bonsai.supportedEfforts)
    m.config.run.modelID = "someone/Custom-Model:x"
    check("hand-typed ID offers every effort", m.supportedEfforts == CatalogModel.allEfforts)

    // E: reset forgets this model's profile and returns to its card.
    m.config.run.modelID = A
    m.resetModelProfile()
    check("reset cleared the stored profile", m.config.modelProfiles[A] == nil)
    check("reset re-applies the card (1.0 / 0.95 / 20)",
          m.config.sampling.temperature == 1.0 && m.config.sampling.topP == 0.95 && m.config.sampling.topK == 20,
          "\(m.config.sampling.temperature)/\(m.config.sampling.topP)/\(m.config.sampling.topK)")
    check("reset returns serve fields to auto",
          m.config.run.maxContext == "auto" && m.config.run.kvFormat == "auto" && m.config.run.languageOnly == false)

    // G: thinking off offers the card's non-thinking set, and only on click.
    m.config.sampling.reasoningEffort = "none"
    m.config.run.defaultReasoningEffort = "none"
    m.applyCardOffSampling()
    check("card's non-thinking set applied on request (0.7 / 0.80 / 20)",
          m.config.sampling.temperature == 0.7 && m.config.sampling.topP == 0.8 && m.config.sampling.topK == 20,
          "\(m.config.sampling.temperature)/\(m.config.sampling.topP)/\(m.config.sampling.topK)")
    m.config.sampling.temperature = 0.55          // hand-tuned value must survive
    m.config.run.modelID = "someone/Custom-Model:x"
    m.applyCardOffSampling()
    check("hand-typed ID has no card, so nothing is rewritten",
          m.config.sampling.temperature == 0.55, "\(m.config.sampling.temperature)")

    // H: what landed on disk reloads the same.
    let reread = ConfigStore.shared.load()
    check("B's card profile persisted", reread.modelProfiles[B]?.sampling.temperature == 1.0,
          "\(reread.modelProfiles[B]?.sampling.temperature ?? -1)")
    check("typed temp 0.55 survives a save", reread.sampling.temperature == 0.55,
          "\(reread.sampling.temperature)")
    check("schemaVersion stays 7", reread.run.schemaVersion == 7)
    // startOnLaunch is absent from this v2 fixture — the tolerant decoder must default it
    // false, not throw the whole config back to factory (the Codable missing-key trap).
    check("startOnLaunch defaults false when the key is absent", reread.startOnLaunch == false)

    // F: the SSD tier and the idle release reach the engine's command line, and the tier's
    // persistence follows the quota (the engine refuses it without one).
    var run = RunConfig()
    run.maxCacheDisk = "10G"
    run.persistentCache = true
    run.idleRelease = "60m"
    let args = SplashServer.buildArguments(for: run)
    check("serve carries the SSD quota", args.contains("--max-cache-disk") && args.contains("10G"))
    check("serve carries the persistent cache", args.contains("--persistent-cache"))
    check("serve carries the idle release", args.contains("--idle-release") && args.contains("60m"))
    var off = RunConfig()
    off.maxCacheDisk = "0"
    off.persistentCache = true
    check("no persistent cache without a quota",
          !SplashServer.buildArguments(for: off).contains("--persistent-cache"))
    off.persistentCache = false
    off.idleRelease = "auto"
    let offArgs = SplashServer.buildArguments(for: off)
    check("persistent cache can be turned off", !offArgs.contains("--persistent-cache"))
    check("auto leaves the engine's own idle release", !offArgs.contains("--idle-release"))
    off.maxCacheDisk = "auto"
    check("auto leaves the SSD quota to the engine", !SplashServer.buildArguments(for: off).contains("--max-cache-disk"))

    // F2: LAN serving. --host goes to the engine only when the toggle is on, and a config
    // written before the toggle existed must decode it defaulted, not throw (the Codable trap).
    check("loopback default: no --host on the command line",
          !SplashServer.buildArguments(for: RunConfig()).contains("--host"))
    var lan = RunConfig()
    lan.lanAccess = true
    let lanArgs = SplashServer.buildArguments(for: lan)
    check("LAN on: --host 0.0.0.0 reaches the engine",
          lanArgs.firstIndex(of: "--host").map { $0 + 1 < lanArgs.count && lanArgs[$0 + 1] == "0.0.0.0" } == true,
          lanArgs.joined(separator: " "))
    let lanHostArgs = SplashServer.buildArguments(for: lan, allowedHosts: ["10.0.0.221"])
    check("LAN on: --allowed-host carries the LAN address",
          lanHostArgs.firstIndex(of: "--allowed-host").map {
              $0 + 1 < lanHostArgs.count && lanHostArgs[$0 + 1] == "10.0.0.221"
          } == true, lanHostArgs.joined(separator: " "))
    check("no --allowed-host when none is passed",
          !SplashServer.buildArguments(for: lan).contains("--allowed-host"))
    let noLan = #"{"run":{"port":8123,"modelID":"someone/Model:x"}}"#
    if let nd = noLan.data(using: .utf8),
       let ncfg = try? JSONDecoder().decode(AppConfig.self, from: nd) {
        check("lanAccess absent decodes false without losing the config",
              ncfg.run.lanAccess == false && ncfg.run.port == 8123
                && ncfg.run.modelID == "someone/Model:x")
    } else {
        check("lanAccess absent decodes false without losing the config", false, "decoder threw")
    }
    var lcfg = AppConfig()
    lcfg.run.lanAccess = true
    if let ld = try? JSONEncoder().encode(lcfg),
       let lback = try? JSONDecoder().decode(AppConfig.self, from: ld) {
        check("lanAccess round-trips through a save", lback.run.lanAccess == true)
    } else {
        check("lanAccess round-trips through a save", false, "encode/decode threw")
    }

    // F3: the serve options (offline, thinking budget, verify-rows, served name, arch memory
    // knobs). Defaults stay off the command line, a config written before they existed decodes
    // them defaulted (the Codable trap), and the arch knobs reach only models that have the
    // memory they tune.
    func flagValue(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let plainArgs = SplashServer.buildArguments(for: RunConfig())
    check("new serve options stay off the command line by default",
          !plainArgs.contains("--offline") && !plainArgs.contains("--thinking-token-budget")
            && !plainArgs.contains("--verify-rows") && !plainArgs.contains("--served-model-name")
            && !plainArgs.contains("--announce-served-name") && !plainArgs.contains("--ple-memory")
            && !plainArgs.contains("--expert-memory") && !plainArgs.contains("--sparse-kv-memory"),
          plainArgs.joined(separator: " "))
    var so = RunConfig()
    so.offline = true
    so.thinkingTokenBudget = "16384"
    so.verifyRowsAll = true
    so.servedModelName = "qwen27"
    so.announceServedName = true
    so.pleMemory = "2G"
    so.expertMemory = "16G"
    so.sparseKvMemory = "1200M"
    let soArgs = SplashServer.buildArguments(for: so)
    check("offline reaches the engine", soArgs.contains("--offline"))
    check("thinking budget reaches the engine",
          flagValue(soArgs, "--thinking-token-budget") == "16384", soArgs.joined(separator: " "))
    check("verify-rows all reaches the engine", flagValue(soArgs, "--verify-rows") == "all")
    check("served name reaches the engine", flagValue(soArgs, "--served-model-name") == "qwen27")
    check("announce reaches the engine with a name", soArgs.contains("--announce-served-name"))
    check("PLE memory reaches the engine", flagValue(soArgs, "--ple-memory") == "2G")
    check("expert memory reaches the engine", flagValue(soArgs, "--expert-memory") == "16G")
    check("sparse-KV memory reaches the engine", flagValue(soArgs, "--sparse-kv-memory") == "1200M")
    var nameless = RunConfig()
    nameless.announceServedName = true
    check("announce without a served name passes nothing",
          !SplashServer.buildArguments(for: nameless).contains("--announce-served-name"))
    let noOptions = #"{"run":{"port":8123,"modelID":"someone/Model:x"}}"#
    if let od = noOptions.data(using: .utf8),
       let ocfg = try? JSONDecoder().decode(AppConfig.self, from: od) {
        check("serve options absent decode defaulted without losing the config",
              ocfg.run.offline == false && ocfg.run.thinkingTokenBudget.isEmpty
                && ocfg.run.verifyRowsAll == false && ocfg.run.servedModelName.isEmpty
                && ocfg.run.announceServedName == false && ocfg.run.pleMemory.isEmpty
                && ocfg.run.expertMemory.isEmpty && ocfg.run.sparseKvMemory.isEmpty
                && ocfg.run.port == 8123 && ocfg.run.modelID == "someone/Model:x")
    } else {
        check("serve options absent decode defaulted without losing the config", false, "decoder threw")
    }
    var ocfg2 = AppConfig()
    ocfg2.run.offline = true
    ocfg2.run.thinkingTokenBudget = "16384"
    ocfg2.run.servedModelName = "qwen27"
    ocfg2.run.announceServedName = true
    ocfg2.run.pleMemory = "2G"
    if let od2 = try? JSONEncoder().encode(ocfg2),
       let oback = try? JSONDecoder().decode(AppConfig.self, from: od2) {
        check("serve options round-trip through a save",
              oback.run.offline == true && oback.run.thinkingTokenBudget == "16384"
                && oback.run.servedModelName == "qwen27" && oback.run.announceServedName == true
                && oback.run.pleMemory == "2G")
    } else {
        check("serve options round-trip through a save", false, "encode/decode threw")
    }
    // The arch gate on the launch copy: knobs typed for a model that lacks the memory never
    // reach the engine; the models that have them keep them.
    let flashNextID = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0"
    let moeID = "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M"
    func knobsKept(_ id: String) -> (ple: Bool, expert: Bool, sparseKv: Bool) {
        var r = RunConfig()
        r.pleMemory = "2G"
        r.expertMemory = "16G"
        r.sparseKvMemory = "1200M"
        r.clearingUnsupportedMemoryKnobs(forModelID: id)
        return (!r.pleMemory.isEmpty, !r.expertMemory.isEmpty, !r.sparseKvMemory.isEmpty)
    }
    let denseKept = knobsKept(A)
    check("knobs dropped for a dense 27B row",
          !denseKept.ple && !denseKept.expert && !denseKept.sparseKv)
    let fnKept = knobsKept(flashNextID)
    check("Flash-Next keeps PLE and sparse-KV, drops experts",
          fnKept.ple && fnKept.sparseKv && !fnKept.expert)
    let moeKept = knobsKept(moeID)
    check("MoE keeps experts, drops PLE and sparse-KV",
          moeKept.expert && !moeKept.ple && !moeKept.sparseKv)
    let customFN = knobsKept("someone/MyQwen3.8-Flash-Next-Quant:Q4")
    check("hand-typed Flash-Next ID keeps its knobs by name",
          customFN.ple && customFN.sparseKv && !customFN.expert)
    let customNone = knobsKept("someone/Custom-Model:x")
    check("unknown custom ID gets no knobs",
          !customNone.ple && !customNone.expert && !customNone.sparseKv)

    // I: the Auto switch resolves the four covered fields at launch.
    let prof = AutoProfile(maxMemoryBytes: 40_000_000_000, contextTokens: 131_072, kvFormat: "int8")
    var arun = RunConfig()   // shipped default: Auto on
    let effAuto = arun.effective(using: prof)
    check("Auto on: profile sizes context and memory",
          effAuto.maxContext == "131072" && effAuto.maxMemory == "40000000000",
          "\(effAuto.maxContext) / \(effAuto.maxMemory)")
    check("Auto on: KV follows the profile", effAuto.kvFormat == "int8")
    check("Auto on: the SSD cache goes to the engine",
          effAuto.maxCacheDisk == "auto"
            && !SplashServer.buildArguments(for: effAuto).contains("--max-cache-disk"))
    let effCustom = arun.effective(using: nil)
    check("Auto on with no profile: Splash sizes context and memory, KV falls back to bf16",
          !SplashServer.buildArguments(for: effCustom).contains("--max-context")
            && !SplashServer.buildArguments(for: effCustom).contains("--max-memory")
            && effCustom.kvFormat == "bf16")
    arun.auto = false
    arun.maxContext = "64K"; arun.maxMemory = "24G"; arun.kvFormat = "bf16"; arun.maxCacheDisk = "10G"
    let effTyped = arun.effective(using: prof)
    check("Auto off: the typed values launch untouched",
          effTyped.maxContext == "64K" && effTyped.maxMemory == "24G"
            && effTyped.kvFormat == "bf16" && effTyped.maxCacheDisk == "10G")

    // J: the Codable trap on the fields — a profile saved before `auto` existed must
    // decode with it defaulted, and grantedAuto must round-trip.
    let legacy = #"{"sampling":{"temperature":0.5,"topP":0.9,"topK":10},"maxContext":"50K","maxMemory":"auto","kvFormat":"bf16","languageOnly":false}"#
    if let pdata = legacy.data(using: .utf8),
       let prof2 = try? JSONDecoder().decode(ModelProfile.self, from: pdata) {
        check("legacy profile without auto decodes defaulted",
              prof2.auto == true && prof2.maxContext == "50K")
    } else {
        check("legacy profile without auto decodes defaulted", false, "decoder threw")
    }
    var gcfg = AppConfig()
    gcfg.grantedAuto["someone/Custom-Model:x"] = GrantedSettings(contextTokens: 65536, memoryBytes: 25_769_803_776)
    if let gd = try? JSONEncoder().encode(gcfg),
       let back = try? JSONDecoder().decode(AppConfig.self, from: gd) {
        check("grantedAuto round-trips",
              back.grantedAuto["someone/Custom-Model:x"]?.contextTokens == 65536
                && back.grantedAuto["someone/Custom-Model:x"]?.memoryBytes == 25_769_803_776)
    } else {
        check("grantedAuto round-trips", false, "encode/decode threw")
    }

    // K: a schema-5 config whose four covered fields are all "auto" migrates to Auto ON,
    // leaving the KV field alone for the launch-time resolution.
    let cfgURL = AppPaths.dataDir.appendingPathComponent("config.json")
    if let raw = try? Data(contentsOf: cfgURL),
       var dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
       var runDict = dict["run"] as? [String: Any] {
        runDict["schemaVersion"] = 5
        runDict["maxContext"] = "auto"
        runDict["maxMemory"] = "auto"
        runDict["kvFormat"] = "auto"
        runDict["maxCacheDisk"] = "auto"
        dict["run"] = runDict
        if let out = try? JSONSerialization.data(withJSONObject: dict) {
            try? out.write(to: cfgURL)
            let migrated = ConfigStore.shared.load()
            check("all-auto schema 5 migrates to Auto on", migrated.run.auto == true)
            check("all-auto migration leaves KV at auto",
                  migrated.run.kvFormat == "auto", migrated.run.kvFormat)
            check("all-auto migration lands on schema 7", migrated.run.schemaVersion == 7)
        } else {
            check("all-auto schema 5 migrates to Auto on", false, "fixture write failed")
        }
    } else {
        check("all-auto schema 5 migrates to Auto on", false, "fixture unreadable")
    }

    // L: the Provider tab's sampling fields and client configs.
    let legacySampling = #"{"temperature":0.5,"topP":0.9,"topK":10,"maxTokens":null,"seed":null,"reasoningEffort":"none"}"#
    if let sdata = legacySampling.data(using: .utf8),
       let sam = try? JSONDecoder().decode(SamplingDefaults.self, from: sdata) {
        check("legacy sampling without presencePenalty/minP decodes defaulted",
              sam.presencePenalty == 0 && sam.minP == 0 && sam.reasoningEffort == "none")
    } else {
        check("legacy sampling without presencePenalty/minP decodes defaulted", false, "threw")
    }
    let bonsaiRow = CatalogModel.catalog.first { $0.id == B }!
    check("Bonsai card: min_p 0.05, presence 0 in thinking mode",
          bonsaiRow.cardProfile().sampling.minP == 0.05
            && bonsaiRow.cardProfile().sampling.presencePenalty == 0)
    m.config.run.modelID = A
    m.applyCardOffSampling()
    check("card-off applies presence 1.5 and min_p 0",
          m.config.sampling.presencePenalty == 1.5 && m.config.sampling.minP == 0
            && m.config.sampling.temperature == 0.7)
    check("parseContext reads the field spellings",
          AppModel.parseContext("100K") == 102_400 && AppModel.parseContext("131072") == 131_072
            && AppModel.parseContext("auto") == nil)

    var sam = SamplingDefaults()
    sam.seed = 12_345_678_901
    let base = ClientConfigContext(client: .opencode, modelID: "someone/Model:x", label: "Model X",
                                   port: 8095, contextTokens: 65_536,
                                   inputModalities: ["text", "image", "pdf"], sampling: sam)
    if let data = ClientConfigs.text(for: base).data(using: .utf8),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let provider = (root["providers"] as? [String: Any])?["splashgui"] as? [String: Any],
       let models = provider["models"] as? [String: Any],
       let model = models["someone/Model:x"] as? [String: Any] {
        let body = model["body"] as? [String: Any]
        check("OpenCode: sampling in the model body",
              (body?["temperature"] as? Double) == 1.0 && (body?["top_k"] as? Int) == 20
                && (body?["presence_penalty"] as? Double) == 0 && (body?["min_p"] as? Double) == 0)
        check("OpenCode: seed passes through body", body?["seed"] != nil)
        let limit = model["limit"] as? [String: Any]
        check("OpenCode: limit math at 64K — out 16384, in 49152",
              (limit?["context"] as? Int) == 65_536 && (limit?["output"] as? Int) == 16_384
                && (limit?["input"] as? Int) == 49_152)
        check("OpenCode: no root model/small_model or agent overrides",
              root["model"] == nil && root["small_model"] == nil
                && root["agent"] == nil && root["agents"] == nil)
        let variants = model["variants"] as? [[String: Any]]
        let variantIDs = variants?.compactMap { $0["id"] as? String }
        let highBody = variants?.first { ($0["id"] as? String) == "high" }?["body"] as? [String: Any]
        check("OpenCode: one variant per effort, reasoning_effort in the body",
              variantIDs == CatalogModel.allEfforts
                && (highBody?["reasoning_effort"] as? String) == "high")
        let reasoning = (model["capabilities"] as? [String: Any])?["reasoning"] as? [String: Any]
        check("OpenCode: reasoning capability advertises the efforts",
              (reasoning?["supported"] as? Bool) == true && (reasoning?["toggle"] as? Bool) == true
                && (reasoning?["effort"] as? [String])?.contains("high") == true)
        let settings = provider["settings"] as? [String: Any]
        let compatibility = model["compatibility"] as? [String: Any]
        check("OpenCode: V2 package + baseURL, reasoning_content and max_tokens compatibility",
              (provider["package"] as? String) == "@opencode/ai/providers/openai-compatible"
                && (settings?["baseURL"] as? String) == "http://127.0.0.1:8095/v1"
                && (compatibility?["reasoningField"] as? String) == "reasoning_content"
                && (compatibility?["maxTokensField"] as? String) == "max_tokens")
    } else {
        check("OpenCode: sampling in the model body", false, "config did not parse")
    }
    let zctx = ClientConfigContext(client: .zed, modelID: base.modelID, label: base.label,
                                   port: base.port, contextTokens: base.contextTokens,
                                   inputModalities: base.inputModalities, sampling: base.sampling)
    let ztext = ClientConfigs.text(for: zctx)
    check("Zed: openai_compatible + api_url + temperature only",
          ztext.contains("openai_compatible") && ztext.contains("api_url")
            && ztext.contains("model_parameters") && !ztext.contains("top_k")
            && ztext.contains("interleaved_reasoning"))
    let cctx = ClientConfigContext(client: .claudeCode, modelID: base.modelID, label: base.label,
                                   port: base.port, contextTokens: base.contextTokens,
                                   inputModalities: base.inputModalities, sampling: base.sampling)
    let ctext = ClientConfigs.text(for: cctx)
    check("Claude Code: env block, bare base URL (no /v1), no sampling",
          ctext.contains("ANTHROPIC_BASE_URL") && ctext.contains("http://127.0.0.1:8095\"")
            && !ctext.contains("/v1") && !ctext.contains("temperature"))
    let xctx = ClientConfigContext(client: .codex, modelID: base.modelID, label: base.label,
                                   port: base.port, contextTokens: base.contextTokens,
                                   inputModalities: base.inputModalities, sampling: base.sampling)
    let xtext = ClientConfigs.text(for: xctx)
    check("Codex: TOML provider, responses wire, 90% compact limit",
          xtext.contains("wire_api = \"responses\"") && xtext.contains("env_key = \"SPLASH_API_KEY\"")
            && xtext.contains("model_auto_compact_token_limit = 58982")
            && xtext.contains("model_provider = \"splash\""))
    var offSam = SamplingDefaults()
    offSam.temperature = 0.7; offSam.topP = 0.8; offSam.topK = 20
    offSam.presencePenalty = 1.5; offSam.minP = 0.05
    let pctx = ClientConfigContext(client: .pi, modelID: base.modelID, label: base.label,
                                   port: base.port, contextTokens: base.contextTokens,
                                   inputModalities: base.inputModalities, sampling: base.sampling,
                                   offSampling: offSam, laterSystem: true)
    if let data = ClientConfigs.text(for: pctx).data(using: .utf8),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let provider = (root["providers"] as? [String: Any])?["splash"] as? [String: Any],
       let models = provider["models"] as? [[String: Any]],
       let model = models.first {
        let sp = model["samplingParams"] as? [String: Any]
        let byLevel = model["samplingParamsByThinkingLevel"] as? [String: Any]
        let off = byLevel?["off"] as? [String: Any]
        check("Pi: provider shape matches splash pi",
              (provider["baseUrl"] as? String) == "http://127.0.0.1:8095/v1"
                && (provider["api"] as? String) == "openai-completions"
                && (provider["apiKey"] as? String) == "local"
                && (model["id"] as? String) == "someone/Model:x"
                && (model["reasoning"] as? Bool) == true
                && (model["contextWindow"] as? Int) == 65_536
                && (model["maxTokens"] as? Int) == 32_768
                && (model["input"] as? [String]) == ["text", "image"]
                && ((model["thinkingLevelMap"] as? [String: Any])?["off"] as? String) == "none"
                && ((model["compat"] as? [String: Any])?["supportsMidConvoSystemMessages"] as? Bool) == true)
        check("Pi: samplingParams carry the model's sampling",
              (sp?["temperature"] as? Double) == 1.0 && (sp?["top_p"] as? Double) == 0.95
                && (sp?["top_k"] as? Int) == 20 && (sp?["presence_penalty"] as? Double) == 0
                && (sp?["min_p"] as? Double) == 0 && (sp?["seed"] as? UInt64) == 12_345_678_901)
        check("Pi: thinking-off set rides samplingParamsByThinkingLevel.off",
              (off?["temperature"] as? Double) == 0.7 && (off?["top_p"] as? Double) == 0.8
                && (off?["top_k"] as? Int) == 20 && (off?["presence_penalty"] as? Double) == 1.5
                && (off?["min_p"] as? Double) == 0.05)
    } else {
        check("Pi: provider shape matches splash pi", false, "config did not parse")
    }
    let pOff = ClientConfigContext(client: .pi, modelID: base.modelID, label: base.label,
                                   port: 9000, contextTokens: base.contextTokens,
                                   inputModalities: ["text"], sampling: base.sampling)
    let pOffText = ClientConfigs.text(for: pOff)
    check("Pi: off-default port names the provider splash-<port>, text-only, no compat",
          pOffText.contains("\"splash-9000\"") && pOffText.contains("\"text\"")
            && !pOffText.contains("image")
            && !pOffText.contains("supportsMidConvoSystemMessages")
            && !pOffText.contains("samplingParamsByThinkingLevel"))
    // The Provider tab's LAN toggle swaps the loopback host for this Mac's LAN address in
    // every client's endpoint (the API has no key; the caption warns about that).
    var lanBase = base
    lanBase.host = "10.0.0.221"
    let lanClaude = ClientConfigContext(client: .claudeCode, modelID: base.modelID,
                                        label: base.label, host: "10.0.0.221", port: base.port,
                                        contextTokens: base.contextTokens,
                                        inputModalities: base.inputModalities,
                                        sampling: base.sampling)
    check("LAN host reaches every client endpoint",
          ClientConfigs.text(for: lanBase).contains("http://10.0.0.221:8095/v1")
            && ClientConfigs.text(for: lanClaude).contains("http://10.0.0.221:8095\"")
            && !ClientConfigs.text(for: lanClaude).contains("127.0.0.1"))

    // The served name, when set, replaces the Hub ID in the configs the Provider tab writes.
    let priorID = m.config.run.modelID
    m.config.run.modelID = A
    m.config.run.servedModelName = "qwen27"
    let stext = m.clientConfigText(for: .claudeCode)
    check("served name: client configs name the model by it",
          stext.contains("\"qwen27\"") && !stext.contains(A))
    m.config.run.servedModelName = ""
    let ftext = m.clientConfigText(for: .claudeCode)
    check("no served name: the full Hub ID is written as before",
          ftext.contains(A) && !ftext.contains("qwen27"))
    m.config.run.modelID = priorID

    // M: engine source — the mode field's tolerant decode and the latest-release resolver.
    // Synthetic JSON, not the live fixture: the app writes engineMode, so the on-disk
    // config always has the key and cannot prove the absent-key default.
    let noMode = #"{"engineURLOverride":"keep-me","sampling":{"temperature":0.3}}"#
    if let nm = noMode.data(using: .utf8),
       let ncfg = try? JSONDecoder().decode(AppConfig.self, from: nm) {
        check("engineMode absent decodes pinned without losing the config",
              ncfg.engineMode == .pinned && ncfg.sampling.temperature == 0.3
                && ncfg.engineURLOverride == "keep-me")
    } else {
        check("engineMode absent decodes pinned without losing the config", false, "decoder threw")
    }
    let oddMode = #"{"engineMode":"sideways","sampling":{"temperature":0.3}}"#
    if let od = oddMode.data(using: .utf8),
       let om = try? JSONDecoder().decode(AppConfig.self, from: od) {
        check("unknown engineMode falls back to pinned without losing the config",
              om.engineMode == .pinned && om.sampling.temperature == 0.3)
    } else {
        check("unknown engineMode falls back to pinned without losing the config", false, "decoder threw")
    }
    var mcfg = AppConfig()
    mcfg.engineMode = .latest
    if let md = try? JSONEncoder().encode(mcfg),
       let mback = try? JSONDecoder().decode(AppConfig.self, from: md) {
        check("engineMode round-trips", mback.engineMode == .latest)
    } else {
        check("engineMode round-trips", false, "encode/decode threw")
    }
    // The resolver's pure half, fed a fixture built FROM the compiled-in pin (so a pin bump
    // cannot stale this check). A latest that equals the pin must produce the identical URL
    // so EngineInstaller reuses its directory instead of keying a hash-named twin off the URL.
    let pinV = EngineInstaller.defaultPin.version
    let assetsPin = ["splash-\(pinV)-arm64-macos26.tar.gz", "splash-\(pinV)-arm64-macos26.tar.gz.sha256",
                     "Splash-\(pinV).dmg", "SHA256SUMS", "appcast.xml"]
    if let lp = EngineResolver.pin(tagName: pinV, assetNames: assetsPin, sha256Text: EngineInstaller.defaultPin.sha256 + "\n") {
        check("latest equal to the compiled-in pin resolves to the identical pin",
              lp == EngineInstaller.defaultPin, "\(lp.version) \(lp.url)")
        check("latest-equals-pinned reuses the pinned install dir",
              EngineInstaller.dirName(for: lp) == EngineInstaller.dirName(for: EngineInstaller.defaultPin))
    } else {
        check("latest equal to the compiled-in pin resolves to the identical pin", false, "pin() returned nil")
        check("latest-equals-pinned reuses the pinned install dir", false)
    }
    // A latest NEWER than the pin: the URL diverges, so
    // dirName keys a hash-named twin — and the payload still installs because the extracted
    // directory is DISCOVERED (findExtractedRoot, above), not assumed (the redownload-loop bug).
    let v150 = "1ddc28bf7bfda8833859a913d7072e2aac9072addb9eb5664f3bf1a83a8d6ee2"
    let assets150 = ["splash-1.5.0-arm64-macos26.tar.gz", "splash-1.5.0-arm64-macos26.tar.gz.sha256"]
    if let older = EngineResolver.pin(tagName: "1.5.0", assetNames: assets150, sha256Text: v150 + "\n") {
        check("a resolved pin with a URL diverging from the compiled pin keys a hash-named dir",
              EngineInstaller.dirName(for: older) != EngineInstaller.dirName(for: EngineInstaller.defaultPin)
                && EngineInstaller.dirName(for: older).hasPrefix("splash-1.5.0-"),
              EngineInstaller.dirName(for: older))
    } else {
        check("a resolved pin with a URL diverging from the compiled pin keys a hash-named dir", false, "pin() returned nil")
    }
    if let vp = EngineResolver.pin(tagName: "v1.6.1", assetNames: ["splash-1.6.1-arm64-macos26.tar.gz",
                                                                   "splash-1.6.1-arm64-macos26.tar.gz.sha256"],
                                   sha256Text: String(repeating: "A", count: 64)) {
        check("v-prefixed tag: version stripped, download URL keeps the tag",
              vp.version == "1.6.1" && vp.url == "https://github.com/incoai/splash/releases/download/v1.6.1/splash-1.6.1-arm64-macos26.tar.gz"
                && vp.sha256 == String(repeating: "a", count: 64), "\(vp.version) \(vp.url)")
    } else {
        check("v-prefixed tag: version stripped, download URL keeps the tag", false, "pin() returned nil")
    }
    check("release without the .sha256 asset resolves to nil",
          EngineResolver.pin(tagName: "1.6.0", assetNames: ["splash-1.6.0-arm64-macos26.tar.gz"],
                             sha256Text: v150) == nil)
    check("release with a malformed checksum resolves to nil",
          EngineResolver.pin(tagName: "1.6.0", assetNames: assets150.map { $0.replacingOccurrences(of: "1.5.0", with: "1.6.0") },
                             sha256Text: "not-hex") == nil)
    check("release with a renamed payload resolves to nil",
          EngineResolver.pin(tagName: "1.6.0", assetNames: ["splash-1.6.0-x64-macos15.tar.gz",
                                                            "splash-1.6.0-x64-macos15.tar.gz.sha256"],
                             sha256Text: v150) == nil)
    var ccfg = AppConfig()
    ccfg.engineMode = .custom
    ccfg.engineVersionOverride = "1.4.1"
    ccfg.engineURLOverride = "https://github.com/incoai/splash/releases/download/1.4.1/splash-1.4.1-arm64-macos26.tar.gz"
    ccfg.engineSHA256Override = String(repeating: "b", count: 64)
    check("custom mode with all three fields yields the override pin",
          ccfg.enginePinOverride()?.version == "1.4.1")
    ccfg.engineSHA256Override = ""
    check("custom mode with a blank SHA falls back to no override", ccfg.enginePinOverride() == nil)

    // The mode table start() installs by: the custom pin applies only in custom mode, pinned
    // mode ignores the override fields, and latest falls back to the installed engine, never
    // downward to the compiled pin. No Homebrew engine (externalVersion nil) in these rows.
    let stale = EnginePin(version: "1.4.1", sha256: String(repeating: "b", count: 64),
                          url: "https://github.com/incoai/splash/releases/download/1.4.1/splash-1.4.1-arm64-macos26.tar.gz")
    let PIN = "1.6.0"
    let pinnedPlan = AppModel.enginePlan(mode: .pinned, customOverride: stale, installed: true,
                                         checkUpdate: true, latest: nil, pinnedVersion: PIN, externalVersion: nil)
    check("pinned mode ignores complete custom fields",
          pinnedPlan.override == nil && pinnedPlan.ensure == true, "\(pinnedPlan)")
    let customPlan = AppModel.enginePlan(mode: .custom, customOverride: stale, installed: true,
                                         checkUpdate: false, latest: nil, pinnedVersion: PIN, externalVersion: nil)
    check("custom mode installs the custom pin regardless of the update toggle",
          customPlan.ensure == true && customPlan.override == stale)
    let partialPlan = AppModel.enginePlan(mode: .custom, customOverride: nil, installed: true,
                                          checkUpdate: false, latest: nil, pinnedVersion: PIN, externalVersion: nil)
    check("custom mode with partial fields keeps pinned behavior",
          partialPlan.ensure == false && partialPlan.override == nil)
    let latestHit = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: true,
                                        checkUpdate: false, latest: stale, pinnedVersion: PIN, externalVersion: nil)
    check("latest mode installs the resolver answer",
          latestHit.ensure == true && latestHit.override == stale)
    let latestKeep = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: true,
                                         checkUpdate: false, latest: nil, pinnedVersion: PIN, externalVersion: nil)
    check("latest mode offline keeps the installed engine",
          latestKeep.ensure == false && latestKeep.override == nil)
    let latestBootstrap = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: false,
                                              checkUpdate: false, latest: nil, pinnedVersion: PIN, externalVersion: nil)
    check("latest mode offline with nothing installed installs the compiled pin",
          latestBootstrap.ensure == true && latestBootstrap.override == nil)

    // Homebrew adoption rows: an engine at or above the wanted build satisfies pinned and
    // latest without a download; an older one does not; custom never accepts a stand-in;
    // and latest compares against the RESOLVED newest, not the compiled pin.
    let extPinned = AppModel.enginePlan(mode: .pinned, customOverride: nil, installed: false,
                                        checkUpdate: true, latest: nil, pinnedVersion: PIN, externalVersion: "1.6.0")
    check("brew engine equal to the pin is adopted, nothing installed",
          extPinned.external && extPinned.ensure == false, "\(extPinned)")
    let extNewer = AppModel.enginePlan(mode: .pinned, customOverride: nil, installed: true,
                                       checkUpdate: true, latest: nil, pinnedVersion: PIN, externalVersion: "1.7.2")
    check("brew engine newer than the pin is adopted too",
          extNewer.external && extNewer.ensure == false)
    let extOlder = AppModel.enginePlan(mode: .pinned, customOverride: nil, installed: false,
                                       checkUpdate: true, latest: nil, pinnedVersion: PIN, externalVersion: "1.5.0")
    check("brew engine older than the pin installs the managed copy",
          !extOlder.external && extOlder.ensure == true)
    let future = EnginePin(version: "9.9.9", sha256: String(repeating: "c", count: 64),
                           url: "https://github.com/incoai/splash/releases/download/9.9.9/splash-9.9.9-arm64-macos26.tar.gz")
    let extLatestOk = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: true,
                                          checkUpdate: false, latest: stale, pinnedVersion: PIN, externalVersion: "1.6.0")
    check("brew at or above the resolved latest satisfies it",
          extLatestOk.external && extLatestOk.ensure == false && extLatestOk.override == stale)
    let extLatestOlder = AppModel.enginePlan(mode: .latest, customOverride: nil, installed: true,
                                             checkUpdate: false, latest: future, pinnedVersion: PIN, externalVersion: "1.6.0")
    check("brew older than the resolved latest installs the managed copy",
          !extLatestOlder.external && extLatestOlder.ensure == true)
    let extCustom = AppModel.enginePlan(mode: .custom, customOverride: stale, installed: true,
                                        checkUpdate: false, latest: nil, pinnedVersion: PIN, externalVersion: "9.9.9")
    check("custom mode never substitutes the brew engine",
          !extCustom.external && extCustom.ensure == true && extCustom.override == stale)
    let brewMode = AppModel.enginePlan(mode: .homebrew, customOverride: nil, installed: true,
                                       checkUpdate: true, latest: nil, pinnedVersion: PIN, externalVersion: "1.5.0")
    check("homebrew mode takes a brew engine older than the pin, no download",
          brewMode.external && brewMode.ensure == false)
    let brewMissing = AppModel.enginePlan(mode: .homebrew, customOverride: nil, installed: true,
                                          checkUpdate: false, latest: nil, pinnedVersion: PIN, externalVersion: nil)
    check("homebrew mode without brew keeps the installed engine",
          !brewMissing.external && brewMissing.ensure == false)
    let brewMissingFresh = AppModel.enginePlan(mode: .homebrew, customOverride: nil, installed: false,
                                               checkUpdate: false, latest: nil, pinnedVersion: PIN, externalVersion: nil)
    check("homebrew mode without brew and nothing installed installs the pin",
          !brewMissingFresh.external && brewMissingFresh.ensure == true)

    // Dotted version compare: numeric segments, not lexicographic.
    check("versionOrder is numeric per segment",
          EngineInstaller.versionOrder("1.10.0", "1.6.0") == .orderedDescending
            && EngineInstaller.versionOrder("1.6.0", "1.10.0") == .orderedAscending
            && EngineInstaller.versionOrder("1.6.0", "1.6.0") == .orderedSame
            && EngineInstaller.versionOrder("1.6", "1.6.0") == .orderedSame
            && EngineInstaller.versionOrder("1.6.0+build7", "1.6.0") == .orderedSame
            && EngineInstaller.versionOrder("1.5.9", "1.6.0") == .orderedAscending)

    // Brew probe against a fixture libexec: complete layout reports its version, any
    // missing piece (or a dangling brew symlink) returns nil.
    let brewFixture = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("splash-brew-fixture-\(UUID().uuidString)", isDirectory: true)
    func brewProbe(_ root: URL) -> String? { EngineInstaller.externalEngineVersion(at: root) }
    try? FileManager.default.createDirectory(at: brewFixture.appendingPathComponent("python/bin", isDirectory: true),
                                             withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: brewFixture.appendingPathComponent("install", isDirectory: true),
                                             withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: brewFixture.appendingPathComponent("python/bin/python3").path,
                                   contents: Data())
    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                           ofItemAtPath: brewFixture.appendingPathComponent("python/bin/python3").path)
    FileManager.default.createFile(atPath: brewFixture.appendingPathComponent("install/launcher.py").path,
                                   contents: Data())
    FileManager.default.createFile(atPath: brewFixture.appendingPathComponent("release.json").path,
                                   contents: Data("{ \"version\": \"9.9.9\" }".utf8))
    check("brew fixture reports its version", brewProbe(brewFixture) == "9.9.9", "\(brewProbe(brewFixture) ?? "nil")")
    try? FileManager.default.removeItem(at: brewFixture.appendingPathComponent("install/launcher.py"))
    check("brew fixture without launcher.py is not usable", brewProbe(brewFixture) == nil)
    check("a dangling path is not a brew engine",
          brewProbe(brewFixture.appendingPathComponent("nope")) == nil)
    try? FileManager.default.removeItem(at: brewFixture)

    // Extracted-payload discovery: the archive's top dir is named for the version while a
    // URL-diverging pin stages under a hashed name — the install must find the real payload
    // (this was the redownload-every-restart bug), and a payload-free staging area is nil.
    let stageFixture = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("splash-stage-fixture-\(UUID().uuidString)", isDirectory: true)
    let hashed = stageFixture.appendingPathComponent("splash-9.9.9-abcd1234-arm64-macos26", isDirectory: true)
    let canonical = stageFixture.appendingPathComponent("splash-9.9.9-arm64-macos26", isDirectory: true)
    try? FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: canonical.appendingPathComponent("release.json").path, contents: Data())
    check("findExtractedRoot discovers the archive-named payload",
          EngineInstaller.findExtractedRoot(in: stageFixture, preferring: hashed)?.lastPathComponent
              == "splash-9.9.9-arm64-macos26")
    try? FileManager.default.createDirectory(at: hashed, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: hashed.appendingPathComponent("release.json").path, contents: Data())
    check("findExtractedRoot prefers the name-keyed payload when it exists",
          EngineInstaller.findExtractedRoot(in: stageFixture, preferring: hashed)?.lastPathComponent
              == "splash-9.9.9-abcd1234-arm64-macos26")
    try? FileManager.default.removeItem(at: stageFixture)
    check("an empty staging area yields no payload dir",
          EngineInstaller.findExtractedRoot(in: stageFixture, preferring: hashed) == nil)

    // N: the catalog must track the installed engine's suggested list. Skips with a PASS when
    // no engine is installed on the test machine.
    let tsv = EngineInstaller.currentLink.appendingPathComponent("install/suggested-models.tsv")
    if let tsvText = try? String(contentsOf: tsv, encoding: .utf8) {
        let ids = tsvText.split(separator: "\n").compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            return s.split(separator: "\t").first.map(String.init)
        }
        let cat = CatalogModel.catalog.map(\.id).filter { $0 != "custom" }
        check("catalog matches the installed engine's suggested list",
              cat == ids, "catalog \(cat.count) vs tsv \(ids.count)"
                + (cat == ids ? "" : " diff: \(Set(cat).symmetricDifference(ids).sorted())"))
        let mem = tsvText.split(separator: "\n").compactMap { line -> (String, Int)? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            let cols = s.split(separator: "\t").map(String.init)
            guard cols.count >= 3, let gb = Int(cols[2]) else { return nil }
            return (cols[0], gb)
        }
        let tsvMemory = Dictionary(mem.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let memoryDrift = CatalogModel.catalog.filter { $0.id != "custom" }.compactMap { entry -> String? in
            guard let gb = entry.memoryGB else { return "\(entry.id): catalog row lacks MEMORY" }
            return tsvMemory[entry.id] == gb ? nil : "\(entry.id): tsv \(tsvMemory[entry.id] ?? -1) vs catalog \(gb)"
        }
        check("catalog MEMORY figures match the engine's suggested list",
              memoryDrift.isEmpty, memoryDrift.joined(separator: "; "))
    } else {
        check("catalog matches the installed engine's suggested list", true, "no engine installed, skipped")
    }

    // Auto sizing constants are 27B-arch-only: other archs return nil so the engine sizes itself.
    // The synthetic weight is small so nil can only come from the arch gate, not the budget.
    check("Auto sizing skips non-27B arch rows",
          MachineInfo.autoProfile(modelID: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0",
                                  languageOnly: false, weightsBytes: 1_000_000_000) == nil)
    check("Auto sizing still covers the 27B arch",
          MachineInfo.autoProfile(modelID: A, languageOnly: false, weightsBytes: 10_000_000_000) != nil)

    // The memory-knob support flags follow the archs: the Flash-Next row tunes PLE and
    // sparse-KV, the three A3B rows tune experts, the rest tune nothing.
    let fnK = CatalogModel.memoryKnobs(forID: flashNextID)
    let moeK = CatalogModel.memoryKnobs(forID: moeID)
    let mlxK = CatalogModel.memoryKnobs(forID: "mlx-community/Qwen3.6-35B-A3B-4bit")
    let q2K = CatalogModel.memoryKnobs(forID: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL")
    let denseK = CatalogModel.memoryKnobs(forID: A)
    check("catalog rows carry their memory-knob support",
          fnK.ple && fnK.sparseKv && !fnK.expert
            && moeK.expert && !moeK.ple && !moeK.sparseKv
            && mlxK.expert && q2K.expert
            && !denseK.ple && !denseK.expert && !denseK.sparseKv)

    // O: local models + the saved custom list.
    // The Codable trap on the list, the engine's argv rules for --model-dir/--mmproj/
    // --revision, the ID validator mirroring parse_model_id, the local file validators, and
    // the saved entry behaving like a catalog row for profiles.
    let noSaved = #"{"run":{"port":8123,"modelID":"someone/Model:x"},"sampling":{"temperature":0.4}}"#
    if let nsd = noSaved.data(using: .utf8),
       let nscfg = try? JSONDecoder().decode(AppConfig.self, from: nsd) {
         check("savedModels absent decodes [] without losing the config",
               nscfg.savedModels.isEmpty && nscfg.run.port == 8123 && nscfg.sampling.temperature == 0.4)
    } else {
        check("savedModels absent decodes [] without losing the config", false, "decoder threw")
    }
    let minEntry = #"{"id":"a/b","label":"B"}"#
    if let med = minEntry.data(using: .utf8),
       let ment = try? JSONDecoder().decode(SavedModel.self, from: med) {
        check("SavedModel without path/mmproj decodes defaulted",
              ment.path.isEmpty && ment.mmproj.isEmpty && ment.isLocal == false)
    } else {
        check("SavedModel without path/mmproj decodes defaulted", false, "decoder threw")
    }
    var scfg = AppConfig()
    scfg.savedModels = [SavedModel(id: "someone/Model:x", label: "X"),
                        SavedModel(id: "local/test", label: "test",
                                   path: "/m/test.gguf", mmproj: "/m/mmproj.gguf")]
    if let sd = try? JSONEncoder().encode(scfg),
       let sback = try? JSONDecoder().decode(AppConfig.self, from: sd) {
        check("the saved list round-trips through a save, order kept",
              sback.savedModels.count == 2
                && sback.savedModels[0].id == "someone/Model:x" && !sback.savedModels[0].isLocal
                && sback.savedModels[1].path == "/m/test.gguf" && sback.savedModels[1].isLocal
                && sback.savedModels[1].mmproj == "/m/mmproj.gguf")
    } else {
        check("the saved list round-trips through a save, order kept", false, "encode/decode threw")
    }
    var lrun = RunConfig()
    lrun.modelID = "local/test"
    let localLaunch = SplashServer.LocalLaunch(modelDir: "/m/test.gguf", mmproj: "")
    let largs = SplashServer.buildArguments(for: lrun, local: localLaunch)
    check("--model-dir reaches the engine for a local entry",
          flagValue(largs, "--model-dir") == "/m/test.gguf", largs.joined(separator: " "))
    check("no --model-dir for a Hub entry",
          !SplashServer.buildArguments(for: RunConfig()).contains("--model-dir"))
    let visArgs = SplashServer.buildArguments(
        for: lrun, local: SplashServer.LocalLaunch(modelDir: "/m/t.gguf", mmproj: "/m/mm.gguf"))
    check("the projector passes with vision", flagValue(visArgs, "--mmproj") == "/m/mm.gguf")
    var loRun = lrun
    loRun.languageOnly = true
    let loArgs = SplashServer.buildArguments(
        for: loRun, local: SplashServer.LocalLaunch(modelDir: "/m/t.gguf", mmproj: "/m/mm.gguf"))
    check("the projector never rides with language-only (engine parser rule)",
          !loArgs.contains("--mmproj"), loArgs.joined(separator: " "))
    let revArgs = SplashServer.buildArguments(for: lrun, revision: "deadbeef", local: localLaunch)
    check("revision never accompanies a local entry, and still rides for a Hub one",
          !revArgs.contains("--revision")
            && flagValue(SplashServer.buildArguments(for: RunConfig(), revision: "abc"), "--revision") == "abc",
          revArgs.joined(separator: " "))
    check("the ID validator mirrors parse_model_id",
          SavedModel.validID("local/Quant:Q4") && SavedModel.validID("a/b:C")
            && SavedModel.validID("local/test")
            && !SavedModel.validID("nope") && !SavedModel.validID("a//b")
            && !SavedModel.validID("a b/c") && !SavedModel.validID("local/a..b")
            && !SavedModel.validID("a/b:Q4..X") && !SavedModel.validID("a/b:")
            && !SavedModel.validID("a/b:c:d"))

    // Local file validators and sizes against temp fixtures.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("splashgui-localtest-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: tmp)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let ggufFile = tmp.appendingPathComponent("m.gguf")
    let junkFile = tmp.appendingPathComponent("junk.gguf")
    let projFile = tmp.appendingPathComponent("mmproj.gguf")
    try? Data([UInt8]("GGUF".utf8) + [UInt8](repeating: 0, count: 100)).write(to: ggufFile)
    try? Data([UInt8](repeating: 7, count: 64)).write(to: junkFile)
    try? Data([UInt8]("GGUF".utf8) + [UInt8](repeating: 0, count: 16)).write(to: projFile)
    let mlxDir = tmp.appendingPathComponent("mlx")
    let emptyDir = tmp.appendingPathComponent("empty")
    try? FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    try? Data("{}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
    try? Data([UInt8](repeating: 3, count: 120)).write(to: mlxDir.appendingPathComponent("model.safetensors"))
    let linkFile = tmp.appendingPathComponent("link.gguf")
    try? FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: ggufFile)
    check("the GGUF magic and directory validators read the files like the engine",
          MachineInfo.localLooksLikeModel(path: ggufFile.path)
            && !MachineInfo.localLooksLikeModel(path: junkFile.path)
            && MachineInfo.localLooksLikeModel(path: mlxDir.path)
            && !MachineInfo.localLooksLikeModel(path: emptyDir.path)
            && !MachineInfo.localLooksLikeModel(path: tmp.appendingPathComponent("gone.gguf").path))
    check("local weights size sums the file or the directory's model files",
          MachineInfo.localWeightsSize(path: ggufFile.path) == 104
            && MachineInfo.localWeightsSize(path: mlxDir.path) == 120
            && MachineInfo.localWeightsSize(path: junkFile.path) == 64
            && MachineInfo.localWeightsSize(path: linkFile.path) == 104
            && MachineInfo.localWeightsSize(path: tmp.appendingPathComponent("gone.gguf").path) == nil)
    check("the local start blocker mirrors the engine's refusals",
          AppModel.localStartBlocker(path: tmp.appendingPathComponent("gone.gguf").path,
                                     mmproj: "", languageOnly: false) != nil
            && AppModel.localStartBlocker(path: ggufFile.path, mmproj: projFile.path,
                                          languageOnly: true) != nil
            && AppModel.localStartBlocker(path: ggufFile.path, mmproj: tmp.appendingPathComponent("gone.gguf").path,
                                          languageOnly: false) != nil
            && AppModel.localStartBlocker(path: ggufFile.path, mmproj: projFile.path,
                                          languageOnly: false) == nil
            && AppModel.localStartBlocker(path: ggufFile.path, mmproj: "",
                                          languageOnly: true) == nil)
    try? FileManager.default.removeItem(at: tmp)
    check("the auto local ID follows the sanitized repo shape",
          SavedModel.localID(forPath: "/x/Qwen3.8-27B-UD-IQ3_XXS.gguf") == "local/Qwen3.8-27B-UD:IQ3_XXS"
            && SavedModel.localID(forPath: "/x/model-v2.gguf") == "local/model-v2"
            && SavedModel.localID(forPath: "/x/weird name (v3)!!") == "local/weird-name-v3"
            && SavedModel.validID(SavedModel.localID(forPath: "/x/a..b__c!!.gguf"))
            && SavedModel.validID(SavedModel.localID(forPath: "/x/!!!.gguf")))

    // The saved entry flows through the picker and profiles like a catalog row.
    let S = "someone/My-Qwen3.8-27B-Quant:Q4"
    m.config.savedModels.removeAll()
    m.selectModelID(A)
    check("saveModel refuses an ID the engine would not accept",
          m.saveModel(id: "nope", label: "N") == false && m.config.savedModels.isEmpty)
    m.saveModel(id: S, label: "My Quant")
    m.selectModelID(S)
    check("the picker selection names a saved entry",
          m.modelPickerSelection.wrappedValue == S && m.savedEntry?.label == "My Quant")
    m.config.sampling.temperature = 0.11
    m.selectModelID(A)
    check("a saved entry's profile archives on switch away",
          m.config.modelProfiles[S]?.sampling.temperature == 0.11)
    m.selectModelID(S)
    check("a saved entry restores its profile like a catalog row",
          m.config.sampling.temperature == 0.11, "\(m.config.sampling.temperature)")
    m.saveModel(id: S, label: "Renamed")
    check("saving a duplicate ID updates the entry instead of appending",
          m.config.savedModels.count == 1 && m.config.savedModels.first?.label == "Renamed",
          "\(m.config.savedModels)")
    m.removeSavedModel(id: S)
    check("remove drops the entry but keeps the profile and grantedAuto",
          m.config.savedModels.isEmpty && m.config.modelProfiles[S]?.sampling.temperature == 0.11
            && m.modelPickerSelection.wrappedValue == "custom")
    m.selectModelID(A)

    checkLoggingParses()
    checkLoggingStore()
    checkPerformanceLog()
    checkLoggingPlanning()
    checkLoggingE2E()

    exit(failures == 0 ? 0 : 1)
}

MainActor.assumeIsolated { runTests() }

// MARK: - session logging checks (pure parses, store, planning, live pipe)

func lgWaitUntil(_ seconds: TimeInterval = 4, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if cond() { return true }
        usleep(40_000)
    }
    return cond()
}

func lgRequest(_ url: String, post: String? = nil) -> Int? {
    guard let u = URL(string: url) else { return nil }
    var req = URLRequest(url: u, timeoutInterval: 5)
    if let post {
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(post.utf8)
    }
    let sem = DispatchSemaphore(value: 0)
    var code: Int?
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        code = (resp as? HTTPURLResponse)?.statusCode
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + 6) == .timedOut { return nil }
    return code
}

final class FakeEngine {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake.engine")
    init(port: Int) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { [queue] conn in FakeEngine.serve(conn, on: queue) }
    }
    func start() { listener.start(queue: queue) }
    func stop() { listener.cancel() }

    static func serve(_ conn: NWConnection, on queue: DispatchQueue) {
        conn.start(queue: queue)
        var buf = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, _ in
                if let d { buf.append(d) }
                guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { conn.cancel(); return }
                    read(); return
                }
                let headS = String(decoding: buf[buf.startIndex..<range.lowerBound], as: UTF8.self)
                var cl = 0
                for line in headS.components(separatedBy: "\r\n")
                where line.lowercased().hasPrefix("content-length:") {
                    cl = Int(line.split(separator: ":", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                }
                if buf.count - range.upperBound < cl {
                    if complete { conn.cancel(); return }
                    read(); return
                }
                respond(conn, firstLine: headS.components(separatedBy: "\r\n").first ?? "")
            }
        }
        read()
    }

    static func respond(_ conn: NWConnection, firstLine: String) {
        let out: Data
        if firstLine.contains("/v1/chat/completions") {
            let c1 = "data: " + lgJSON(["choices": [["delta": ["content": "hel"]]]])
            let c2 = "data: " + lgJSON(["choices": [["delta": ["content": "lo", "reasoning_content": "thin",
                "tool_calls": [["index": 0, "id": "c1", "function": ["name": "read", "arguments": "{\"a\""]]]]]]])
            let c3 = "data: " + lgJSON(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": ":1}"]]]],
                "finish_reason": "stop"]], "usage": ["prompt_tokens": 7, "completion_tokens": 3,
                "completion_tokens_details": ["reasoning_tokens": 2], "prompt_tokens_details": ["cached_tokens": 1]]])
            let body = c1 + "\n\n" + c2 + "\n\n" + c3 + "\n\ndata: [DONE]\n\n"
            out = Data(("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n" + body).utf8)
        } else if firstLine.contains("/v1/models") {
            let body = #"{"object":"list","data":[{"id":"m1"}]}"#
            out = Data("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: \(body.count)\r\n\r\n\(body)".utf8)
        } else {
            out = Data("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok".utf8)
        }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// Build fixture JSON via JSONSerialization so hand-counted braces can never silently
// produce a malformed chunk the reassembler rightly refuses.
func lgJSON(_ o: Any) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    return String(decoding: d, as: UTF8.self)
}

func checkLoggingParses() {
    let reqHead = Data("POST /v1/chat/completions HTTP/1.1\r\ncontent-type: application/json\r\nContent-Length: 12\r\nuser-agent: tester\r\n\r\n".utf8)
    let h = HTTPParse.parseHead(reqHead[reqHead.startIndex..<reqHead.endIndex - 2])
    check("request head parses method/path/lowered headers",
          h?.method == "POST" && h?.path == "/v1/chat/completions"
            && h?.headers["content-length"] == "12" && h?.headers["user-agent"] == "tester")
    let resHead = HTTPParse.parseHead(Data("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n".utf8))
    check("response head parses status + content-type",
          resHead?.status == 200 && resHead?.headers["content-type"] == "text/event-stream")
    check("framing: GET none / chunked / content-length", { () -> Bool in
        guard let g = HTTPParse.parseHead(Data("GET /m HTTP/1.1\r\n\r\n".utf8)),
              let c = HTTPParse.parseHead(Data("POST /m HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)),
              let l = HTTPParse.parseHead(Data("POST /m HTTP/1.1\r\ncontent-length: 9\r\n\r\n".utf8))
        else { return false }
        if case .none = HTTPParse.bodyFraming(head: g),
           case .chunked = HTTPParse.bodyFraming(head: c),
           case .length(9) = HTTPParse.bodyFraming(head: l) { return true }
        return false
    }())

    let dec = HTTPParse.ChunkedDecoder()
    var body = Data()
    body.append(dec.feed(Data("5\r\nhel".utf8)))
    body.append(dec.feed(Data("lo\r\n16;ext=1\r\n01234567890123456789".utf8)))   // 0x16 = 22
    body.append(dec.feed(Data("01\r\n0\r\n\r\n".utf8)))
    check("chunked decoder: hex sizes, extensions, split feeds",
          body == Data("hello0123456789012345678901".utf8) && dec.isComplete, "\(body.count)")

    let summary = HTTPParse.summarizeRequest(Data(#"{"model":"test-model","stream":true,"messages":[{"role":"system","content":"sys"},{"role":"user","content":"hi"}],"tools":[{"function":{"name":"read"}}]}"#.utf8))
    check("request summary pulls model/stream/system/tools",
          summary.model == "test-model" && summary.stream
            && summary.systemChars == 3 && summary.toolNames == ["read"])

    let sse = SSEReassembler()
    let d1 = lgJSON(["choices": [["delta": ["content": "a"]]]])
    let d2 = lgJSON(["choices": [["delta": ["content": "b", "tool_calls": [["index": 0, "id": "c1", "function": ["name": "read", "arguments": "{\"a\""]]]]]]])
    let d3 = lgJSON(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": ":1}"]]]], "finish_reason": "stop"]], "usage": ["prompt_tokens": 7, "completion_tokens": 3]])
    sse.feed(Data("event: x\ndata: \(d1)\n\ndata: \(d2)\n\ndata: \(d3)\n\ndata: [DONE]\n\n".utf8))
    let r = sse.result()
    check("SSE reassembly joins split deltas and tool-call fragments",
          r.text == "ab" && r.finish == "stop" && r.sawDone
            && r.toolCalls.count == 1 && r.toolCalls.first?.argumentsJSON == "{\"a\":1}"
            && r.usage?.input == 7 && r.usage?.output == 3, "\(r.text) \(r.toolCalls)")

    let resp = SSEReassembler()
    let r1 = lgJSON(["type": "response.output_text.delta", "delta": "hey"])
    let r2 = lgJSON(["type": "response.function_call_arguments.delta", "item_id": "fc1", "delta": "{\"x\":1}"])
    let r3 = lgJSON(["type": "response.completed", "response": ["status": "completed", "usage": ["input_tokens": 5, "output_tokens": 2]]])
    resp.feed(Data("data: \(r1)\n\ndata: \(r2)\n\ndata: \(r3)\n\n".utf8))
    let rr = resp.result()
    check("Responses-API events fold into the same record",
          rr.text == "hey" && rr.finish == "completed"
            && rr.toolCalls.first?.argumentsJSON == "{\"x\":1}" && rr.usage?.input == 5)

    let chat = HTTPParseTee.parseJSONBody(Data(#"{"choices":[{"message":{"content":"hi","tool_calls":[{"id":"t","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":2}}"#.utf8))
    check("non-streaming chat body parses",
          chat.parsed && chat.text == "hi" && chat.finish == "tool_calls"
            && chat.toolCalls?.first?.name == "f" && chat.usage?.output == 2)
    let respObj = HTTPParseTee.parseJSONBody(Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"yo"}]},{"type":"function_call","call_id":"c","name":"g","arguments":"{}"}],"usage":{"input_tokens":3,"output_tokens":4}}"#.utf8))
    check("Responses object body parses",
          respObj.parsed && respObj.text == "yo" && respObj.toolCalls?.first?.name == "g"
            && respObj.usage?.input == 3)
    check("unknown JSON shape keeps parsed=false",
          HTTPParseTee.parseJSONBody(Data(#"{"ok":true}"#.utf8)).parsed == false)
}

func checkLoggingStore() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("splash-log-\(UUID().uuidString)", isDirectory: true)
    var rec = SessionRecord(tsStart: Date(), clientHint: "ua", clientLoopback: true, path: "/v1/chat/completions")
    rec.model = "m"; rec.requestJSON = #"{"model":"m"}"#
    rec.responseText = "hi"; rec.parsed = true
    let line = SessionLog.encodeLine(rec)
    check("record round-trips through JSONL",
          line != nil && SessionLog.decodeLine(line!)?.model == "m"
            && SessionLog.decodeLine(line!)?.responseText == "hi")
    check("day file name is YYYY-MM-DD.jsonl",
          SessionLog.dayFileName(Date()).count == 16
            && SessionLog.dayFileName(Date()).hasSuffix(".jsonl"))

    let log = SessionLog(dir: tmp)
    log.write(rec)
    var old = SessionRecord(tsStart: Date().addingTimeInterval(-100 * 86400), path: "/v1/old")
    old.model = "old"
    log.write(old)
    check("both day files land and tail reads the newest",
          lgWaitUntil(4) { (try? FileManager.default.contentsOfDirectory(atPath: tmp.path).count) == 2 }
            && SessionLog.tail(dir: tmp, limit: 5).first?.path == "/v1/chat/completions")
    let removed = SessionLog.purge(dir: tmp, retentionDays: 90, now: Date())
    let stats = SessionLog.stats(dir: tmp, now: Date())
    check("retention purges only out-of-window day files",
          removed.count == 1 && stats.fileCount == 1 && stats.sessionsToday == 1
            && stats.totalBytes > 0, "\(removed) \(stats.sessionsToday)")
    try? FileManager.default.removeItem(at: tmp)
}

func checkPerformanceLog() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("splash-perf-\(UUID().uuidString)", isDirectory: true)
    var s = PerformanceSample(ts: Date())
    s.model = "someone/Model:x"; s.engine = "1.6.1"; s.stage = "decode"
    s.ttftP50 = 120; s.ttftP95 = 300; s.itlP50 = 18; s.itlP95 = 40
    s.decodeTps = 42.5; s.prefillTps = 900; s.draftAcceptance = 0.72
    s.cacheHitRate = 0.5; s.reusedTokens = 1234; s.cacheLookups = 9
    s.queued = 0; s.prefilling = 0; s.decoding = 1
    s.kvPagesActive = 12; s.kvBlockTokens = 256; s.hardBudgetBytes = 40_000_000_000
    s.contextTokens = 65_536; s.physicalRAM = 64_000_000_000
    s.metalMaxWorkingSet = 48_000_000_000
    let line = PerformanceLog.encodeLine(s)
    check("performance sample round-trips through JSONL",
          line != nil && PerformanceLog.decodeLine(line!)?.decodeTps == 42.5
            && PerformanceLog.decodeLine(line!)?.stage == "decode")
    check("performance sampling follows the tick interval",
          PerformanceLog.shouldSample(tick: 1, interval: 1)
            && !PerformanceLog.shouldSample(tick: 4, interval: 5)
            && PerformanceLog.shouldSample(tick: 5, interval: 5)
            && PerformanceLog.shouldSample(tick: 10, interval: 10)
            && PerformanceLog.shouldSample(tick: 3, interval: 0))
    let log = PerformanceLog(dir: tmp)
    log.write(s)
    var idle = PerformanceSample(ts: Date().addingTimeInterval(1))
    idle.model = "someone/Model:x"; idle.stage = nil
    log.write(idle)
    check("performance day file lands and stats count it",
          lgWaitUntil(4) { PerformanceLog.stats(dir: tmp).samplesToday == 2 }
            && PerformanceLog.stats(dir: tmp).fileCount == 1)
    let csv = PerformanceLog.csv(dir: tmp)
    let rows = csv.split(separator: "\n")
    check("performance CSV has a stable header and one row per sample",
          rows.count == 3 && rows[0].hasPrefix("timestamp,model,engine,stage")
            && rows[1].contains("42.5") && rows[1].contains("decode")
            && rows[2].contains("someone/Model:x"))
    try? FileManager.default.removeItem(at: tmp)
}

func checkLoggingPlanning() {
    let p = AppModel.frontingPlan(enabled: true, adopted: false, pickedInternalPort: 8199)
    check("fronting only when enabled, app-launched and a port was picked",
          p.front && p.enginePort == 8199
            && AppModel.frontingPlan(enabled: true, adopted: true, pickedInternalPort: 8199).front == false
            && AppModel.frontingPlan(enabled: false, adopted: false, pickedInternalPort: 8199).front == false
            && AppModel.frontingPlan(enabled: true, adopted: false, pickedInternalPort: nil).front == false)
    let pol = SessionProxy.Policy(logLocal: true, logLAN: false)
    check("LAN clients pipe but are not recorded by default",
          SessionProxy.shouldRecord(policy: pol, loopbackPeer: true)
            && !SessionProxy.shouldRecord(policy: pol, loopbackPeer: false)
            && SessionProxy.shouldRecord(policy: .init(logLocal: true, logLAN: true), loopbackPeer: false))
    check("loopback peer detection covers IPv4, IPv6 and localhost",
          SessionProxy.isLoopbackEndpoint(.hostPort(host: "127.0.0.1", port: 1))
            && SessionProxy.isLoopbackEndpoint(.hostPort(host: "::1", port: 1))
            && SessionProxy.isLoopbackEndpoint(.hostPort(host: "localhost", port: 1))
            && !SessionProxy.isLoopbackEndpoint(.hostPort(host: "10.0.0.5", port: 1)))

    let occupied = (41000 + Int.random(in: 0..<9000))
    if SessionProxy.isPortFree(occupied) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(occupied).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound == 0 {
            let picked = SessionProxy.pickInternalPort(publicPort: occupied - 1)
            check("internal port pick skips occupied ports",
                  picked != occupied - 1 && picked != occupied && picked != nil
                    && (picked ?? 0) > occupied - 1, "\(picked ?? -1)")
        } else {
            check("internal port pick skips occupied ports", true, "bind raced, skipped")
        }
        close(fd)
    } else {
        check("internal port pick skips occupied ports", true, "port raced, skipped")
    }
}

func checkLoggingE2E() {
    guard let pub = SessionProxy.pickInternalPort(publicPort: 40000 + Int.random(in: 0..<1000)),
          let internalPort = SessionProxy.pickInternalPort(publicPort: pub) else {
        check("E2E proxy pipe", false, "no free test ports"); return
    }
    let engine = try? FakeEngine(port: internalPort)
    engine?.start()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("splash-e2e-\(UUID().uuidString)", isDirectory: true)
    let log = SessionLog(dir: tmp)
    guard let proxy = try? SessionProxy(publicPort: pub, internalPort: internalPort,
                                        lanBind: false,
                                        policy: .init(logLocal: true, logLAN: false), log: log)
    else {
        check("E2E proxy pipe", false, "proxy init failed"); return
    }
    proxy.start()
    _ = lgWaitUntil(3) { lgRequest("http://127.0.0.1:\(pub)/status") == 200 }

    check("proxy forwards non-/v1 traffic unlogged", {
        usleep(300_000)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        let lines = files.flatMap { name -> [Substring] in
            guard let d = try? Data(contentsOf: tmp.appendingPathComponent(name)),
                  let s = String(data: d, encoding: .utf8) else { return [] }
            return s.split(separator: "\n")
        }
        return lines.isEmpty
    }())

    let chatBody = #"{"model":"test-model","stream":true,"messages":[{"role":"system","content":"sys prompt"},{"role":"user","content":"hi"}]}"#
    let code = lgRequest("http://127.0.0.1:\(pub)/v1/chat/completions", post: chatBody)
    let gotRecord = lgWaitUntil(5) { SessionLog.tail(dir: tmp, limit: 10).count >= 1 }
    check("chat through the proxy returns 200 and records one turn",
          code == 200 && gotRecord, "code \(code ?? -1)")
    let rec = SessionLog.tail(dir: tmp, limit: 1).first
    check("record holds the full request and the reassembled SSE reply",
          rec?.model == "test-model" && rec?.stream == true
            && rec?.requestJSON?.contains("sys prompt") == true
            && rec?.systemChars == 10
            && rec?.responseText == "hello" && rec?.responseReasoning == "thin"
            && rec?.toolCalls?.first?.argumentsJSON == "{\"a\":1}"
            && rec?.finishReason == "stop" && rec?.status == 200
            && rec?.usage?.input == 7 && rec?.usage?.reasoning == 2 && rec?.usage?.cached == 1,
          "\(rec?.responseText ?? "nil") \(rec?.error ?? "ok")")

    if let lan = MachineInfo.lanIPv4Address,
       let pub2 = SessionProxy.pickInternalPort(publicPort: pub + 100),
       let proxy2 = try? SessionProxy(publicPort: pub2, internalPort: internalPort,
                                      lanBind: true, policy: .init(logLocal: true, logLAN: false),
                                      log: log) {
        proxy2.start()
        let lanCode = lgWaitUntil(3) { lgRequest("http://\(lan):\(pub2)/v1/models") == 200 }
        usleep(400_000)
        let stillOne = SessionLog.tail(dir: tmp, limit: 10).count == 1
        proxy2.stop()
        check("a LAN-facing bind serves remote-IP clients without recording them (LAN off)",
              lanCode && stillOne)
    } else {
        check("a LAN-facing bind serves remote-IP clients without recording them (LAN off)",
              true, "no LAN IPv4 leased, skipped")
    }

    proxy.stop()
    engine?.stop()
    try? FileManager.default.removeItem(at: tmp)
}

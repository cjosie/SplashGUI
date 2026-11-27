import Foundation

struct StatusSnapshot {
    let raw: [String: Any]

    subscript(_ path: [String]) -> Any? {
        var current: Any? = raw
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    private func num(_ path: [String]) -> Double? {
        guard let v = self[path] else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func number(_ path: String...) -> Double? {
        num(path)
    }

    func string(_ path: String...) -> String? {
        guard let v = self[path] else { return nil }
        return v as? String
    }

    func int(_ path: String...) -> Int? {
        num(path).map { Int($0) }
    }

    var instanceModel: String? { string("instance", "model") }
    var instancePID: Int? { int("instance", "pid") }
    var maxContextTokens: Int? {
        int("maximum_context_tokens") ?? int("native", "maximum_context_tokens")
    }
    // The memory budget Splash actually charged itself (== the --max-memory it was given, or
    // its own ceiling when the flag was omitted). Verified live on 1.3.2, spec §8.1; the 1.5.0
    // backend status still emits it (frontend.status() passes backend.status() through).
    var hardBudgetBytes: Int? { int("memory_plan", "budget", "hard_budget_bytes") }
    var ttftP50: Double? { number("metrics", "ttft_ms", "p50") }
    var ttftP95: Double? { number("metrics", "ttft_ms", "p95") }
    var itlP50: Double? { number("metrics", "itl_ms", "p50") }
    var itlP95: Double? { number("metrics", "itl_ms", "p95") }
    var cacheHitRate: Double? { number("cache", "hit_rate") }
    // Schema 8 (engine 1.6.0) renamed the lookup counter to probe_hashed_blocks; the old
    // path stays as the fallback for engines that still emit it.
    var cacheLookups: Int? { int("cache", "probe_hashed_blocks") ?? int("cache", "lookups") }
    var reusedTokens: Int? { int("cache", "reused_tokens") }
    var kvPagesActive: Int? { int("kv", "pages_active") }
    var kvBlockTokens: Int? { int("kv", "block_tokens") }
    // What the running server accepts: ["text"] or ["text","image","pdf"].
    var inputModalities: [String]? { self[["input_modalities"]] as? [String] }
    // Whether every chat template renders a later system message in place. The engine's Pi
    // connector advertises this as compat.supportsMidConvoSystemMessages; /status reports
    // "native"/"patched" per template (or one string when there is a single template).
    var rendersLaterSystem: Bool? {
        guard let t = self[["chat_template", "later_system"]] else { return nil }
        if let s = t as? String { return s == "native" || s == "patched" }
        if let d = t as? [String: Any] {
            return !d.isEmpty && d.values.allSatisfy {
                guard let s = $0 as? String else { return false }
                return s == "native" || s == "patched"
            }
        }
        return nil
    }

    // Live fraction of the granted context window occupied by active requests' KV:
    // resident tokens (active pages x tokens-per-page) over the ceiling. Server-wide, so it
    // reflects every client (web chat included), not just app-run requests.
    var contextUsedFraction: Double? {
        guard let active = kvPagesActive, let block = kvBlockTokens, block > 0,
              let max = maxContextTokens, max > 0 else { return nil }
        return min(1.0, Double(active * block) / Double(max))
    }
    // Raw tokens held by active requests' KV (pages × tokens-per-page); the toolbar caption
    // shows this over the granted window, the bar shows the fraction.
    var contextUsedTokens: Int? {
        guard let active = kvPagesActive, let block = kvBlockTokens else { return nil }
        return active * block
    }
    var kvResidentBytes: Int? { int("kv", "resident_backing_bytes") }
    var queued: Int? { int("scheduler", "queued") }
    var prefilling: Int? { int("scheduler", "prefilling") }
    var decoding: Int? { int("scheduler", "decoding") }

    // memory_actual — engine-side allocated/current/peak.
    var memActualAllocated: Int? { int("memory_actual", "allocated_bytes") }
    var memActualCurrent: Int? { int("memory_actual", "current_bytes") }
    var memActualPeak: Int? { int("memory_actual", "peak_bytes") }

    // memory_governor — charged vs the hard budget, plus backpressure state.
    var govLimit: Int? { int("memory_governor", "limit_bytes") }
    var govCharged: Int? { int("memory_governor", "charged_bytes") }
    var govHeadroom: Int? { int("memory_governor", "headroom_bytes") }
    var govGrowthAllowed: Bool? { self[["memory_governor", "growth_allowed"]] as? Bool }
    var govDeniedReservations: Int? { int("memory_governor", "denied_reservations") }
    var govSystemPressure: String? { string("memory_governor", "system_pressure") }

    // The engine's per-account budget usage — the chunks the Splash budget bar segments by.
    struct GovernorAccount {
        let name: String
        let currentBytes: Int
    }
    var govAccounts: [GovernorAccount] {
        guard let list = self[["memory_governor", "accounts"]] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let bytes: Int?
            if let d = entry["current_bytes"] as? Double { bytes = Int(d) }
            else if let i = entry["current_bytes"] as? Int { bytes = Int(i) }
            else { bytes = nil }
            guard let b = bytes else { return nil }
            return GovernorAccount(name: name, currentBytes: b)
        }
    }

    // kv_spill is null when nothing is spilled; expose the raw value so a future fill shows.
    var kvSpill: String? {
        guard let v = self[["memory_plan", "budget", "kv_spill"]] else { return nil }
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return String(Int(d)) }
        return nil
    }

    // Disk (SSD tier).
    var diskUsed: Int? { int("disk", "used_bytes") }
    var diskLimit: Int? { int("disk", "limit_bytes") }
    var diskWrittenLastHour: Int? { int("disk", "written_last_hour_bytes") }
    var diskPersistent: Bool? { self[["disk", "persistent"]] as? Bool }

}

final class SplashClient {
    let port: Int

    init(port: Int) { self.port = port }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func ready() async -> Bool {
        guard let url = URL(string: "\(baseURL)/ready") else { return false }
        let req = URLRequest(url: url, timeoutInterval: 3)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse { return http.statusCode == 200 }
            return false
        } catch {
            return false
        }
    }

    func fetchStatus() async -> StatusSnapshot? {
        guard let url = URL(string: "\(baseURL)/status") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 5)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return StatusSnapshot(raw: dict)
        } catch {
            return nil
        }
    }

    func fetchMetric(_ name: String) async -> Double? {
        guard let url = URL(string: "\(baseURL)/metrics") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 5)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                if line.hasPrefix(name + " ") || line.hasPrefix(name + "{") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2, let v = Double(parts.last!) { return v }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func probePort() async -> (open: Bool, pid: Int?, detail: String?) {
        let lockPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Splash/runtime/serve-\(port).lock")
        if let data = try? Data(contentsOf: lockPath),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = dict["pid"] as? Int {
            let model = dict["model"] as? String ?? "?"
            let running = kill(Int32(pid), 0) == 0
            if running { return (true, pid, "a Splash server for \(model)") }
        }
        guard let url = URL(string: "\(baseURL)/health") else { return (false, nil, nil) }
        let req = URLRequest(url: url, timeoutInterval: 2)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return (true, nil, "something responding on port \(port)")
            }
        } catch {}
        return (false, nil, nil)
    }
}
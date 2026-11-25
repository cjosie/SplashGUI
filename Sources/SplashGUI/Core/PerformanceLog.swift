import Foundation

// One /status sample, as the Status tab already reads it. Written to JSONL day files so a
// throughput report can be built without eyeballing the page. Every field is optional except
// the timestamp: an idle sample still records the scheduler and memory, with no rates.
nonisolated struct PerformanceSample: Codable {
    var ts: Date
    var model: String? = nil
    var engine: String? = nil
    var stage: String? = nil        // "prefill" | "decode" | nil (idle)
    var ttftP50: Double? = nil
    var ttftP95: Double? = nil
    var itlP50: Double? = nil
    var itlP95: Double? = nil
    var decodeTps: Double? = nil
    var prefillTps: Double? = nil
    var draftAcceptance: Double? = nil
    var cacheHitRate: Double? = nil
    var reusedTokens: Int? = nil
    var cacheLookups: Int? = nil
    var queued: Int? = nil
    var prefilling: Int? = nil
    var decoding: Int? = nil
    var kvPagesActive: Int? = nil
    var kvBlockTokens: Int? = nil
    var hardBudgetBytes: Int? = nil
    var contextTokens: Int? = nil
    var physicalRAM: Int? = nil
    var metalMaxWorkingSet: Int? = nil
}

// JSONL performance store: logs/performance/YYYY-MM-DD.jsonl under the app data dir. The
// sampler rides the existing /status poll, so enabling it adds no requests to the engine.
final class PerformanceLog: @unchecked Sendable {
    let dir: URL
    private let queue = DispatchQueue(label: "splashgui.performancelog")
    var lastWriteError: String?

    init(dir: URL? = nil) {
        self.dir = dir ?? AppPaths.dataDir.appendingPathComponent("logs/performance", isDirectory: true)
    }

    nonisolated static func encodeLine(_ sample: PerformanceSample) -> String? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(sample) else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    nonisolated static func decodeLine(_ line: String) -> PerformanceSample? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(PerformanceSample.self, from: Data(line.utf8))
    }

    // The poll runs once a second; sample on every Nth tick. A zero/negative interval is
    // treated as every tick rather than dividing by zero.
    nonisolated static func shouldSample(tick: Int, interval: Int) -> Bool {
        interval <= 1 || tick % interval == 0
    }

    func write(_ sample: PerformanceSample) {
        guard let line = Self.encodeLine(sample) else {
            lastWriteError = "encode failed"
            return
        }
        queue.async {
            do {
                try JSONLStore(dir: self.dir).appendLine(line, ts: sample.ts)
                self.lastWriteError = nil
            } catch {
                self.lastWriteError = "\(error)"
            }
        }
    }

    struct Stats { var samplesToday = 0; var totalBytes = 0; var fileCount = 0 }

    static func stats(dir: URL, now: Date = Date()) -> Stats {
        let (today, totalBytes, fileCount) = JSONLStore(dir: dir).stats(now: now)
        var s = Stats()
        s.samplesToday = today
        s.totalBytes = totalBytes
        s.fileCount = fileCount
        return s
    }

    // Every retained sample as CSV, oldest first. The header is stable so a community report
    // can paste the file straight into a spreadsheet.
    static func csv(dir: URL) -> String {
        let header = [
            "timestamp", "model", "engine", "stage",
            "ttft_p50_ms", "ttft_p95_ms", "itl_p50_ms", "itl_p95_ms",
            "decode_tps", "prefill_tps", "draft_acceptance", "cache_hit_rate",
            "reused_tokens", "cache_lookups", "queued", "prefilling", "decoding",
            "kv_pages_active", "kv_block_tokens", "hard_budget_bytes", "context_tokens",
            "physical_ram_bytes", "metal_max_working_set_bytes",
        ].joined(separator: ",")
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".jsonl") } ?? []).sorted()
        var samples: [PerformanceSample] = []
        for n in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(n)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            samples += text.split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { decodeLine(String($0)) }
        }
        samples.sort { $0.ts < $1.ts }
        let iso = ISO8601DateFormatter()
        func cell(_ s: String?) -> String {
            guard let s else { return "" }
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        func num(_ v: Double?) -> String { v.map { String($0) } ?? "" }
        func int(_ v: Int?) -> String { v.map { String($0) } ?? "" }
        let rows = samples.map { s in
            [
                iso.string(from: s.ts), cell(s.model), cell(s.engine), cell(s.stage),
                num(s.ttftP50), num(s.ttftP95), num(s.itlP50), num(s.itlP95),
                num(s.decodeTps), num(s.prefillTps), num(s.draftAcceptance), num(s.cacheHitRate),
                int(s.reusedTokens), int(s.cacheLookups), int(s.queued), int(s.prefilling),
                int(s.decoding), int(s.kvPagesActive), int(s.kvBlockTokens),
                int(s.hardBudgetBytes), int(s.contextTokens), int(s.physicalRAM),
                int(s.metalMaxWorkingSet),
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}

import Foundation

// One proxied /v1 request, end to end, as written to the session log. Full fidelity is
// the point (the quant corpus wants whole prompts): requestJSON keeps the body verbatim,
// and the parsed fields beside it are conveniences for the tail view and future export.
// Unknown response shapes still record: parsed=false plus rawResponse verbatim.
nonisolated struct SessionRecord: Codable {
    nonisolated struct ToolCall: Codable, Equatable {
        var id: String?
        var name: String?
        var argumentsJSON: String?
    }
    nonisolated struct Usage: Codable, Equatable {
        var input: Int?
        var output: Int?
        var reasoning: Int?
        var cached: Int?
    }

    var tsStart: Date
    var tsEnd: Date?
    var durationMs: Int?
    var clientHint: String?          // User-Agent
    var clientLoopback: Bool?        // loopback peer = "this machine's own client"
    var path: String
    var model: String?
    var stream: Bool?
    var systemChars: Int?
    var toolNames: [String]?
    var requestJSON: String?         // full body, verbatim UTF-8 when decodable
    var responseText: String?
    var responseReasoning: String?
    var toolCalls: [ToolCall]?
    var finishReason: String?
    var usage: Usage?
    var status: Int?
    var parsed: Bool?                // false = unknown shape; rawResponse holds the body
    var rawResponse: String?
    var error: String?               // client-abort | upstream-error | malformed | nil
}

// JSONL session store: logs/sessions/YYYY-MM-DD.jsonl under the app data dir, written
// from the proxy queue, purged by day-file name, tailed by the Logging tab.
final class SessionLog: @unchecked Sendable {
    let dir: URL
    private let queue = DispatchQueue(label: "splashgui.sessionlog")
    private let iso = ISO8601DateFormatter()
    var lastWriteError: String?

    init(dir: URL? = nil) {
        self.dir = dir ?? AppPaths.dataDir.appendingPathComponent("logs/sessions", isDirectory: true)
    }

    nonisolated static func dayFileName(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian)
        let d = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", d.year ?? 1970, d.month ?? 1, d.day ?? 1)
    }

    // One JSON object per line; Dates ride as ISO-8601 strings so jq/python read them.
    nonisolated static func encodeLine(_ record: SessionRecord) -> String? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(record) else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    nonisolated static func decodeLine(_ line: String) -> SessionRecord? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(SessionRecord.self, from: Data(line.utf8))
    }

    func write(_ record: SessionRecord) {
        guard let line = Self.encodeLine(record) else {
            lastWriteError = "encode failed"
            return
        }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
                let url = self.dir.appendingPathComponent(Self.dayFileName(record.tsStart))
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                self.lastWriteError = nil
            } catch {
                // Logging must never break forwarding; the failure is surfaced in the tab.
                self.lastWriteError = "\(error)"
            }
        }
    }

    // Purge day-files older than the cutoff. Files that don't parse as a date are left
    // alone — never delete what we can't name.
    @discardableResult
    static func purge(dir: URL, retentionDays: Int, now: Date = Date()) -> [String] {
        guard retentionDays > 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let cutoffDay = dayFileName(Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -retentionDays, to: now) ?? now)
        var removed: [String] = []
        for n in names where n.hasSuffix(".jsonl") {
            let day = String(n.dropLast(".jsonl".count))
            let c = Array(day)
            guard c.count == 10, c[4] == "-", c[7] == "-",
                  [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ c[$0].isNumber }),
                  day < cutoffDay else { continue }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            removed.append(n)
        }
        return removed
    }

    // Newest-last: the tail of today's file (falling back to the newest file present).
    static func tail(dir: URL, limit: Int, now: Date = Date()) -> [SessionRecord] {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(dayFileName(now))
        if !fm.fileExists(atPath: url.path) {
            guard let names = (try? fm.contentsOfDirectory(atPath: dir.path))?
                    .filter({ $0.hasSuffix(".jsonl") }).sorted(),
                  let last = names.last else { return [] }
            url = dir.appendingPathComponent(last)
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(limit).reversed().compactMap { decodeLine(String($0)) }
    }

    struct Stats { var sessionsToday = 0; var totalBytes = 0; var fileCount = 0 }

    static func stats(dir: URL, now: Date = Date()) -> Stats {
        let fm = FileManager.default
        var s = Stats()
        guard let names = (try? fm.contentsOfDirectory(atPath: dir.path))?
                .filter({ $0.hasSuffix(".jsonl") }).sorted() else { return s }
        s.fileCount = names.count
        for n in names {
            let u = dir.appendingPathComponent(n)
            s.totalBytes += (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if n == dayFileName(now), let data = try? Data(contentsOf: u) {
                s.sessionsToday = data.filter { $0 == UInt8(ascii: "\n") }.count
            }
        }
        return s
    }
}

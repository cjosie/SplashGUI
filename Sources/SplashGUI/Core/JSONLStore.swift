import Foundation

// The shared file machinery behind the session and performance JSONL stores: day-file naming,
// appending a line, purge-by-age and per-directory stats. The two logs keep their own record
// types and (de)serializers; this file owns the file-shape rules.
nonisolated struct JSONLStore {
    let dir: URL

    init(dir: URL) { self.dir = dir }

    static func dayFileName(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian)
        let d = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", d.year ?? 1970, d.month ?? 1, d.day ?? 1)
    }

    // One JSON object per line; the caller owns the line's shape.
    func appendLine(_ line: String, ts: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.dayFileName(ts))
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
    }

    // Purge day-files older than the cutoff. Files that don't parse as a date are left
    // alone — never delete what we can't name.
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

    func stats(now: Date = Date()) -> (today: Int, totalBytes: Int, fileCount: Int) {
        let fm = FileManager.default
        guard let names = (try? fm.contentsOfDirectory(atPath: dir.path))?
                .filter({ $0.hasSuffix(".jsonl") }).sorted() else { return (0, 0, 0) }
        let todayName = Self.dayFileName(now)
        var today = 0
        var totalBytes = 0
        for n in names {
            let u = dir.appendingPathComponent(n)
            totalBytes += (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if n == todayName, let data = try? Data(contentsOf: u) {
                today = data.filter { $0 == UInt8(ascii: "\n") }.count
            }
        }
        return (today, totalBytes, names.count)
    }
}

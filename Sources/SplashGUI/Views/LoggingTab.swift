import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Session logging controls and the live tail. Logging is opt-in and full-fidelity: whole
// prompts, replies, reasoning and tool calls as JSONL, with day-file retention as the only
// cap. The proxy fronts the public port, so client configs never change.
struct LoggingTab: View {
    @EnvironmentObject var model: AppModel
    @State private var stats = SessionLog.Stats()
    @State private var perfStats = PerformanceLog.Stats()
    @State private var tail: [SessionRecord] = []

    var body: some View {
        SettingsPage {
            SettingsSection("Session logging") {
                Toggle("Log /v1 sessions through the app proxy", isOn: $model.config.loggingEnabled)
                if model.phase != .stopped && model.launchedLoggingEnabled != model.config.loggingEnabled {
                    Label("Applies on the next Start (the proxy binds when the serve launches).",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()
                Toggle("Also record LAN clients", isOn: $model.config.loggingLanClients)
                    .disabled(!model.config.run.lanAccess)
                    .help("Takes effect immediately while the proxy is running. Off keeps LAN clients working through the proxy but unrecorded.")
                if model.config.run.lanAccess && model.config.loggingEnabled {
                    Label(model.config.loggingLanClients
                          ? "LAN clients are recorded: machines on your network have their turns logged too."
                          : "LAN clients keep working through the proxy but are NOT recorded; loopback clients are.",
                          systemImage: model.config.loggingLanClients ? "exclamationmark.triangle" : "lock.shield")
                        .font(.callout)
                        .foregroundStyle(model.config.loggingLanClients ? .orange : .secondary)
                }
            }
            SettingsSection("Storage") {
                Picker("Keep logs for", selection: $model.config.loggingRetentionDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .frame(maxWidth: 240, alignment: .leading)
                HStack(spacing: 16) {
                    Text("\(String(stats.sessionsToday)) sessions today · \(MachineInfo.bytesText(stats.totalBytes)) in \(String(stats.fileCount)) file(s)")
                    Button("Open log folder") { NSWorkspace.shared.open(model.sessionLog.dir) }
                    Button("Refresh") { load() }
                }
                .font(.callout)
                if let err = model.sessionLog.lastWriteError {
                    Label("Log write problem: \(err)", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(verbatim: "Full prompts, replies, reasoning and tool calls, one JSON object per request at \(model.sessionLog.dir.path). Point clients at http://127.0.0.1:\(model.config.run.port)/v1 as always; while logging is on, the app sits between them and the engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("Performance") {
                Toggle("Log performance samples", isOn: $model.config.performanceLoggingEnabled)
                    .help("Writes the same /status numbers the Status tab shows — TTFT, prefill/decode tok/s, draft acceptance, cache hit, scheduler and memory — to a JSONL day file while the server is prefilling or generating. It rides the existing status poll, so it adds no requests to the engine.")
                HStack(spacing: 6) {
                    Text("Sample every")
                        .fixedSize(horizontal: true, vertical: false)
                    Picker("Sample every", selection: $model.config.performanceLogInterval) {
                        Text("1 second").tag(1)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!model.config.performanceLoggingEnabled)
                    Spacer()
                }
                HStack(spacing: 16) {
                    Text("\(String(perfStats.samplesToday)) samples today · \(MachineInfo.bytesText(perfStats.totalBytes)) in \(String(perfStats.fileCount)) file(s)")
                    Button("Open folder") { NSWorkspace.shared.open(model.performanceLog.dir) }
                    Button("Export CSV…") { exportPerformanceCSV() }
                    Button("Refresh") { load() }
                }
                .font(.callout)
                if let err = model.performanceLog.lastWriteError {
                    Label("Performance log write problem: \(err)", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("One JSON object per sample at \(model.performanceLog.dir.path), written while the server is prefilling or generating (idle periods are gaps). Retention follows the Storage setting above. Export CSV writes every retained sample, oldest first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("Recent sessions") {
                if tail.isEmpty {
                    Text("Nothing logged yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(tail.enumerated()), id: \.offset) { _, r in
                    SessionRow(record: r)
                }
            }
        }
        .onAppear { load() }
    }

    private var statusLine: String {
        if let internalPort = model.frontedEnginePort {
            return "Running: proxy :\(model.config.run.port) → engine :\(internalPort)"
        }
        if model.phase == .ready, model.launchedLoggingEnabled {
            return "Serving directly (logging could not front the port; see the Run log)."
        }
        return model.config.loggingEnabled
            ? "Armed: the next Start runs the serve behind the proxy."
            : "Off: the serve runs directly on port \(model.config.run.port)."
    }

    private func load() {
        let log = model.sessionLog
        let perf = model.performanceLog
        Task.detached(priority: .utility) {
            let s = SessionLog.stats(dir: log.dir)
            let t = SessionLog.tail(dir: log.dir, limit: 20)
            let ps = PerformanceLog.stats(dir: perf.dir)
            await MainActor.run {
                stats = s
                tail = t
                perfStats = ps
            }
        }
    }

    private func exportPerformanceCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "splash-performance-\(Self.dayStamp()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let csv = PerformanceLog.csv(dir: model.performanceLog.dir)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// One collapsed line per record; expanded shows the full JSON of the turn.
private struct SessionRow: View {
    let record: SessionRecord
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(prettyJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 10) {
                Text(time).font(.caption.monospaced())
                Text(record.model ?? "?").font(.caption).lineLimit(1)
                Spacer()
                if let e = record.error {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                if let u = record.usage {
                    Text("\(String(u.input ?? 0))→\(String(u.output ?? 0))t").font(.caption).foregroundStyle(.secondary)
                }
                Text(record.finishReason ?? (record.status.map { "\($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var time: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: record.tsStart)
    }

    private var prettyJSON: String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? e.encode(record) else { return "(encode failed)" }
        let s = String(decoding: d, as: UTF8.self)
        // A 128K-context prompt is a wall of text; the row shows the head, the file has all.
        return s.count > 20_000 ? s.prefix(20_000) + "\n… truncated view (the log file keeps the full record)" : s
    }
}

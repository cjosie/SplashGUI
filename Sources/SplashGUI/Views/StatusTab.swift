import SwiftUI

struct StatusTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.phase == .ready, let snap = model.status {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    memorySection(snap)
                    HStack(alignment: .top, spacing: 10) {
                        Card("TTFT", msText(model.lastRequestTTFT), note: "server p50",
                             help: "Time to first token: how long a request waits before its first token arrives. The median across recent requests, as the server reports it. Long prompts raise it; cached prefixes lower it.")
                        Card("Prefill tok/s", tpsText(model.prefillGaugeValue),
                             note: maximaText(model.prefillMax5m, model.prefillMaxSession),
                             help: "Prompt tokens read per second right now, with the highest rate in the last 5 minutes and in this session.")
                        Card("Decode tok/s", tpsText(model.decodeGaugeValue),
                             note: maximaText(model.decodeMax5m, model.decodeMaxSession),
                             help: "Tokens generated per second right now, with the highest rate in the last 5 minutes and in this session.")
                        Card("Draft acceptance", pctText(snapOfDraft()),
                             help: "Share of the draft model's guessed tokens that the main model accepted. Higher means faster generation; it drops on unpredictable text.")
                        Card("Cache hit rate", pctText(snap.cacheHitRate), note: "lookups \(snap.cacheLookups ?? 0)",
                             help: "Share of prompt lookups that found a cached prefix, so the server skipped reading that part of the prompt again.")
                    }
                    chartBlock

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                              spacing: 10) {
                        Card("TTFT p95", msText(snap.ttftP95),
                             help: "Time to first token for the slowest 5% of recent requests.")
                        Card("ITL p50", msText(snap.itlP50),
                             help: "Inter-token latency: the typical gap between generated tokens. Lower is faster.")
                        Card("ITL p95", msText(snap.itlP95),
                             help: "Inter-token latency for the slowest 5% of gaps between generated tokens.")
                        Card("Scheduler", schedulerTotal(snap), note: schedulerText(snap),
                             help: "Total requests in the scheduler, split in the line below: queue waiting, prefill reading its prompt, decode generating.")
                    }

                }
                .padding(16)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "gauge")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .foregroundStyle(.secondary)
                if let v = model.engineVersion {
                    Text("engine \(v) installed at \(EngineInstaller.currentLink.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func memorySection(_ snap: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Two quick "am I running out?" glances sharing one row; the Splash budget bar keeps
            // the full width below them.
            HStack(alignment: .top, spacing: 10) {
                if physicalRAM != nil { ramBar }
                if MachineInfo.totalDisk != nil { diskBar(snap) }
            }
            budgetBar(snap)
        }
    }

    // System RAM at a glance. The three numbers the old banner line spelled out, as a bar; the
    // legend below it still states them exactly.
    private var ramBar: some View {
        SegmentBar(
            label: "RAM",
            trailing: "\(MachineInfo.gb(physicalRAM ?? 0)) total",
            segments: [
                .init(name: "Splash", bytes: model.modelFootprint, color: .blue),
                .init(name: "macOS", bytes: otherUsed, color: .orange),
                .init(name: "free", bytes: availableRAM, color: .secondary.opacity(0.25)),
            ],
            total: physicalRAM ?? 0,
            help: "Physical memory on this Mac. Splash = physical pages charged to the server process tree right now; macOS = everything else in use; free = available now. Weights are memory-mapped and fault in on use, so this grows during decode and shrinks when idle."
        )
    }

    // The volume's whole-disk picture: what the engine's persistent cache and the model downloads
    // cost, everything else in use, and what is left. The cache colors match the budget bar's KV
    // and states accounts — same data, parked on disk instead of in RAM. Labels stay short because
    // five legend items in half a row has no room for "cache KV".
    private func diskBar(_ snap: StatusSnapshot) -> some View {
        let cache = SSDCache.usage()
        let free = MachineInfo.freeDisk
        let total = MachineInfo.totalDisk ?? 0
        let models = model.hfCacheBytes
        return SegmentBar(
            label: "Disk",
            trailing: "\(MachineInfo.gb(total)) total",
            segments: [
                .init(name: "KV", bytes: cache.kv, color: .orange),
                .init(name: "states", bytes: cache.states, color: .mint),
                .init(name: "models", bytes: models, color: .purple),
                .init(name: "other", bytes: otherDisk(cache: cache, models: models, free: free, total: total),
                      color: .secondary.opacity(0.5)),
                .init(name: "free", bytes: free, color: .secondary.opacity(0.25)),
            ],
            total: total,
            help: "Space on the volume that holds the model store and the SSD cache tier. KV and states are the engine's persistent cache, measured as allocated bytes rather than the file sizes it reports: the slot files are sparse, so a KV arena sized in the tens of GB can cost a fraction of that on disk. Models is the Hugging Face download cache at ~/.cache/huggingface/hub, counted once per shared blob — it holds every model this Mac has pulled, not only Splash's catalog; the model now running is \(MachineInfo.gb(MachineInfo.cachedModelSize(model.effectiveModel ?? model.effectiveModelID))) of it. Engine tier: \(MachineInfo.bytesText(snap.diskUsed)) of \(MachineInfo.gb(snap.diskLimit)) limit, \(MachineInfo.bytesText(snap.diskWrittenLastHour)) written in the last hour, \(diskPersistentText(snap.diskPersistent)) (kept across restarts or not), KV spill \(snap.kvSpill ?? "none")."
        )
    }

    private func otherDisk(cache: SSDCache.Usage, models: Int?, free: Int?, total: Int) -> Int? {
        guard let free, total > 0 else { return nil }
        return max(0, total - free - cache.total - (models ?? 0))
    }

    // The full-width Splash budget bar: the engine's own accounting, one segment per
    // account (fixed / kv / states / …) plus headroom, like the macOS storage bar.
    @ViewBuilder
    private func budgetBar(_ snap: StatusSnapshot) -> some View {
        let limit = snap.govLimit ?? 0
        // No governor data (or an engine that doesn't report it): the bar is meaningless —
        // skip it rather than render a "0.0 GB of 0.0 GB used" bar with full-width segments.
        if limit > 0 {
            let accounts = snap.govAccounts.filter { $0.currentBytes > 0 }
            let charged = snap.govCharged ?? accounts.reduce(0) { $0 + $1.currentBytes }
            let headroom = snap.govHeadroom ?? max(0, limit - charged)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Splash budget")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(MachineInfo.gb(charged)) of \(MachineInfo.gb(limit)) used")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(accounts.enumerated()), id: \.offset) { _, a in
                            Rectangle()
                                .fill(accountColor(a.name))
                                .frame(width: max(0, geo.size.width * min(1, CGFloat(a.currentBytes) / CGFloat(limit))))
                        }
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 16)
                .clipShape(Capsule())
                HStack(spacing: 14) {
                    ForEach(Array(accounts.enumerated()), id: \.offset) { _, a in
                        HStack(spacing: 4) {
                            Circle().fill(accountColor(a.name)).frame(width: 7, height: 7)
                            Text("\(accountLabel(a.name)) \(MachineInfo.gb(a.currentBytes))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                        Text("headroom \(MachineInfo.gb(headroom))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("limit \(MachineInfo.gb(limit))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(budgetCaption(snap))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help("The engine's own budget accounting against the hard budget it was launched with. Segments are the engine's accounts — fixed (weights and fixed runtime), kv (the KV page pool), states (the linear-attention state cache); gray is headroom, what may still grow.")
        }
    }

    private func accountColor(_ name: String) -> Color {
        switch name {
        case "fixed": return .blue
        case "kv": return .orange
        case "states": return .mint
        case "vision_arena": return .pink
        case "embeddings": return .secondary.opacity(0.4)
        default: return .secondary.opacity(0.25)
        }
    }

    private func accountLabel(_ name: String) -> String {
        switch name {
        case "fixed": return "fixed (weights + runtime)"
        case "kv": return "KV cache"
        case "states": return "linear-attention states"
        case "vision_arena": return "vision arena"
        case "embeddings": return "embeddings"
        default: return name
        }
    }

    private func budgetCaption(_ snap: StatusSnapshot) -> String {
        let growth = snap.govGrowthAllowed == nil ? "?" : (snap.govGrowthAllowed! ? "growth allowed" : "growth blocked")
        return "\(growth) · denied \(snap.govDeniedReservations ?? 0) · system pressure \(snap.govSystemPressure ?? "–") · peak \(MachineInfo.bytesText(snap.memActualPeak))"
    }

    @ViewBuilder
    private var chartBlock: some View {
        TimeSeriesChart(samples: model.history, defs: [
            .init(name: "Draft accept", color: .green,
                  extract: { $0.draftAcceptance }, format: { String(format: "%.0f%%", $0 * 100) }),
            .init(name: "Cache hit", color: .mint,
                  extract: { $0.cacheHitRate }, format: { String(format: "%.0f%%", $0 * 100) }),
            .init(name: "Prefill tok/s", color: .orange,
                  extract: { $0.prefillTps }, format: { String(format: "%.0f", $0) }),
            .init(name: "Decode tok/s", color: .blue,
                  extract: { $0.decodeTps }, format: { String(format: "%.0f", $0) })
        ])
    }

    private func maximaText(_ fiveMin: Double?, _ session: Double?) -> String {
        let f = fiveMin.map { String(format: "%.0f", $0) } ?? "–"
        let s = session.map { String(format: "%.0f", $0) } ?? "–"
        return "peak \(f) (5m) · \(s) (session)"
    }

    private var physicalRAM: Int? {
        let v = MachineInfo.physicalRAM
        return v > 0 ? v : nil
    }

    private var availableRAM: Int? {
        MachineInfo.availableRAM
    }

    private var otherUsed: Int? {
        guard let physical = physicalRAM, let avail = availableRAM else { return nil }
        let used = max(0, physical - avail)
        let model = model.modelFootprint ?? 0
        return max(0, used - model)
    }

    private func snapOfDraft() -> Double? {
        model.draftAcceptance ?? model.history.last?.draftAcceptance
    }

    private var statusText: String {
        switch model.phase {
        case .starting:
            return "Starting: status appears once the model has loaded"
        case .stopping:
            return "Stopping…"
        case .ready:
            return "waiting for /status…"
        default:
            return "Server not running; press Start in the toolbar"
        }
    }

    private func diskPersistentText(_ persistent: Bool?) -> String {
        guard let persistent else { return "–" }
        return persistent ? "persistent" : "volatile"
    }

    private func msText(_ v: Double?) -> String? {
        v.map { String(format: "%.0f ms", $0) }
    }

    private func tpsText(_ v: Double?) -> String? {
        v.map { String(format: "%.1f", $0) }
    }

    private func pctText(_ v: Double?) -> String? {
        v.map { String(format: "%.1f%%", $0 * 100) }
    }

    // The card's big slot is the total; the breakdown lives in the note line like every other
    // card. The three-word form used to sit in the value slot and wrapped to two lines, which
    // made this the tallest card in the grid.
    private func schedulerTotal(_ snap: StatusSnapshot) -> String {
        "\((snap.queued ?? 0) + (snap.prefilling ?? 0) + (snap.decoding ?? 0))"
    }

    private func schedulerText(_ snap: StatusSnapshot) -> String {
        "\(snap.queued ?? 0) queue · \(snap.prefilling ?? 0) prefill · \(snap.decoding ?? 0) decode"
    }
}

struct Card: View {
    let title: String
    let value: String?
    var note: String = ""
    var help: String = ""

    init(_ title: String, _ value: String?, note: String = "", help: String = "") {
        self.title = title
        self.value = value
        self.note = note
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.medium)
            // One reserved note line: cards keep matching heights without every card paying for
            // a second line most of them never use.
            Text(note.isEmpty ? " " : note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .modifier(HelpIfNotEmpty(help))
    }
}

// .help has no optional overload; an empty tooltip must attach nothing.
private struct HelpIfNotEmpty: ViewModifier {
    let text: String
    init(_ text: String) { self.text = text }
    @ViewBuilder func body(content: Content) -> some View {
        if text.isEmpty { content } else { content.help(text) }
    }
}
import SwiftUI

// The Status tab's hardware row — the macmon module's whole surface.
//
// Opt-in rule (architecture.md 2026-11-27): this view is the ONLY place the install can be
// triggered, and only through the button below. The off state is a single slim card, so the
// feature is discoverable without costing the trimmed status page real vertical space.
// Turning it off lives in the row's context menu (a permanent visible control would re-add
// the chrome the 1.4.0 slim-down removed).

struct HardwareSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var sampler: HardwareSampler
    // Probed once per appearance: Macmon.resolve() spawns `macmon --version`, which must not
    // ride the tab's per-second redraws.
    @State private var found: MacmonSource?

    var body: some View {
        Group {
            if model.config.hardwareStatsEnabled {
                switch sampler.state {
                case .running, .starting, .stopped:   // .stopped only exists between the toggle and the launch
                    if let s = sampler.latest {
                        liveRow(s)
                    } else {
                        pendingCard("starting…",
                                    note: "first sample lands in about a second")
                    }
                case .failed(let msg):
                    failedCard(msg)
                }
            } else {
                promptCard
            }
        }
        .onAppear { found = Macmon.resolve() }
    }

    // MARK: states

    // Off. The button is the consent action: AppModel's toggle handler installs only when
    // reached through it, and adapts its own label to what resolve() found.
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            chrome(title: "Hardware stats",
                   value: found == nil ? "not installed" : "off",
                   note: (found.map { "macmon found: \($0.label)" }
                       ?? "installs macmon \(Macmon.defaultPin.version) (MIT, ~1 MB) — or `brew install macmon`"),
                   help: "Package power, core clocks, GPU, temperatures and fans, read sudoless through macmon — the open-source Apple Silicon monitor (MIT licensed). Nothing is downloaded or launched until you press Enable; macmon then runs as a child process of this app only while enabled.")
            HStack(spacing: 8) {
                Spacer()
                Button(found == nil ? "Install & enable" : "Enable") {
                    // The flip itself is the consent; AppModel's handler resolves first
                    // and downloads only when nothing is found.
                    model.config.hardwareStatsEnabled = true
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .cardFace()
    }

    private func pendingCard(_ value: String, note: String) -> some View {
        chrome(title: "Hardware stats", value: value, note: note,
               help: "macmon is streaming; the row replaces itself once the first sample decodes.")
    }

    private func failedCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            chrome(title: "Hardware stats", value: "unavailable", note: msg,
                   help: msg + "\n\nRetry installs the pinned macmon if it is missing; a macmon that keeps crashing usually means a macOS update moved the counters — check for a newer SplashGUI.")
            HStack(spacing: 8) {
                Spacer()
                Button("Retry") {
                    Task { await sampler.installAndStart() }
                }
                .controlSize(.small)
                Button("Turn off") { model.config.hardwareStatsEnabled = false }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .cardFace()
    }

    // MARK: live row — four cards, same grid rhythm as the latency rows

    private func liveRow(_ s: MacmonSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 10) {
            Card("Chip power", watts(s.allPower),
                 note: "cpu \(watts(s.cpuPower)) · gpu \(watts(s.gpuPower)) · ane \(watts(s.anePower))",
                 help: """
                 Power the package (CPU+GPU+ANE+DRAM controllers) is drawing right now, from \
                 Apple's chip-level counters — the same source powermetrics reports. This is the \
                 compute number to watch during a generation run; it is not wall draw (the SMC \
                 system-total reading updates seconds behind load, so it is not shown here). \
                 Desktop adapters and battery flow are visible in `macmon pipe` output. \
                 Session peak: \(sampler.maxima.powerW.map { String(format: "%.1f W", $0) } ?? "–").
                 """)
            Card("CPU usage", pctBig(s.cpuActiveRatio),
                 note: clockNote(s),
                 help: """
                 Share of the last second with at least one core active — the headline \
                 busyness number. The line below gives each cluster's current clock; the \
                 per-cluster busy shares are in the chart underneath. Clusters idle down to \
                 their floor between tokens; a generation run should hold high usage and top \
                 clocks. Session peak: \(sampler.maxima.cpuUtil.map { String(format: "%.0f%%", $0 * 100) } ?? "–").
                 """)
            Card("GPU usage", pctBig(s.gpuScaledRatio),
                 note: "\(s.gpuFreqMhz) MHz",
                 help: "Frequency-weighted GPU utilization — how hard the GPU worked, counting how fast it ran. Inference load mostly shows up here: Splash runs compute on Metal. The clock line below is where the GPU idles between tokens. Session peak: \(sampler.maxima.gpuUtil.map { String(format: "%.0f%%", $0 * 100) } ?? "–").")
            Card("SoC temp", hottest(s).map { String(format: "%.0f °C", $0) },
                 note: tempNote(s),
                 help: """
                 The HOTTEST part of the package right now — whichever of the CPU-core or GPU \
                 sensor averages (SMC) is higher, with both spelled out on the line below and \
                 the first fan's RPM. Session peak: \(sampler.maxima.hottestTempC.map { String(format: "%.0f °C", $0) } ?? "–"). \
                 Apple Silicon throttles well above this — treat it as a trend line, not an \
                 alarm; the engine caps itself via the system thermal state anyway.
                 """)
        }
        .contextMenu {
            Button("Turn off hardware stats") { model.config.hardwareStatsEnabled = false }
        }

        // Power / heat / utilization on the same 1 s cadence the engine chart samples at 2 s:
        // reading a tok/s dip against a power or clock line is the whole point of the module.
        TimeSeriesChart(samples: sampler.history, defs: [
            .init(name: "Power", color: .yellow,
                  extract: { $0.allPower }, format: { String(format: "%.1f W", $0) },
                  peakValue: [sampler.maxima.powerW, sampler.persistedPeakW].compactMap { $0 }.max(),
                  fullScale: powerAxis),
            .init(name: "Hottest °C", color: .red,
                  extract: { hottest($0) },
                  format: { String(format: "%.0f°C", $0) },
                  peakValue: sampler.maxima.hottestTempC),
            .init(name: "CPU", color: .teal,
                  extract: { $0.cpuActiveRatio }, format: { String(format: "%.0f%%", $0 * 100) },
                  peakValue: sampler.maxima.cpuUtil, fullScale: 1.0),
            .init(name: "GPU", color: .indigo,
                  extract: { $0.gpuScaledRatio }, format: { String(format: "%.0f%%", $0 * 100) },
                  peakValue: sampler.maxima.gpuUtil, fullScale: 1.0),
        ], helpText: "Rolling 8 min of macmon hardware samples, one per second, continuous — idle time renders too (the flat baseline before a request is the reference line). Power is drawn against a real watt axis: the top is this Mac's LEARNED peak draw rounded up to the next 10 W — the highest package power ever recorded here, remembered across launches (no hard tables: the same chip draws different boost power in different machines). It only ever grows, so the idle baseline sinks toward the floor over the first few heavy runs. CPU/GPU utilization are fixed 0–100 %. Temperature keeps per-line 90th-percentile scaling, because a 32→36 °C drift has no meaningful absolute axis and would otherwise hide under the power spikes. The legend peak is the all-time power record (session peak for the other lines).")
        }
    }

    // MARK: formatting

    private func watts(_ v: Double?) -> String {
        v.map { String(format: "%.1f W", $0) } ?? "–"
    }
    private func pctBig(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
    // Power axis top: the learned machine peak (persisted all-time, or this session if that
    // one runs higher) rounded UP to the next 10 W, floored at 10 W. Monotonic forever now —
    // maxima never shrink and the record survives relaunches — so the idle baseline sinks
    // toward the floor across the first few heavy runs and stays put after that.
    private var powerAxis: Double {
        (max(10, sampler.axisPowerW) / 10).rounded(.up) * 10
    }
    private func clockNote(_ s: MacmonSample) -> String {
        s.cpuTiers.map { "\($0.label) \($0.freqMhz)" }.joined(separator: " · ") + " MHz"
    }
    private func hottest(_ s: MacmonSample) -> Double? {
        switch (s.temp.cpuTempAvg, s.temp.gpuTempAvg) {
        case (let a?, let b?): return max(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }
    // Units belong on each number, not the line: a shared " °C" suffix used to hang off the
    // end and turned "fan 2317" into 2317 °C.
    private func tempNote(_ s: MacmonSample) -> String {
        var parts = [
            "cpu " + (s.temp.cpuTempAvg.map { String(format: "%.0f°", $0) } ?? "–"),
            "gpu " + (s.temp.gpuTempAvg.map { String(format: "%.0f°", $0) } ?? "–"),
        ]
        if let fan = s.fans?.first {
            parts.append("fan \(fan.rpm) rpm")
        } else if let pct = s.batteryPercent {
            parts.append("batt \(pct)%")   // desktops have no fans; laptops show battery beside heat
        }
        return parts.joined(separator: " · ")
    }

    // Card chrome identical to the shared Card view, but as a builder so the prompt/failed
    // states can bolt a trailing button under it without Card growing a button parameter
    // every other card would carry.
    private func chrome(title: String, value: String?, note: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.medium)
            Text(note.isEmpty ? " " : note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .help(help)
    }
}

// The shared Card face (design.md: controlBackgroundColor fill, separator stroke, radius 8),
// for the prompt/failure cards that outgrow what `Card` can hold.
private extension View {
    func cardFace() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

import SwiftUI

struct StageChipsRow: View {
    @EnvironmentObject var model: AppModel
    var flexibleWidth = true  // trailing Spacer fills the container; off inside toolbars

    var body: some View {
        HStack(spacing: 8) {
            chip("prefill", active: model.currentStage == .prefill)
            chip("generation", active: model.currentStage == .decode)
            if flexibleWidth { Spacer() }
        }
        .help("Live request stage from the 2s status poll. Green = active right now: prefill while a prompt is read, generation while tokens come out.")
    }

    private func chip(_ label: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.callout)
                .fontWeight(active ? .semibold : .regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Green lives on the dot and the chip outline only. An un-clipped tinted fill let the
        // green wash past the rounded border into the title-bar material.
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(active ? Color.green : Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// The server control row lives in the window toolbar (title-bar strip): it owns the
// title-bar strip so it works from every tab.
struct ServerToolbarControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            contextSlot
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            StageChipsRow(flexibleWidth: false)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) {
                Text("http://" + endpointHost + ":")
                    .font(.system(.caption, design: .monospaced))
                    .help("The endpoint other services connect to. OpenAI-compatible API under /v1, Anthropic under /v1/messages. With “Serve on LAN” on (Run tab) this shows this Mac's LAN address so you can copy it for other machines; 0.0.0.0 means the toggle is on but no network is leased yet.")
                // String ports: Text interpolation of an Int applies locale number formatting,
                // which grouped the port as "8,095".
                TextField("", value: $model.config.run.port, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 52)
                    .foregroundStyle(model.portValid ? Color.primary : Color.red)
                    .help("HTTP port of the server. Splash's own default is 8000; the app uses \(RunConfig.defaultPort). Change if something else owns the port. Editable while running; an edit is a pending change for Apply & Restart.")
                Button {
                    copyToClipboard(endpoint)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the endpoint URL")
            }
            .fixedSize(horizontal: true, vertical: false)
            Button("Apply & Restart") { model.restart() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(model.phase == .ready && model.hasPendingChanges))
                .help("Stop the server and start it again with the edited settings. Model, context, memory, KV and port changes always need this.")
                .fixedSize(horizontal: true, vertical: false)
            if model.phase == .ready || model.phase == .starting {
                Button("Stop", role: .destructive) { model.stop() }
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Button(model.engineVersion == nil ? "Download & start" : "Start") { model.start() }
                    .disabled(!model.canStart || !model.portValid || model.isInstallingEngine)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // The toolbar host follows the (possibly edited) toggle, the way the port field follows
    // the edited port: the LAN address once "Serve on LAN" is on, loopback otherwise.
    private var endpointHost: String {
        return MachineInfo.effectiveHost(lanEnabled: model.config.run.lanAccess)
    }

    private var endpoint: String { "http://" + endpointHost + ":" + String(model.config.run.port) }

    // One slot, switched in place: the engine install / model load progress while getting to
    // ready, the KV context gauge once ready, and the plain server state with an empty gauge
    // while not running — a bar captioned "Context" would imply a context to spend.
    @ViewBuilder
    private var contextSlot: some View {
        if model.isInstallingEngine {
            VStack(alignment: .leading, spacing: 3) {
                Text(engineStepLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                ProgressView(value: min(1, max(0.02, model.engineProgress)))
            }
            .help("First launch downloads the Splash engine (~71 MB). Later launches reuse it.")
        } else if model.phase == .starting {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.loadStage.isEmpty ? "starting…" : model.loadStage)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                ProgressView(value: model.loadProgress ?? 0.05)
            }
            .help("Covers the model download (if needed) and engine loading")
        } else if model.phase == .ready, let snap = model.status, let max = snap.maxContextTokens, max > 0 {
            // The gauge only moves while requests run; between runs it would reset to 0 and
            // stop answering "how full is context?". Hold the last non-zero reading until
            // the next one arrives.
            let liveUsed = snap.contextUsedTokens ?? 0
            let used = liveUsed > 0 ? liveUsed : (model.lastContextUsedTokens ?? 0)
            let fraction = liveUsed > 0 ? (snap.contextUsedFraction ?? 0) : (model.lastContextUsedFraction ?? 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(String(used))/\(String(max / 1024))K")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(fraction > 0.9 ? .orange : .accentColor)
            }
            .help("Tokens held by active requests' KV out of the granted window (server pool gauge, updated on the 2s status poll). While the server starts, this shows the download and load progress instead.")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(slotStatusLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
            }
            .help("The context gauge appears once the server is up; until then this is the server state.")
        }
    }

    // The context slot's caption while there is no context to gauge. .starting and the engine
    // install have their own progress branches above.
    private var slotStatusLabel: String {
        switch model.phase {
        case .ready: return "Waiting for status…"   // up, first poll not in yet
        case .stopping: return "Stopping…"
        case .exited: return "Exited"
        default: return "Stopped"
        }
    }

    private var engineStepLabel: String {
        let v = model.engineResolvedVersion.map { " \($0)" } ?? ""
        switch model.engineStep {
        case .checking: return "Checking for the engine…"
        case .downloading: return "Downloading Splash\(v): \(Int(model.engineProgress * 100))%"
        case .verifying: return "Verifying the download…"
        case .extracting: return "Installing the engine…"
        case .validating: return "Checking the engine…"
        case .switching: return "Activating the engine…"
        default: return "Installing the engine…"
        }
    }
}

// A slim segmented bar in the macOS storage-bar shape: caption row, thin proportional bar,
// legend carrying the real numbers. A non-zero segment narrower than `minPoints` is widened to
// that floor so it stays visible as a sliver instead of vanishing; the shortfall comes off the
// largest segment so the bar still fills exactly one row. Precision lives in the legend, not the
// widths - and the floor is in points, not a percentage, so a segment ~100x smaller than its
// neighbour stays ~100x smaller instead of being floored up to equal it.
struct SegmentBar: View {
    struct Segment {
        let name: String
        let bytes: Int?
        let color: Color
    }

    let label: String
    let trailing: String
    let segments: [Segment]
    let total: Int
    let help: String

    private let minPoints: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(segmentWidths(in: geo.size.width).enumerated()), id: \.offset) { i, pt in
                        Rectangle()
                            .fill(segments[i].color)
                            .frame(width: max(0, pt))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            // Tight on purpose: side by side, the four-item Disk legend needs ~387pt of content
            // and the bar is ~409pt wide at the minimum window width, so an adaptive grid or the
            // budget bar's 14pt gap both push it onto a second line. The scale factor lets it
            // shrink a hair at that extreme instead of truncating a number.
            HStack(spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 3) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text("\(s.name) \(MachineInfo.gb(s.bytes))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
        // Fill whatever column the bar is given, so two of them in an HStack split it evenly.
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    private func segmentWidths(in width: CGFloat) -> [CGFloat] {
        var ws = segments.map { width * CGFloat($0.bytes ?? 0) / CGFloat(max(1, total)) }
        var deficit: CGFloat = 0
        for i in ws.indices where ws[i] > 0 && ws[i] < minPoints {
            deficit += minPoints - ws[i]
            ws[i] = minPoints
        }
        if deficit > 0, let largest = ws.indices.max(by: { ws[$0] < ws[$1] }) {
            ws[largest] = max(0, ws[largest] - deficit)
        }
        return ws
    }
}

struct SliderNumberField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    var digits: Int = 2

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)
            Slider(value: clampedBinding, in: range)
            TextField("", value: clampedBinding, format: .number.precision(.fractionLength(digits)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .monospacedDigit()
        }
        .help(helpText)
    }

    var helpText: String {
        "Drag or type a value; it snaps to \(step) and clamps to \(range.lowerBound)–\(range.upperBound)."
    }

    private var clampedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { value = Self.snap($0, range: range, step: step) }
        )
    }

    static func snap(_ v: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let snapped = (clamped / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

// Numeric field with an unset state, editing a local draft for the same reason as
// SamplingFieldRow: while the server runs, the 1s status poll repaints a TextField(value:format:)
// mid-keystroke. Empty text commits nil — that is what "unlimited" and "random" mean here — while
// text that is not a number restores the current value rather than silently unsetting it.
struct OptionalNumberField<Number: BinaryInteger & LosslessStringConvertible>: View {
    @Binding var value: Number?
    let placeholder: String
    var fallback: Number

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .disabled(value == nil)
                .opacity(value == nil ? 0.4 : 1)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, editing in
                    if !editing { commit() }
                }
            Toggle("Set", isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? (value ?? fallback) : nil }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
        }
        .onAppear { draft = text }
        .onChange(of: value) { _, _ in
            if !focused { draft = text }
        }
    }

    private var text: String { value.map { String(describing: $0) } ?? "" }

    private func commit() {
        let typed = draft.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            value = nil
            return
        }
        guard let parsed = Number(typed) else {
            draft = text
            return
        }
        value = parsed
        draft = String(describing: parsed)
    }
}

/// Rolling multi-series line chart. Generic over the sample type: the Status page uses it for
/// /status samples (with the prefill/generation stage strip below the plot) and for macmon
/// hardware samples (no strip — hardware has no request stages). Each series scales to the
/// p90 of its own values, so units (W, °C, %, tok/s) can mix freely on one canvas.
struct TimeSeriesChart<S>: View {
    struct SeriesDef {
        let name: String
        let color: Color
        let extract: (S) -> Double?
        let format: (Double) -> String
        // Session peak beside the live value in the legend (the call site owns the window —
        // see HardwareSampler.MacmonMaxima). Nil = legend shows the live value only.
        var peakValue: Double? = nil
        // Fixed top of the axis for this series. Set = the line is drawn against a real scale
        // (idle sits at the bottom, 100 % means 100 %); nil = the old p90-of-own-values
        // auto-scaling, which keeps slow-drifting series (temperature) legible.
        var fullScale: Double? = nil
    }

    let samples: [S]
    let defs: [SeriesDef]
    // Present = the bottom stage strip and its legend render; nil = plain chart.
    var stages: ((S) -> SampleStage?)? = nil
    // The tooltip is call-site knowledge (cadence, window, what gaps mean), not chart mechanics.
    var helpText: String = ""

    // Always reserved, even without a stage strip: both Status charts must share the exact
    // plot height (170 − 20) or their baselines sit a few pixels apart when stacked.
    private let bracketHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                let plotH = max(0, size.height - bracketHeight)
                for i in 1..<4 {
                    let y = plotH * CGFloat(i) / 4
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
                }
                // The 4th line: the data floor. Zero maps to 0.96 of the plot (values climb
                // through 0.92 of headroom above it), so without this the idle baselines of
                // every series float unexplained just above the bottom edge.
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: plotH * 0.96))
                baseline.addLine(to: CGPoint(x: size.width, y: plotH * 0.96))
                ctx.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                guard samples.count > 1 else { return }
                let span = CGFloat(Double(max(1, samples.count - 1)))
                let xAt = { (i: Int) in CGFloat(Double(i)) / span * size.width }

                for def in defs {
                    let vals = samples.map(def.extract)
                    let present = vals.compactMap { $0 }
                    guard !present.isEmpty else { continue }
                    let scale = def.fullScale ?? p90(present)
                    guard scale > 0 else { continue }
                    var path = Path()
                    var started = false
                    for (i, v) in vals.enumerated() {
                        guard let v else {
                            started = false
                            continue
                        }
                        let clamped = min(v / scale, 1.0)
                        let x = xAt(i)
                        let y = plotH * 0.96 - CGFloat(clamped) * plotH * 0.92
                        if started {
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.move(to: CGPoint(x: x, y: y))
                            started = true
                        }
                    }
                    ctx.stroke(path, with: .color(def.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }

                drawBracket(ctx: ctx, width: size.width, plotH: plotH)
            }
            .frame(height: 170)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            HStack(spacing: 14) {
                ForEach(defs, id: \.name) { def in
                    HStack(spacing: 4) {
                        Circle().fill(def.color).frame(width: 7, height: 7)
                        Text(def.peakValue.map { "\(def.name) \(currentText(def)) · peak \(def.format($0))" }
                             ?? "\(def.name) \(currentText(def))")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if stages != nil { stageLegend }
            }
            .font(.caption)
        }
        .help(helpText.isEmpty
              ? "Rolling window of samples. Each line scales to the 90th percentile of its own values so bursts don't flatten the rest."
              : helpText)
    }

    private var stageLegend: some View {
        HStack(spacing: 10) {
            legendDot(.orange, "prefill")
            legendDot(.green, "generation")
        }
    }

    private func legendDot(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).foregroundStyle(.secondary)
        }
    }

    private func drawBracket(ctx: GraphicsContext, width: CGFloat, plotH: CGFloat) {
        let stripY = plotH + 3
        let stripH = bracketHeight - 6
        guard let stages, samples.count > 1 else { return }
        let span = CGFloat(Double(max(1, samples.count - 1)))
        let xAt = { (i: Int) in CGFloat(Double(i)) / span * width }
        let segWidth = width / span

        // One fill per CONTIGUOUS RUN of the same stage, not per sample: adjacent
        // semi-transparent rects always show a seam (overlapping alpha paints darker,
        // exact butt joins paint lighter). A run is one rect, so it is one flat color.
        var runs: [(stage: SampleStage, from: Int, through: Int)] = []
        var open: (stage: SampleStage, from: Int)?
        for (i, s) in samples.enumerated() {
            guard let stage = stages(s) else {
                if let o = open { runs.append((o.stage, o.from, i - 1)); open = nil }
                continue
            }
            if let o = open, o.stage == stage { continue }
            if let o = open { runs.append((o.stage, o.from, i - 1)) }
            open = (stage, i)
        }
        if let o = open { runs.append((o.stage, o.from, samples.count - 1)) }

        for r in runs {
            let color: Color
            switch r.stage {
            case .prefill: color = .orange
            case .decode: color = .green
            }
            let x0 = xAt(r.from)
            // Extend by one sample width so the run covers its last sample's slice too.
            let x1 = max(xAt(r.through) + segWidth, x0 + 2)
            let rect = CGRect(x: x0, y: stripY, width: x1 - x0, height: stripH)
            ctx.fill(Path(rect), with: .color(color.opacity(0.8)))
        }
    }

    private func p90(_ vals: [Double]) -> Double {
        let sorted = vals.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.9))
        return max(0.0001, sorted[idx])
    }

    private func currentText(_ def: SeriesDef) -> String {
        for sample in samples.reversed() {
            if let v = def.extract(sample) { return def.format(v) }
        }
        return "–"
    }
}
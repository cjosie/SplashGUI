import Foundation

// MARK: - macmon JSON model
//
// One line of `macmon pipe` output. Only the fields this app consumes are declared;
// decoder keys map from macmon's snake_case via .convertFromSnakeCase. Fields that a
// given Mac can report as null (media_power on chips without a media engine) or omit
// are optional; everything else is present in every 0.12.x sample and decoding it is
// a hard requirement, so a format change fails loudly instead of silently zeroing UI.

struct MacmonSample: Decodable, Equatable {
    struct Core: Decodable, Equatable {
        let coreId: Int
        let freqMhz: Int
        let scaledRatio: Double
        let activeRatio: Double
    }
    struct Tier: Decodable, Equatable {
        let label: String        // "P"/"S" (or "E"…) — lowest to highest tier order
        let freqMhz: Int
        let scaledRatio: Double  // frequency-weighted busy fraction of the tier
        let activeRatio: Double  // plain busy fraction of the tier
        let cores: [Core]
    }
    struct Temps: Decodable, Equatable {
        let cpuTempAvg: Double?
        let gpuTempAvg: Double?
    }
    struct Memory: Decodable, Equatable {
        let ramTotal: Int64
        let ramUsage: Int64
        let swapTotal: Int64
        let swapUsage: Int64
        let pressurePercent: Int?
    }
    struct Fan: Decodable, Equatable {
        let name: String
        let rpm: Int
        let maxRpm: Int?
    }

    let timestamp: String
    let allPower: Double          // package power, W (macmon's CLPC total)
    let cpuPower: Double          // W
    let gpuPower: Double          // W
    let anePower: Double?         // W
    let ramPower: Double?         // W
    let sysPower: Double?         // W, SMC system total (≈ wall draw minus adapter loss)
    let dcInPower: Double?        // W, adapter input
    let cpuScaledRatio: Double
    let cpuActiveRatio: Double
    let cpuTiers: [Tier]
    let gpuFreqMhz: Int
    let gpuScaledRatio: Double
    let gpuActiveRatio: Double?
    let temp: Temps
    let memory: Memory
    let fans: [Fan]?
    let batteryPercent: Int?
    let batteryCharging: Bool?
    let batteryPlugged: Bool?
    let uptime: Double?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - Sampler

// Streams `macmon pipe -i <ms>` and publishes the newest decoded sample. The child is a
// plain piped subprocess: no port, no daemon, and `stop()` (or app exit) takes it with us.
// Unexpected exits (macmon crashing on a macOS change, a user killing it) retry with
// backoff up to `maxRetries`, then surface `.failed` so the UI can offer a fix instead of
// spinning. All public surface is main-actor; the read loop lives in a background Task.
// Session peaks, computed here from the stream (macmon's JSON is per-sample only — its TUI
// derives its own averages/maxima the same way). Reset whenever sampling (re)starts, so they
// mean "since you enabled this", and the chart legends can print them beside the live value.
struct MacmonMaxima: Equatable {
    var powerW: Double?
    var cpuTempC: Double?
    var gpuTempC: Double?
    var cpuUtil: Double?
    var gpuUtil: Double?

    var hottestTempC: Double? {
        switch (cpuTempC, gpuTempC) {
        case (let a?, let b?): return max(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }

    private func bump(_ cur: Double?, _ v: Double?) -> Double? {
        guard let v else { return cur }
        return cur.map { max($0, v) } ?? v
    }

    mutating func observe(_ s: MacmonSample) {
        powerW = bump(powerW, s.allPower)
        cpuTempC = bump(cpuTempC, s.temp.cpuTempAvg)
        gpuTempC = bump(gpuTempC, s.temp.gpuTempAvg)
        cpuUtil = bump(cpuUtil, s.cpuActiveRatio)
        gpuUtil = bump(gpuUtil, s.gpuScaledRatio)
    }
}

@MainActor
final class HardwareSampler: ObservableObject {
    // All-time package-power high-water mark, persisted across app launches. Hard per-chip
    // tables are useless (the same SoC draws wildly different boost power in a 14" laptop vs
    // a 16" vs a small desktop — different thermal headroom), so the chart axis is LEARNED:
    // it starts at the session floor and converges to this machine's real ceiling as the
    // user actually runs work. Stored outside config.json — it is machine telemetry, not a
    // user setting, and it must not ride along when someone copies their config to another Mac.
    struct PeakRecord: Codable { var peakPowerW: Double; var updated: Date }

    static var peakFile: URL { AppPaths.dataDir.appendingPathComponent("hardware-peak.json") }
    private(set) var persistedPeakW: Double?
    enum State: Equatable {
        case stopped
        case starting
        case running(MacmonSource)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var latest: MacmonSample?
    // Rolling chart window, newest last. 480 samples = 8 min at the default 1 s cadence —
    // the same horizon as the /status chart above it, so the two line up when comparing
    // a tok/s dip against a power spike.
    @Published private(set) var history: [MacmonSample] = []
    @Published private(set) var maxima = MacmonMaxima()
    private let historyLimit = 480

    var intervalMs = 1000
    private let maxRetries = 3

    // Clock discipline for the two stacked Status charts: while the /status poll runs, the
    // hardware HISTORY appends on that same tick (AppModel calls recordPollTick()), so both
    // charts' right edges advance together instead of alternating on two independent 1 Hz
    // clocks. The macmon stream keeps feeding `latest`/maxima live either way — a history
    // point is at most one second stale. With no server (no poll), the stream self-drives.
    var pollDriven = false
    private var lastAppendedStamp: String?

    init() {
        if let data = try? Data(contentsOf: Self.peakFile),
           let rec = try? JSONDecoder().decode(PeakRecord.self, from: data),
           rec.peakPowerW > 0 {
            persistedPeakW = rec.peakPowerW
        }
    }

    // The power axis ceiling source: the better of the persisted all-time mark and the
    // current session (a fresh machine record still sets the scale immediately).
    var axisPowerW: Double { max(maxima.powerW ?? 0, persistedPeakW ?? 0) }

    private var process: Process?
    private var readTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var stoppingByIntent = true
    private var retriesLeft = 0
    private var source: MacmonSource?

    // Start streaming from an already-resolved macmon (Homebrew or managed). NEVER installs
    // or downloads — when none is present it reports through the return value and `.failed`,
    // and the UI offers the install as its own explicit step (see Macmon's OPTIONAL MODULE
    // rule). Safe to call from window/appearance logic; it cannot touch the network.
    @discardableResult
    func start() -> Bool {
        guard process == nil else { return true }
        guard let src = Macmon.resolve() else {
            state = .failed("macmon is not installed. Install it with `brew install macmon`, or let the app download the pinned copy.")
            return false
        }
        launch(src)
        return true
    }

    // The install entry point: downloads the pinned macmon when none is resolved, then
    // streams. Bind this ONLY to an explicit user control ("Install & enable hardware
    // stats"); never call it from launch, resume, or anything automatic.
    func installAndStart(pin: MacmonPin = Macmon.defaultPin) async {
        if process != nil { return }
        if Macmon.resolve() == nil {
            state = .starting
            do { _ = try await Macmon.ensureInstalled(pin: pin) }
            catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                return
            }
        }
        start()
    }

    func stop() {
        guard let p = process else { stoppingByIntent = true; state = .stopped; return }
        stoppingByIntent = true
        process = nil
        readTask?.cancel(); readTask = nil
        retryTask?.cancel(); retryTask = nil
        latest = nil
        history = []
        lastAppendedStamp = nil
        maxima = MacmonMaxima()
        state = .stopped
        p.terminationHandler = nil
        p.terminate()
    }

    // One history point per /status poll tick while pollDriven — called by AppModel right
    // after it appends its own StatusSample, so the two charts tick in lockstep. Repeats the
    // newest macmon sample when the two clocks slip (same timestamp never appended twice).
    func recordPollTick() {
        guard pollDriven, let s = latest else { return }
        appendHistory(s)
    }

    private func appendHistory(_ s: MacmonSample) {
        guard s.timestamp != lastAppendedStamp else { return }
        lastAppendedStamp = s.timestamp
        history.append(s)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    // MARK: plumbing

    // Persist a new all-time high. The +0.5 W threshold is deliberate: a ramp can set a new
    // high every second, and the axis quantizes to 10 W anyway — sub-half-watt moves are not
    // worth a disk write. Atomic replace, best-effort: losing a write just relearns the peak.
    private func notePowerPeak(_ w: Double) {
        guard w > (persistedPeakW ?? 0) + 0.5 else { return }
        persistedPeakW = w
        let rec = PeakRecord(peakPowerW: w, updated: Date())
        guard let data = try? JSONEncoder().encode(rec) else { return }
        try? data.write(to: Self.peakFile, options: .atomic)
    }

    private func launch(_ src: MacmonSource) {
        source = src
        retriesLeft = maxRetries
        state = .starting

        let p = Process()
        p.executableURL = URL(fileURLWithPath: src.path)
        p.arguments = ["pipe", "-i", String(intervalMs)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // macmon's banner/diagnostics are not for us
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "MACMON_FORCE_CLPC")  // debug override is the user's, not ours
        p.environment = env

        process = p
        stoppingByIntent = false
        latest = nil
        history = []   // a restart mid-window would otherwise draw a line across the gap
        lastAppendedStamp = nil
        maxima = MacmonMaxima()
        do { try p.run() } catch {
            process = nil
            state = .failed("Could not launch macmon: \(error.localizedDescription)")
            return
        }

        let handle = out.fileHandleForReading
        readTask = Task.detached(priority: .utility) { [weak self] in
            // Bind once so the MainActor hops below capture a constant, not the weak var.
            guard let sampler = self else { return }
            do {
                for try await line in handle.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let sample = try? MacmonSample.decoder.decode(MacmonSample.self, from: data)
                    else { continue }   // tolerate a stray non-JSON line; the schema test covers real breaks
                    let ok = await MainActor.run { () -> Bool in
                        guard sampler.process === p else { return false }
                        sampler.latest = sample
                        sampler.maxima.observe(sample)
                        sampler.notePowerPeak(sample.allPower)
                        if !sampler.pollDriven { sampler.appendHistory(sample) }
                        if case .starting = sampler.state { sampler.state = .running(src) }
                        return true
                    }
                    if !ok { break }
                }
            } catch { /* EOF or cancel — the termination handler decides */ }
            handle.terminateReading()
        }

        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.process === proc, !self.stoppingByIntent else { return }
                self.process = nil
                self.readTask?.cancel(); self.readTask = nil
                guard self.retriesLeft > 0, let src = self.source else {
                    self.state = .failed("macmon exited (code \(code)) and retries are exhausted.")
                    return
                }
                self.retriesLeft -= 1
                let delay = Double(self.maxRetries - self.retriesLeft) * 2  // 2s, 4s, 8s
                self.retryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                    guard let self, !self.stoppingByIntent, self.process == nil else { return }
                    self.launch(src)
                }
            }
        }
    }
}

private extension FileHandle {
    // Unblock the `bytes.lines` iterator when the child dies, so the read Task exits.
    func terminateReading() { try? close() }
}

// MARK: - `SplashGUI --macmon-probe` — headless smoke test of the whole chain
// (resolve → download-if-missing → pipe → decode). Prints one summary line per sample.
// The download here is consented: a developer typed the flag; it is not a code path the app
// itself can reach.

func runMacmonProbe(samples: Int) -> Int32 {
    setbuf(stdout, nil)
    do {
        let path: String
        if let src = Macmon.resolve() {
            path = src.path
            print("macmon via \(src.label) at \(path)")
        } else {
            print("no macmon found — downloading pinned \(Macmon.defaultPin.version)…")
            path = try SemaphoreBox.run { box in
                Task {
                    do { box.complete(result: .success(try await Macmon.ensureInstalled())) }
                    catch { box.complete(result: .failure(error)) }
                }
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["pipe", "-i", "1000", "--samples", String(samples)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        // Blocking reads (this runs before the SwiftUI runloop exists): accumulate and
        // split on newlines — `macmon pipe` writes exactly one JSON document per line.
        let fh = out.fileHandleForReading
        var buf = Data()
        var count = 0
        func handle(_ lineData: Data) -> Bool {
            guard let s = try? MacmonSample.decoder.decode(MacmonSample.self, from: lineData) else {
                print("DECODE FAILED on: \(String(decoding: lineData.prefix(120), as: UTF8.self))")
                return false
            }
            count += 1
            let tiers = s.cpuTiers.map { "\($0.label) \($0.freqMhz)MHz/\(Int($0.activeRatio * 100))%" }.joined(separator: " ")
            let fans = (s.fans ?? []).map { "\($0.name) \($0.rpm)" }.joined(separator: " ")
            print("#\(count) pkg \(String(format: "%.1f", s.allPower))W cpu \(String(format: "%.1f", s.cpuPower))W gpu \(String(format: "%.1f", s.gpuPower))W sys \(s.sysPower.map { String(format: "%.1f", $0) } ?? "-")W | [\(tiers)] | gpu \(s.gpuFreqMhz)MHz | temp cpu \(s.temp.cpuTempAvg.map { String(format: "%.0f", $0) } ?? "-")C gpu \(s.temp.gpuTempAvg.map { String(format: "%.0f", $0) } ?? "-")C | ram \(s.memory.ramUsage / (1 << 20))/\(s.memory.ramTotal / (1 << 20))MiB | fans [\(fans)] | batt \(s.batteryPercent.map(String.init) ?? "-")%")
            return count >= samples
        }
        outer: while count < samples {
            let chunk = fh.availableData
            if chunk.isEmpty { break }   // EOF
            buf += chunk
            while let nl = buf.firstIndex(of: 0x0A) {
                let lineData = buf[buf.startIndex..<nl]
                buf.removeSubrange(buf.startIndex...nl)
                if handle(lineData) { break outer }
            }
        }
        p.terminate()
        print(count >= samples ? "probe ok (\(count) samples decoded)" : "stream ended after \(count) samples")
        return count >= samples ? 0 : 1
    } catch {
        print("probe failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        return 1
    }
}

// Bridge for awaiting one async value from a synchronous CLI entry point.
private final class SemaphoreBox {
    enum Outcome { case success(String), failure(Error) }
    private let sem = DispatchSemaphore(value: 0)
    private var outcome: Outcome = .failure(MacmonError.install("interrupted"))
    func complete(result: Outcome) { outcome = result; sem.signal() }
    static func run(_ body: (SemaphoreBox) -> Void) throws -> String {
        let box = SemaphoreBox()
        body(box)
        box.sem.wait()
        switch box.outcome {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}

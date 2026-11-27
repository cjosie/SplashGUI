import Foundation

// macmon (https://github.com/vladkens/macmon, MIT) is the hardware-metrics helper this app
// shells out to: `macmon pipe` streams one JSON sample per line (CPU/GPU/ANE watts, per-tier
// frequencies, temps, fans, RAM) sudoless through private IOReport channels we would otherwise
// have to reverse-engineer and re-reverse on every macOS release — macmon ships its own SMC
// fallbacks and a firmware-discovery pipeline for exactly that. MIT lets us bundle; we just
// don't bundle — same as the engine, we adopt a Homebrew copy when present and otherwise
// download the pinned release on demand.
//
// We consume its stdout only; never `macmon serve` (no listening port, and the child's
// lifetime stays tied to ours). The license ships inside the payload we extract.
//
// OPTIONAL MODULE — HARD RULE: macmon is a third utility we did not ship, so nothing may
// download or launch it without an explicit user action. The only entry points that install
// are `HardwareSampler.installAndStart()` (bound to an Enable/Install control the user clicks)
// and the `--macmon-probe` CLI flag a developer typed. `start()`, `--version` probes and app
// launch never touch the network. This is deliberately unlike the Splash engine, where the
// download IS the product and launching the app after setup counts as consent.

struct MacmonPin: Equatable {
    let version: String
    let sha256: String
    let url: String
}

// Where a usable macmon binary came from, for the status UI.
enum MacmonSource: Equatable {
    case homebrew(path: String, version: String)
    case managed(path: String, version: String)

    var label: String {
        switch self {
        case .homebrew(_, let v): return "Homebrew \(v)"
        case .managed(_, let v): return "managed \(v)"
        }
    }
    var path: String {
        switch self {
        case .homebrew(let p, _), .managed(let p, _): return p
        }
    }
}

enum Macmon {
    // Bumping this pin is an app release. macmon's releases carry no .sha256 sidecar asset,
    // so the digest is hand-verified against the downloaded release tarball (the same rule
    // as hardware-verified engine rows): 0.12.1's asset, downloaded 2026-12 from
    // github.com/vladkens/macmon, shasummed locally before being pasted here.
    static let defaultPin = MacmonPin(
        version: "0.12.1",
        sha256: "93e37628f57023aaf51147d32aeead6fa7ba092bf85bda86581a78e826e0d6fb",
        url: "https://github.com/vladkens/macmon/releases/download/v0.12.1/macmon-v0.12.1-aarch64-apple-darwin.tar.gz"
    )

    static let fm = FileManager.default

    // brew's prefixes on Apple Silicon and Intel Macs. Same adoption rule as the engine:
    // a Homebrew copy at or above the pin is used as-is and updates with `brew upgrade`.
    static let externalCandidates = ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"]

    static var macmonRoot: URL { AppPaths.dataDir.appendingPathComponent("macmon", isDirectory: true) }
    static func managedDir(for pin: MacmonPin) -> URL {
        macmonRoot.appendingPathComponent("macmon-\(pin.version)-arm64-macos", isDirectory: true)
    }
    static func managedBinary(for pin: MacmonPin) -> URL {
        managedDir(for: pin).appendingPathComponent("macmon")
    }

    // MARK: discovery

    // The version a binary reports (`macmon --version` → "macmon 0.12.1"), or nil when it is
    // missing, not executable, crashes, or speaks an unexpected format. Spawns a process, so
    // callers cache the result rather than re-probing per frame.
    static func binaryVersion(at path: String) -> String? {
        guard fm.isExecutableFile(atPath: path),
              let out = try? runCapturing(path, ["--version"]) else { return nil }
        // Tolerate "0.12.1", "macmon 0.12.1", "macmon v0.12.1 (commit …)".
        guard let tok = out.split(separator: " ").map(String.init).last(where: { $0.first?.isNumber == true })
        else { return nil }
        let v = tok.prefix { $0.isNumber || $0 == "." }
        return v.isEmpty ? nil : String(v)
    }

    // The one preference rule (sampler and status UI both use it): Homebrew at/above the pin,
    // else a managed copy of exactly the pin, else nil (caller offers the download).
    // `SPLASHGUI_MACMON_FORCE_MANAGED=1` skips the Homebrew check — a test hook so the
    // managed download path can be exercised on a Mac that has brew macmon installed.
    static func resolve(pin: MacmonPin = defaultPin) -> MacmonSource? {
        let forceManaged = ProcessInfo.processInfo.environment["SPLASHGUI_MACMON_FORCE_MANAGED"] == "1"
        for c in forceManaged ? [] : externalCandidates {
            guard let v = binaryVersion(at: c),
                  EngineInstaller.shouldAdoptExternal(v, wanted: pin.version) else { continue }
            return .homebrew(path: c, version: v)
        }
        let m = managedBinary(for: pin)
        if let v = binaryVersion(at: m.path), v == pin.version {
            return .managed(path: m.path, version: v)
        }
        return nil
    }

    // MARK: managed install

    // Ensure the pinned release is on disk and return its path. Downloads ~1 MB, verifies the
    // digest BEFORE extracting, then validates the binary actually runs at the pinned version
    // before it is moved into place — a truncated or bogus payload never becomes resolvable.
    // Throws MacmonError with a user-readable message; safe to call repeatedly (no-op once
    // the managed binary is in place). Skips Homebrew entirely: this is the fallback path.
    static func ensureInstalled(pin: MacmonPin = defaultPin) async throws -> String {
        let final = managedBinary(for: pin)
        if let v = binaryVersion(at: final.path), v == pin.version { return final.path }

        guard let url = URL(string: pin.url) else { throw MacmonError.install("macmon download URL is malformed.") }
        let stagedRoot = macmonRoot.appendingPathComponent(".staged", isDirectory: true)
        try? fm.removeItem(at: stagedRoot)
        try fm.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagedRoot) }

        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MacmonError.install("macmon download failed: HTTP \(http.statusCode) from \(url.host ?? "server").")
        }
        let tar = stagedRoot.appendingPathComponent("macmon.tar.gz")
        try? fm.removeItem(at: tar)
        try fm.moveItem(at: tmp, to: tar)

        let got = try EngineInstaller.sha256(of: tar)
        guard got.caseInsensitiveCompare(pin.sha256) == .orderedSame else {
            throw MacmonError.install("Downloaded macmon failed checksum (expected \(pin.sha256.prefix(12))…, got \(got.prefix(12))…).")
        }

        try EngineInstaller.run("/usr/bin/tar", ["-xzf", tar.path, "-C", stagedRoot.path])
        // The release tarball carries the bare binary (plus LICENSE/readme.md) at top level.
        let extracted = stagedRoot.appendingPathComponent("macmon")
        guard fm.fileExists(atPath: extracted.path) else {
            throw MacmonError.install("macmon archive does not contain the expected top-level binary.")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extracted.path)
        guard let v = binaryVersion(at: extracted.path), v == pin.version else {
            throw MacmonError.install("Extracted macmon does not report version \(pin.version).")
        }

        let dir = managedDir(for: pin)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: extracted, to: final)
        // Keep the release's license text next to the binary we adopted from the tarball.
        for extra in ["LICENSE", "readme.md"] {
            let src = stagedRoot.appendingPathComponent(extra)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: dir.appendingPathComponent(extra))
            }
        }
        pruneManaged(keeping: dir)
        return final.path
    }

    static func pruneManaged(keeping dir: URL) {
        guard let names = try? fm.contentsOfDirectory(atPath: macmonRoot.path) else { return }
        for n in names where n.hasPrefix("macmon-") && n != dir.lastPathComponent {
            try? fm.removeItem(at: macmonRoot.appendingPathComponent(n, isDirectory: true))
        }
    }

    // MARK: process helpers

    // Run an executable to completion capturing stdout (nil on non-zero exit). Short-lived
    // probes only (`--version`); long-running streams use HardwareSampler.
    static func runCapturing(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw MacmonError.install("`\(exe)` exited with status \(p.terminationStatus).") }
        return String(decoding: data, as: UTF8.self)
    }
}

enum MacmonError: LocalizedError {
    case install(String)
    var errorDescription: String? {
        switch self {
        case .install(let m): return m
        }
    }
}

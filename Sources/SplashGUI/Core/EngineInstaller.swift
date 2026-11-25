import Foundation
import CryptoKit

struct EnginePin: Equatable {
    let version: String
    let sha256: String
    let url: String
}

final class EngineInstaller: ObservableObject {
    enum Step: Equatable {
        case idle
        case checking
        case downloading
        case verifying
        case extracting
        case validating
        case switching
        case ready
        case failed(String)
    }

    @Published var step: Step = .idle
    @Published var progress: Double = 0
    @Published var resolvedVersion: String?
    @Published var installedVersion: String?

    // Bumping the engine is an app release; AppConfig's engine*Override fields are the escape hatch.
    static let defaultPin = EnginePin(
        version: "1.7.2",
        sha256: "40a1e6d585ed8f51b2f2e17c331e7d9533a1b666e1e6e418ddd623bdd3a29e2b",
        url: "https://github.com/incoai/splash/releases/download/1.7.2/splash-1.7.2-arm64-macos26.tar.gz"
    )

    static let fm = FileManager.default

    static var engineRoot: URL { AppPaths.dataDir.appendingPathComponent("engine", isDirectory: true) }
    static var currentLink: URL { engineRoot.appendingPathComponent("current") }
    static var stagedDir: URL { engineRoot.appendingPathComponent(".staged", isDirectory: true) }
    static var installLock: URL { engineRoot.appendingPathComponent(".install.lock") }

    static var pythonPath: URL { currentLink.appendingPathComponent("python/bin/python3") }
    static var launcherPath: URL { currentLink.appendingPathComponent("install/launcher.py") }

    // A Homebrew-casked engine (`brew install splash`, incoai/tap). The bottle's `libexec/`
    // mirrors the OTA tarball root exactly (python/bin/python3, install/launcher.py,
    // release.json), so `current` can simply point at it and every downstream reader —
    // isInstalled, release.json, the launcher argv — works unchanged. The `opt` symlink is
    // version-independent, so `brew upgrade` needs no app cooperation; `brew uninstall`
    // leaves it dangling and externalEngineVersion() returns nil.
    static var externalEngineRoot: URL {
        URL(fileURLWithPath: "/opt/homebrew/opt/splash/libexec", isDirectory: true)
    }

    // The version of a usable Homebrew engine, or nil (not installed, uninstalled, or an
    // unexpected layout). `at` lets the harness feed a fixture directory.
    static func externalEngineVersion(at root: URL? = nil) -> String? {
        let root = root ?? externalEngineRoot
        guard fm.isExecutableFile(atPath: root.appendingPathComponent("python/bin/python3").path),
              fm.fileExists(atPath: root.appendingPathComponent("install/launcher.py").path),
              let data = try? Data(contentsOf: root.appendingPathComponent("release.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String, !v.isEmpty else { return nil }
        return v
    }

    // Numeric-aware compare of dotted versions: "1.10.0" > "1.6.0"; non-numeric suffixes
    // ("1.6.0+build7") compare on their leading digits. Missing segments count as 0.
    nonisolated static func versionOrder(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // Point `current` at the Homebrew payload instead of downloading a managed copy.
    // The managed directories (if any) stay on disk untouched — this only moves a symlink.
    // True when `current` points at the adopted Homebrew payload rather than a managed dir.
    static var currentIsExternal: Bool {
        (try? fm.destinationOfSymbolicLink(atPath: currentLink.path)) == externalEngineRoot.path
    }

    static func adoptExternalEngine() throws {
        guard let v = externalEngineVersion() else {
            throw InstallError.preflight("No usable Homebrew Splash engine found at \(externalEngineRoot.path).")
        }
        try fm.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        try flipCurrent(to: externalEngineRoot.path)
        _ = v
    }

    static func currentReleaseVersion() -> String? {
        let rel = currentLink.appendingPathComponent("release.json")
        guard let data = try? Data(contentsOf: rel),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String else { return nil }
        return v
    }

    init() {
        installedVersion = Self.currentReleaseVersion()
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath.path)
    }

    func ensureInstalled(port: Int, override: EnginePin? = nil) async throws {
        await MainActor.run { self.step = .checking; self.progress = 0 }
        let pin = override ?? Self.defaultPin
        await MainActor.run { self.resolvedVersion = pin.version }

        // Reuse when `current` already runs exactly this pin's version from the right place:
        // this pin's own directory, or the adopted Homebrew payload (a same-version override
        // from ANOTHER URL must still install into its own dir, so overrides never match the
        // external path).
        let currentDest = try? Self.fm.destinationOfSymbolicLink(atPath: Self.currentLink.path)
        if let have = Self.currentReleaseVersion(), have == pin.version, Self.isInstalled,
           currentDest == Self.dirName(for: pin)
             || (override == nil && currentDest == Self.externalEngineRoot.path) {
            await MainActor.run { self.installedVersion = have; self.step = .ready }
            return
        }

        try preflight(port: port)
        // preflight takes the install lock; hold it only for the install itself. flock treats a
        // second open of the same file in one process as a different holder, so without this a
        // failed (or pin-changed) install would leave the GUI locked out — "another install is
        // already in progress" — until relaunch.
        defer { Self.releaseInstallLock() }

        let name = Self.dirName(for: pin)
        let stagedTar = Self.stagedDir.appendingPathComponent(name + ".tar.gz")
        let stagedRoot = Self.stagedDir.appendingPathComponent(name, isDirectory: true)

        // Wipe the staging area first: a previous failed attempt can leave an extracted
        // payload under the archive's own directory name (see findExtractedRoot), and a
        // stale one would confuse the discovery below.
        try? Self.fm.removeItem(at: Self.stagedDir)
        try Self.fm.createDirectory(at: Self.stagedDir, withIntermediateDirectories: true)

        do {
            try await download(pin: pin, to: stagedTar)
            await MainActor.run { self.step = .verifying; self.progress = 1.0 }
            let got = try Self.sha256(of: stagedTar)
            guard got.caseInsensitiveCompare(pin.sha256) == .orderedSame else {
                throw InstallError.preflight("Downloaded engine failed checksum (expected \(pin.sha256.prefix(12))…, got \(got.prefix(12))…).")
            }

            await MainActor.run { self.step = .extracting }
            try Self.run("/usr/bin/tar", ["-xzf", stagedTar.path, "-C", Self.stagedDir.path])
            // The archive's top-level directory is always named for the VERSION, while
            // `name` gains a URL hash whenever pin.url differs from the compiled default
            // (a resolved-latest or custom pin). Expecting stagedRoot there meant every
            // such install died on the release.json check AFTER the download — and
            // re-downloaded on every retry. Discover what was actually extracted.
            guard let extractedRoot = Self.findExtractedRoot(in: Self.stagedDir, preferring: stagedRoot) else {
                throw InstallError.preflight("Extracted archive has no release.json in any payload directory; unexpected archive layout.")
            }
            for rel in ["python/bin/python3", "engine/splash"] {
                try? Self.fm.setAttributes([.posixPermissions: 0o755],
                    ofItemAtPath: extractedRoot.appendingPathComponent(rel).path)
            }

            await MainActor.run { self.step = .validating }
            try Self.run(extractedRoot.appendingPathComponent("python/bin/python3").path,
                ["-u", extractedRoot.appendingPathComponent("install/launcher.py").path, "--help"])

            await MainActor.run { self.step = .switching }
            let finalDir = Self.engineRoot.appendingPathComponent(name, isDirectory: true)
            try? Self.fm.removeItem(at: finalDir)
            try Self.fm.createDirectory(at: Self.engineRoot, withIntermediateDirectories: true)
            try Self.fm.moveItem(at: extractedRoot, to: finalDir)
            try Self.flipCurrent(to: name)
            Self.prune(keeping: name)
            try? Self.fm.removeItem(at: Self.stagedDir)

            let v = Self.currentReleaseVersion()
            await MainActor.run { self.installedVersion = v; self.step = .ready }
        } catch {
            try? Self.fm.removeItem(at: Self.stagedDir)
            await MainActor.run {
                if self.step != .ready {
                    self.step = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
            }
            throw error
        }
    }

    // MARK: preflight

    private func preflight(port: Int) throws {
        var sys = utsname()
        if uname(&sys) == 0 {
            let machine = withUnsafeBytes(of: &sys.machine) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if machine != "arm64" {
                throw InstallError.preflight("This Mac is not running natively on arm64; the Splash engine needs native arm64.")
            }
        }
        if #available(macOS 26.4, *) {} else {
            throw InstallError.preflight("The Splash engine needs macOS 26.4 or later.")
        }
        guard let free = MachineInfo.freeDisk, free >= 1_200_000_000 else {
            throw InstallError.preflight("Not enough free disk space to install the engine (need ~1.2 GB).")
        }
        if Self.splashServing(port: port) {
            throw InstallError.preflight("A Splash server is already running. Stop it before updating the engine.")
        }
        if !Self.acquireInstallLock() {
            throw InstallError.preflight("Another engine install is already in progress.")
        }
    }

    private static func splashServing(port: Int) -> Bool {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Splash", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        guard let base, let names = try? fm.contentsOfDirectory(atPath: base.path) else { return false }
        for n in names where n.hasPrefix("serve") && n.hasSuffix(".lock") {
            guard let data = try? Data(contentsOf: base.appendingPathComponent(n)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int else { continue }
            if kill(Int32(pid), 0) == 0 { return true }
        }
        return false
    }

    private static var lockFD: Int32 = -1
    private static func acquireInstallLock() -> Bool {
        try? fm.createDirectory(at: engineRoot, withIntermediateDirectories: true)
        let fd = open(installLock.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lockFD = fd
        return true
    }
    static func releaseInstallLock() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    // MARK: download

    private func download(pin: EnginePin, to dest: URL) async throws {
        guard let url = URL(string: pin.url) else {
            throw InstallError.preflight("Engine download URL is malformed.")
        }
        let delegate = DownloadDelegate { [weak self] frac in
            Task { @MainActor in
                self?.step = .downloading
                self?.progress = frac
            }
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: url)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.onFinish = { result in
                switch result {
                case .success(let tmp):
                    try? FileManager.default.removeItem(at: dest)
                    do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume() }
                    catch { cont.resume(throwing: error) }
                case .failure(let e):
                    cont.resume(throwing: e)
                }
            }
            task.resume()
        }
    }

    // MARK: helpers

    // The one payload naming rule: the release asset, the install dir and the resolver's
    // expected file all share the same base.
    static func payloadBaseName(version: String) -> String {
        "splash-\(version)-arm64-macos26"
    }

    // The one "external engine at or above the pin → adopt" rule.
    nonisolated static func shouldAdoptExternal(_ external: String?, wanted: String) -> Bool {
        guard let external else { return false }
        return versionOrder(external, wanted) != .orderedAscending
    }

    static func dirName(for pin: EnginePin) -> String {
        let base = payloadBaseName(version: pin.version)
        // An override URL can serve a different payload under a version the pinned release
        // already used; keying the dir by the URL keeps the two installs from sharing it.
        guard pin.url != defaultPin.url else { return base }
        let h = SHA256.hash(data: Data(pin.url.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "splash-\(pin.version)-\(h)-arm64-macos26"
    }

    // The payload directory inside the staging area: the preferred (name-keyed) path when
    // it carries a release.json, otherwise the one directory that does — the archive's own
    // top-level name, which the install moves from.
    static func findExtractedRoot(in staged: URL, preferring: URL) -> URL? {
        if fm.fileExists(atPath: preferring.appendingPathComponent("release.json").path) { return preferring }
        guard let names = try? fm.contentsOfDirectory(atPath: staged.path) else { return nil }
        for n in names where n.hasPrefix("splash-") {
            let c = staged.appendingPathComponent(n, isDirectory: true)
            if fm.fileExists(atPath: c.appendingPathComponent("release.json").path) { return c }
        }
        return nil
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw InstallError.preflight("`\(exe)` exited with status \(p.terminationStatus).")
        }
    }

    static func flipCurrent(to name: String) throws {
        let tmp = currentLink.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        try fm.createSymbolicLink(atPath: tmp.path, withDestinationPath: name)
        if rename(tmp.path, currentLink.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw InstallError.preflight("Could not activate the new engine (symlink flip failed).")
        }
    }

    static func prune(keeping name: String) {
        guard let names = try? fm.contentsOfDirectory(atPath: engineRoot.path) else { return }
        for n in names where n.hasPrefix("splash-") && n.hasSuffix("-arm64-macos26") && n != name {
            try? fm.removeItem(at: engineRoot.appendingPathComponent(n, isDirectory: true))
        }
    }
}

enum InstallError: LocalizedError {
    case preflight(String)
    var errorDescription: String? {
        switch self {
        case .preflight(let m): return m
        }
    }
}

extension EngineInstaller {
    // Headless install for `SplashGUI --install-engine` — drives the same flow and exits 0/1.
    static func runCLI(port: Int) -> Int32 {
        setbuf(stdout, nil)
        // Same preference as the GUI: a Homebrew engine at or above the pin is adopted
        // instead of downloading a duplicate payload.
        if let ext = externalEngineVersion(),
           shouldAdoptExternal(ext, wanted: defaultPin.version) {
            do {
                try adoptExternalEngine()
                print("adopted Homebrew engine \(ext) at \(externalEngineRoot.path)")
                print("engine \(currentReleaseVersion() ?? "?") → \(currentLink.path)")
                return 0
            } catch {
                FileHandle.standardError.write(Data("adopt failed: \(error) — falling back to managed install\n".utf8))
            }
        }
        let inst = EngineInstaller()
        var code: Int32 = 1
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                try await inst.ensureInstalled(port: port)
                code = 0
            } catch {
                let m = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                FileHandle.standardError.write(Data("install failed: \(m)\n".utf8))
                code = 1
            }
            releaseInstallLock()
            done.signal()
        }
        var last = ""
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let line = "\(inst.step) \(Int(inst.progress * 100))%"
            if line != last { print(line); last = line }
        }
        print("engine \(inst.installedVersion ?? "?") → \(currentLink.path)")
        return code
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    var onFinish: ((Result<URL, Error>) -> Void)?
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        // A failed request (rate-limit page, missing asset) still "finishes downloading" its
        // error body; without the status check that HTML lands as tar.gz and only surfaces as
        // a confusing checksum failure.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finished = true
            onFinish?(.failure(InstallError.preflight(
                "Engine download failed: HTTP \(http.statusCode) from \(http.url?.host ?? "server").")))
            return
        }
        finished = true
        onFinish?(.success(location))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !finished {
            finished = true
            onFinish?(.failure(error))
        }
    }
    private var finished = false
}

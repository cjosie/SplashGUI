import Foundation
import Metal
import os

enum MachineInfo {
    private static let sizeLock = NSLock()
    private static var sizeCache: [String: Int] = [:]

    // Drop a cached size so the next lookup re-reads disk (e.g. after a model finishes downloading).
    static func invalidateModelSize(_ modelID: String) {
        sizeLock.lock()
        sizeCache[modelID] = nil
        sizeLock.unlock()
    }

    static func cachedModelSize(_ modelID: String) -> Int? {
        sizeLock.lock()
        if let v = sizeCache[modelID] {
            sizeLock.unlock()
            return v
        }
        sizeLock.unlock()
        let v = weightsSize(for: modelID)
        sizeLock.lock()
        sizeCache[modelID] = v
        sizeLock.unlock()
        return v
    }

    static var physicalRAM: Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }

    // The real GPU wired-memory ceiling for this exact chip/RAM combo, read once at runtime
    // (37.44 GB on the 48 GB M5 Pro). Falls back to the ~66% stock ratio if Metal is unavailable.
    static let metalMaxWorkingSet: Int = {
        if let cap = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize, cap > 0 {
            return Int(cap)
        }
        return physicalRAM * 66 / 100
    }()

    static var availableRAM: Int? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size))
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(
                to: integer_t.self,
                capacity: MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
            ) { dataPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, dataPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let avail = UInt64(stats.free_count + stats.inactive_count + stats.speculative_count)
        return Int(avail * UInt64(vm_page_size))
    }

    static var freeDisk: Int? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else { return nil }
        return (attrs[.systemFreeSize] as? Int64).map(Int.init)
    }

    // Capacity of the volume hosting the cache and the model store. "/" and the Data volume
    // share one APFS container, so free and total read the same pool the cache grows in.
    static var totalDisk: Int? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else { return nil }
        return (attrs[.systemSize] as? Int64).map(Int.init)
    }

    // The Hugging Face download cache: where weights actually live, with Splash's model store
    // symlinking into it. Measured with directorySize, whose dedupe by resolved path is essential
    // here — blobs are shared across snapshot links, so a naive walk counted 100.8 GB for a
    // 57.9 GB cache. Costs ~18 ms over 540 blobs, so callers should not do it per frame.
    static var hfHubDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    static func hfCacheBytes() -> Int? { directorySize(hfHubDir) }

    // The address to hand LAN clients: IPv4 on an active non-loopback interface, preferring
    // en0 (the built-in Wi-Fi on every Apple Silicon Mac), then any other "en*" (Thunderbolt
    // Ethernet/docks), then anything else. Skips link-local 169.254.x addresses — those mean
    // "no DHCP lease", so nothing off this Mac can reach them.
    static var lanIPv4Address: String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var en0: String?
        var otherEn: String?
        var any: String?
        var ptr = ifaddrPtr
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard ok == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if name == "en0" { en0 = ip; break }
            if name.hasPrefix("en"), otherEn == nil { otherEn = ip }
            if any == nil { any = ip }
        }
        return en0 ?? otherEn ?? any
    }

    static func footprint(pid: Int) -> Int? {
        var info = rusage_info_current()
        let r = withUnsafeMutableBytes(of: &info) { rawBuf in
            let typed = rawBuf.bindMemory(to: rusage_info_t?.self)
            return proc_pid_rusage(Int32(pid), RUSAGE_INFO_CURRENT, typed.baseAddress)
        }
        guard r == 0 else { return nil }
        return Int(info.ri_phys_footprint)
    }

    static func childPIDs(of parent: Int) -> [Int] {
        var size = 0
        guard sysctlbyname("kern.proc.all", nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let slots = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: slots)
        guard sysctlbyname("kern.proc.all", &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        guard count > 0, count <= procs.count else { return [] }
        return (0..<count)
            .filter { Int(procs[$0].kp_eproc.e_ppid) == parent }
            .map { Int(procs[$0].kp_proc.p_pid) }
    }

    static func serverFootprint(parentPID: Int) -> Int? {
        var total = footprint(pid: parentPID) ?? 0
        for child in childPIDs(of: parentPID) {
            total += footprint(pid: child) ?? 0
        }
        return total > 0 ? total : nil
    }

    static func weightsSize(for modelID: String) -> Int? {
        guard let dir = weightsDir(for: modelID) else { return nil }
        return directorySize(dir)
    }

    // Splash's selection link for a model ID: <models root>/<owner>/<repo[:variant]>, a symlink
    // to the content-addressed assembly under models/.resolved/ that holds model.json. The
    // variant is part of the link name, so it stays in the path here.
    static func selectionDir(for modelID: String) -> URL? {
        guard let slash = modelID.firstIndex(of: "/") else { return nil }
        let owner = String(modelID[..<slash])
        let repo = String(modelID[modelID.index(after: slash)...])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Splash/models/\(owner)/\(repo)")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    // The Hugging Face cache directory for a model ID: models--<owner>--<repo>, variant stripped.
    // One implementation of the naming rule; existence is the caller's question.
    static func hfCacheDir(for modelID: String) -> URL? {
        guard let slash = modelID.firstIndex(of: "/") else { return nil }
        let owner = String(modelID[..<slash])
        let repo = String(modelID[modelID.index(after: slash)...]).split(separator: ":").first ?? ""
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(owner)--\(repo)")
    }

    static func weightsDir(for modelID: String) -> URL? {
        if let splash = selectionDir(for: modelID) { return splash }
        guard let hf = hfCacheDir(for: modelID),
              FileManager.default.fileExists(atPath: hf.path) else { return nil }
        return hf
    }

    // The digest the engine recorded in model.json for one file of an installed assembly, keyed
    // as the record keys it ("target/<file>.gguf"). nil = not installed, or no record. The
    // engine's quick verify only re-checks these records' paths and byte counts, so comparing a
    // catalog hash against them catches a swapped or edited blob that quick verify would pass.
    static func installedDigest(for modelID: String, key: String) -> String? {
        guard let record = selectionDir(for: modelID)?.appendingPathComponent("model.json"),
              let data = try? Data(contentsOf: record), data.count < 4_194_304,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: [String: Any]],
              let entry = files[key] else { return nil }
        return entry["digest"] as? String
    }

    // nil when the installed assembly matches the catalog hash (or there is nothing to compare),
    // else a plain-language explanation. One implementation: Start blocks on it, --check-model prints it.
    static func modelHashMismatch(_ modelID: String) -> String? {
        guard let entry = CatalogModel.catalog.first(where: { $0.id == modelID }),
              let expected = entry.sha256, let target = entry.targetFile
        else { return nil }
        guard let installed = installedDigest(for: modelID, key: "target/\(target)") else { return nil }
        guard installed != expected else { return nil }
        return "\(modelID): the installed \(target) does not match the catalog hash. On disk "
            + "\(installed), expected \(expected). The cached download changed or is corrupt; delete "
            + "~/.cache/huggingface/hub/models--\(entry.owner)--\(entry.hfRepo) and start again to re-pull it."
    }

    // The "GGUF" magic at the head of a file.
    static func hasGGUFMagic(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url),
              let head = try? h.read(upToCount: 4) else { return false }
        return head == Data("GGUF".utf8)
    }

    // Whether a saved local entry's path is something the engine can serve: a GGUF file
    // (magic, per install/local.py) or a directory whose root holds a GGUF or an MLX model
    // (config.json + safetensors). A hint for the UI only — the engine has the last word.
    static func localLooksLikeModel(path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return hasGGUFMagic(URL(fileURLWithPath: path)) }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return false }
        if names.contains(where: { $0.lowercased().hasSuffix(".gguf") }) { return true }
        return names.contains("config.json")
            && names.contains(where: { $0.lowercased().hasSuffix(".safetensors") })
    }

    // Bytes a local entry loads: the GGUF file (every part of a split GGUF lies beside it) or
    // the model files at a directory's root. Stat sizes only, so no cache is needed.
    static func localWeightsSize(path: String) -> Int? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        // HF snapshot files are symlinks into the blob store; stat the resolved file, and
        // count only regular files so a directory entry never adds a bogus link size.
        func size(_ p: String) -> Int {
            let url = URL(fileURLWithPath: p).resolvingSymlinksInPath()
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true else { return 0 }
            return vals.fileSize ?? 0
        }
        var total = 0
        if isDir.boolValue {
            for name in (try? fm.contentsOfDirectory(atPath: path)) ?? []
            where name.lowercased().hasSuffix(".gguf") || name.lowercased().hasSuffix(".safetensors") {
                total += size((path as NSString).appendingPathComponent(name))
            }
        } else if let stem = splitGGUFStem(of: (path as NSString).lastPathComponent),
                  let dir = try? fm.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent) {
            let parent = (path as NSString).deletingLastPathComponent
            for name in dir where splitGGUFStem(of: name) == stem {
                total += size((parent as NSString).appendingPathComponent(name))
            }
        } else {
            total = size(path)
        }
        return total > 0 ? total : nil
    }

    // The model a split GGUF part belongs to: NAME from NAME-00001-of-00003.gguf; nil for a
    // whole file (install/local.py's SPLIT_NAME rule, same shape as its part naming).
    private static func splitGGUFStem(of name: String) -> String? {
        guard let r = name.range(of: #"-\d+-of-\d+\.gguf$"#, options: .regularExpression)
        else { return nil }
        return String(name[..<r.lowerBound])
    }

    // Sums the real bytes under a directory, following symlinks. The Splash model path is a
    // symlink into the HF snapshot and its files are symlinks into the content-addressed blob
    // store, so the default enumerator (which treats symlinks as non-regular) sees nothing.
    // Resolving each path and deduping by resolved URL counts each shared blob exactly once.
    static func directorySize(_ url: URL) -> Int? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let root = url.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
        var seen = Set<URL>()
        var total = 0
        for case let file as URL in enumerator {
            let real = file.resolvingSymlinksInPath()
            guard let vals = try? real.resourceValues(forKeys: Set(keys)) else { continue }
            guard vals.isRegularFile == true else { continue }
            if !seen.insert(real).inserted { continue }
            total += vals.fileSize ?? 0
        }
        return total > 0 ? total : nil
    }

    // Computes run settings for a model from this Mac's GPU wired-memory ceiling. Pure: no
    // process, no UI. weightsBytes overrides the on-disk lookup (e.g. a catalog estimate
    // before the model has downloaded). Returns nil when the model can't be sized confidently.
    // Keys on the Metal ceiling, NOT free RAM: macOS keeps RAM resident and evicts on demand,
    // so availableRAM sits ~50-60% "used" at idle and would spuriously collapse the pick.
    static func autoProfile(modelID: String, languageOnly: Bool, weightsBytes: Int? = nil) -> AutoProfile? {
        // Auto's KV-per-token and window constants were measured on the Qwen3.8-27B arch; other
        // archs return nil here and the engine sizes itself.
        guard CatalogModel.catalog.first(where: { $0.id == modelID })?.qwen27BArch == true else { return nil }
        let weights = weightsBytes ?? weightsSize(for: modelID)
        guard let weights else { return nil }
        let maxMemory = metalMaxWorkingSet  // hard GPU wired ceiling; already reserves ~22% for the OS
        let engineFixed = 1_610_612_736  // 1.5 GiB: engine buffers + native MTP draft
        let vision = languageOnly ? 0 : 536_870_912  // 0.5 GiB: vision projector
        let budget = maxMemory - weights - engineFixed - vision
        guard budget > 0 else { return nil }
        let window = CatalogModel.windowTokens
        func context(_ bytesPerToken: Int) -> Int {
            let capped = min(budget / bytesPerToken, window)
            return (capped / 32_768) * 32_768
        }
        // One KV constant for the 27B arch (67 KiB/token BF16, half for INT8).
        let bf16 = context(68_608)
        if bf16 >= 32_768 {
            return AutoProfile(maxMemoryBytes: maxMemory, contextTokens: bf16, kvFormat: "bf16")
        }
        let int8 = context(34_304)
        guard int8 >= 32_768 else { return nil }
        return AutoProfile(maxMemoryBytes: maxMemory, contextTokens: int8, kvFormat: "int8")
    }

    static func gb(_ bytes: Int?) -> String {
        guard let bytes else { return "–" }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // Full-precision byte format (GB / MB / KB / B) for size displays.
    static func bytesText(_ bytes: Int?) -> String {
        guard let bytes else { return "–" }
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1e6) }
        if bytes >= 1_000 { return "\(bytes / 1000) KB" }
        return "\(bytes) B"
    }

    // The host a client dials: the LAN address when Serve on LAN is on (falling back to
    // loopback while none is leased), loopback otherwise.
    static func effectiveHost(lanEnabled: Bool) -> String {
        lanEnabled ? (lanIPv4Address ?? "127.0.0.1") : "127.0.0.1"
    }
}

struct AutoProfile: Equatable {
    let maxMemoryBytes: Int
    let contextTokens: Int
    let kvFormat: String
}
import Foundation

// The persistent SSD tier: the engine writes its KV pages and GDN states here when
// --persistent-cache is on (~/Library/Caches/Splash/prefix-cache/<namespace>/). The app has
// no flag to clear it, so a manual clear deletes the contents. Safe only while the server
// is stopped — the engine holds the files open.
enum SSDCache {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Splash/prefix-cache", isDirectory: true)
    }

    // Allocated bytes of the persistent cache, split by what the engine writes: KV pages (kv.*)
    // and GDN states (state.*). Allocated, never logical — the slot files are sparse, so a 29 GB
    // KV arena can occupy 7.5 GB on the volume; logical sizes would overstate the disk cost.
    struct Usage {
        let kv: Int
        let states: Int
        let total: Int
    }

    static func usage(_ url: URL = directory) -> Usage {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return Usage(kv: 0, states: 0, total: 0)
        }
        var kv = 0, states = 0, total = 0
        for case let file as URL in enumerator {
            guard let size = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize else { continue }
            total += size
            let name = file.lastPathComponent
            if name.hasPrefix("kv.") { kv += size }
            if name.hasPrefix("state.") { states += size }
        }
        return Usage(kv: kv, states: states, total: total)
    }

    static func clear() throws {
        let fm = FileManager.default
        let root = directory
        guard fm.fileExists(atPath: root.path) else { return }
        for child in try fm.contentsOfDirectory(atPath: root.path) {
            try fm.removeItem(at: root.appendingPathComponent(child))
        }
    }
}

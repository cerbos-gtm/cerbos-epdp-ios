import Foundation

/// Stores the latest Hub `GetBundle` response per cache key, as received, so the PDP can start
/// offline. The bridge replays it only when the initial download fails.
public actor PolicyBundleCache {
    public struct Entry: Sendable, Codable, Equatable {
        public var key: String
        public var bundleId: String
        public var ruleRevision: String
        public var savedAt: Date
        public var byteCount: Int
    }

    public let directory: URL

    /// - Parameter directory: Where to store bundles. Defaults to ``defaultDirectory()``.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    /// `Application Support/CerbosEmbeddedPDP/policy-bundles`. On macOS the bundle identifier is
    /// added, because non-sandboxed apps share Application Support and ``removeAll()`` would clear theirs.
    public static func defaultDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var directory = base.appendingPathComponent("CerbosEmbeddedPDP", isDirectory: true)
        #if os(macOS)
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            directory.appendPathComponent(bundleIdentifier, isDirectory: true)
        }
        #endif
        return directory.appendingPathComponent("policy-bundles", isDirectory: true)
    }

    /// Returns the cached response for the key, or `nil` if there is none. Corrupt entries are removed.
    public func load(key: String) -> (entry: Entry, body: Data)? {
        let files = fileURLs(for: key)
        guard let entryData = try? Data(contentsOf: files.entry),
            let entry = try? JSONDecoder().decode(Entry.self, from: entryData),
            entry.key == key,
            let body = try? Data(contentsOf: files.body),
            body.count == entry.byteCount
        else {
            remove(key: key)
            return nil
        }
        return (entry, body)
    }

    @discardableResult
    public func save(key: String, body: Data, bundleId: String, ruleRevision: String) throws -> Entry {
        let entry = Entry(key: key, bundleId: bundleId, ruleRevision: ruleRevision, savedAt: Date(), byteCount: body.count)
        let files = fileURLs(for: key)
        do {
            try ensureDirectory()
            try body.write(to: files.body, options: .atomic)
            try JSONEncoder().encode(entry).write(to: files.entry, options: .atomic)
        } catch {
            throw CerbosError.cache(reason: String(describing: error))
        }
        return entry
    }

    public func remove(key: String) {
        let files = fileURLs(for: key)
        try? FileManager.default.removeItem(at: files.body)
        try? FileManager.default.removeItem(at: files.entry)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    public func entries() -> [Entry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } }
            .sorted { $0.savedAt > $1.savedAt }
    }

    private func ensureDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
        #endif
    }

    private func fileURLs(for key: String) -> (body: URL, entry: URL) {
        let name = Self.fileName(for: key)
        return (
            directory.appendingPathComponent(name + ".bundle"),
            directory.appendingPathComponent(name + ".json")
        )
    }

    /// Stable, filesystem-safe name for a cache key (FNV-1a 64-bit).
    static func fileName(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

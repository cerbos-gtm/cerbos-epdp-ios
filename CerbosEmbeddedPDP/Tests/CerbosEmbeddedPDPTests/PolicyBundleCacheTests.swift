import Foundation
import Testing

@testable import CerbosEmbeddedPDP

@Suite("PolicyBundleCache")
struct PolicyBundleCacheTests {
    private func makeCache() -> PolicyBundleCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cerbos-cache-tests-\(UUID().uuidString)", isDirectory: true)
        return PolicyBundleCache(directory: directory)
    }

    @Test func saveLoadRemove() async throws {
        let cache = makeCache()
        defer { Task { await cache.removeAll() } }
        let key = "https://api.cerbos.cloud|RULE|"
        let body = Data((0..<1024).map { UInt8($0 % 251) })

        #expect(await cache.load(key: key) == nil)

        let entry = try await cache.save(key: key, body: body, bundleId: "B1", ruleRevision: "7")
        #expect(entry.byteCount == 1024)

        let loaded = try #require(await cache.load(key: key))
        #expect(loaded.body == body)
        #expect(loaded.entry.bundleId == "B1")
        #expect(loaded.entry.ruleRevision == "7")
        #expect(await cache.entries().map(\.key) == [key])

        // A different key is isolated.
        #expect(await cache.load(key: key + "other") == nil)

        // Overwrite keeps the latest.
        try await cache.save(key: key, body: Data([1, 2, 3]), bundleId: "B2", ruleRevision: "8")
        #expect(await cache.load(key: key)?.entry.bundleId == "B2")
        #expect(await cache.entries().count == 1)

        await cache.remove(key: key)
        #expect(await cache.load(key: key) == nil)
    }

    @Test func corruptEntriesAreDiscarded() async throws {
        let cache = makeCache()
        defer { Task { await cache.removeAll() } }
        let key = "k"
        try await cache.save(key: key, body: Data(repeating: 7, count: 100), bundleId: "B", ruleRevision: "1")

        // Truncate the body behind the cache's back.
        let bodyURL = await cache.directory.appendingPathComponent(PolicyBundleCache.fileName(for: key) + ".bundle")
        try Data(repeating: 7, count: 10).write(to: bodyURL)

        #expect(await cache.load(key: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path), "corrupt entries are removed")
    }

    @Test func fileNamesAreStableAndSafe() {
        let name = PolicyBundleCache.fileName(for: "https://api.cerbos.cloud|AVGB9RP6HFBL|a,b")
        #expect(name == PolicyBundleCache.fileName(for: "https://api.cerbos.cloud|AVGB9RP6HFBL|a,b"))
        #expect(name != PolicyBundleCache.fileName(for: "https://api.cerbos.cloud|AVGB9RP6HFBL|a"))
        #expect(name.allSatisfy { $0.isHexDigit })
    }
}

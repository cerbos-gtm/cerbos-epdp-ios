#if os(macOS) && canImport(WebKit)
import CerbosEmbeddedPDP
import Foundation
import Testing

/// Exercises the whole stack in the package test process on macOS: the hidden web view, the URL scheme
/// handler streaming `server.wasm` into WebKit, the JavaScript bridge, a real policy bundle from
/// Cerbos Hub, decisions, and the offline replay of the cached bundle.
///
/// Requires network access to `api.cerbos.cloud`. Override the rule with `CERBOS_RULE_ID`.
@Suite("Embedded PDP integration", .serialized)
@MainActor
struct EmbeddedPDPIntegrationTests {
    static let ruleId = ProcessInfo.processInfo.environment["CERBOS_RULE_ID"] ?? "AVGB9RP6HFBL"

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cerbos-epdp-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private static let request = CheckResourcesRequest(
        principal: Principal(id: "alice@example.com", roles: ["USER"], attributes: ["tier": "PREMIUM"]),
        resources: [
            ResourceCheck(
                resource: Resource(kind: "resource", id: "1", attributes: ["ownerId": "alice@example.com"]), actions: ["read", "update"]),
            ResourceCheck(
                resource: Resource(kind: "resource", id: "2", attributes: ["ownerId": "someone-else@example.com"]), actions: ["read"]),
        ],
        includeMetadata: true
    )

    @Test("starts from Hub, evaluates checks, then restarts offline from the cache", .timeLimit(.minutes(5)))
    func onlineStartThenOfflineReplay() async throws {
        let cacheDirectory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = PolicyBundleCache(directory: cacheDirectory)

        var configuration = CerbosEmbeddedPDP.Configuration(ruleId: Self.ruleId)
        configuration.updateInterval = nil

        // 1. Online start: WASM compiled by WebKit, bundle downloaded from Cerbos Hub.
        let online = CerbosEmbeddedPDP(configuration: configuration, cache: cache)
        await online.start()
        guard online.status == .ready else {
            Issue.record("online start failed: \(online.status); logs: \(online.logs.map(\.message))")
            return
        }
        let onlineBundle = try #require(online.bundle)
        #expect(onlineBundle.source == .network)
        #expect(!onlineBundle.bundleId.isEmpty)
        #expect(online.server?.version.isEmpty == false)

        // 2. Decisions are evaluated locally and come back well-formed.
        let response = try await online.checkResources(Self.request)
        #expect(response.results.count == 2)
        #expect(response.results.map(\.resource.id) == ["1", "2"])
        #expect(Set(response.results[0].actions.keys) == ["read", "update"])
        #expect(response.results[0].metadata != nil, "includeMetadata was requested")

        let allowed = try await online.isAllowed(
            principal: Self.request.principal,
            resource: Self.request.resources[0].resource,
            action: "read"
        )
        #expect(allowed == response.results[0].isAllowed("read"))

        let plan = try await online.planResources(
            PlanResourcesRequest(principal: Self.request.principal, resource: PlanResource(kind: "resource"), action: "read")
        )
        #expect([PlanKind.alwaysAllowed, .alwaysDenied, .conditional].contains(plan.kind))

        // 3. The bundle was persisted for offline starts (the cache write is asynchronous).
        let onlineKey = online.offlineCacheKey
        var cached = await cache.load(key: onlineKey)
        for _ in 0..<50 where cached == nil {
            try await Task.sleep(for: .milliseconds(200))
            cached = await cache.load(key: onlineKey)
        }
        let cachedEntry = try #require(cached, "policy bundle was not written to the offline cache")
        #expect(cachedEntry.entry.bundleId == onlineBundle.bundleId)
        online.stop()

        // 4. Offline start: Hub is unreachable, the cached bundle is replayed.
        var offlineConfiguration = configuration
        offlineConfiguration.hubBaseURL = URL(string: "http://127.0.0.1:9")!
        let offline = CerbosEmbeddedPDP(configuration: offlineConfiguration, cache: cache)
        // The cache key includes the Hub URL; seed the entry for the unreachable one.
        try await cache.save(
            key: offline.offlineCacheKey,
            body: cachedEntry.body,
            bundleId: cachedEntry.entry.bundleId,
            ruleRevision: cachedEntry.entry.ruleRevision
        )
        await offline.start()
        guard offline.status == .ready else {
            Issue.record("offline start failed: \(offline.status); logs: \(offline.logs.map(\.message))")
            return
        }
        #expect(offline.bundle?.source == .cache)
        #expect(offline.bundle?.bundleId == onlineBundle.bundleId)
        let offlineResponse = try await offline.checkResources(Self.request)
        #expect(offlineResponse.results.map(\.actions) == response.results.map(\.actions))
        offline.stop()

        // 5. Offline start without a cached bundle fails cleanly instead of hanging.
        let uncached = CerbosEmbeddedPDP(
            configuration: offlineConfiguration, cache: PolicyBundleCache(directory: Self.temporaryDirectory()))
        await uncached.start()
        guard case .failed(let error) = uncached.status else {
            Issue.record("expected the uncached offline start to fail, got \(uncached.status)")
            return
        }
        #expect(!error.localizedDescription.isEmpty)
        await #expect(throws: CerbosError.notReady) {
            _ = try await uncached.checkResources(Self.request)
        }
    }
}
#endif

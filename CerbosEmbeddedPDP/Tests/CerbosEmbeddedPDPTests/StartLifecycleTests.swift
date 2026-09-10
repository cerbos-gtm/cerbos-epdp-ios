#if canImport(WebKit)
import CerbosEmbeddedPDP
import Foundation
import Testing

/// Lifecycle calls that interrupt a start in progress. Requires network access to `api.cerbos.cloud`.
@Suite("Embedded PDP start lifecycle", .serialized)
@MainActor
struct StartLifecycleTests {
    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cerbos-epdp-lifecycle-\(UUID().uuidString)", isDirectory: true)
    }

    private static func configuration() -> CerbosEmbeddedPDP.Configuration {
        var configuration = CerbosEmbeddedPDP.Configuration(ruleId: EmbeddedPDPIntegrationTests.ruleId)
        configuration.updateInterval = nil
        return configuration
    }

    /// Starts in the background and returns once the attempt is under way.
    private static func startInBackground(_ pdp: CerbosEmbeddedPDP) async throws -> Task<Void, Never> {
        let task = Task { await pdp.start() }
        for _ in 0..<100 where pdp.status != .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pdp.status == .loading)
        // Let the attempt get past loading the page and into compiling the engine or downloading the bundle.
        try await Task.sleep(for: .milliseconds(400))
        return task
    }

    @Test("restart() during a start replaces the attempt instead of joining it", .timeLimit(.minutes(5)))
    func restartDuringStart() async throws {
        let cacheDirectory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let pdp = CerbosEmbeddedPDP(configuration: Self.configuration(), cache: PolicyBundleCache(directory: cacheDirectory))

        let original = try await Self.startInBackground(pdp)
        await pdp.restart()
        #expect(pdp.status == .ready, "restart during loading ended \(pdp.status); logs: \(pdp.logs.map(\.message))")

        // The superseded attempt must not publish anything once it winds down.
        await original.value
        #expect(pdp.status == .ready)
        let allowed = try await pdp.isAllowed(
            principal: Principal(id: "alice@example.com", roles: ["USER"]),
            resource: Resource(kind: "resource", id: "1"),
            action: "read"
        )
        _ = allowed
        pdp.stop()
    }

    @Test("reconfigure() during a start makes the new configuration the one that runs", .timeLimit(.minutes(5)))
    func reconfigureDuringStart() async throws {
        let cacheDirectory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        // Start against a Hub address that does not answer (a non-routable address, so the connection
        // hangs until `initialLoadTimeout` rather than being refused). Nothing is cached for it.
        var unreachable = Self.configuration()
        unreachable.hubBaseURL = URL(string: "https://10.255.255.1")!
        unreachable.initialLoadTimeout = .seconds(15)
        let pdp = CerbosEmbeddedPDP(configuration: unreachable, cache: PolicyBundleCache(directory: cacheDirectory))
        let original = try await Self.startInBackground(pdp)
        // Give the stalled attempt time to get past compiling the engine and into its bundle download.
        try await Task.sleep(for: .seconds(1))

        // Switching to the real Hub must not wait for, or inherit the outcome of, the stalled attempt.
        let reconfigureStart = ContinuousClock.now
        await pdp.reconfigure(Self.configuration())
        #expect(pdp.configuration.hubBaseURL == nil)
        #expect(pdp.status == .ready, "reconfigure during a stalled start ended \(pdp.status); logs: \(pdp.logs.map(\.message))")
        #expect(pdp.bundle?.source == .network)
        #expect(ContinuousClock.now - reconfigureStart < .seconds(10), "reconfigure waited for the superseded attempt")

        // The superseded attempt keeps winding down in the background (its stalled download is only
        // released by the network timeout); whatever it does, it must not disturb the published state.
        try await Task.sleep(for: .seconds(2))
        #expect(pdp.status == .ready)
        #expect(pdp.bundle?.source == .network)
        original.cancel()
        pdp.stop()
    }
}
#endif

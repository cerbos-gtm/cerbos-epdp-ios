#if canImport(WebKit)
import CerbosEmbeddedPDP
import Foundation
import Testing

/// End-to-end `checkResources` latency from Swift, including the web view round trip. Opt-in (needs
/// Hub, slow): `CERBOS_BENCH=1 swift test --filter DecisionLatencyBenchmark`.
@Suite("Decision latency benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CERBOS_BENCH"] != nil))
@MainActor
struct DecisionLatencyBenchmark {
    static let iterations = Int(ProcessInfo.processInfo.environment["CERBOS_BENCH_ITERATIONS"] ?? "") ?? 1000

    static let principal = Principal(id: "alice@example.com", roles: ["USER"], attributes: ["tier": "PREMIUM"])
    static let demo = CheckResourcesRequest(
        principal: principal,
        resources: [
            ResourceCheck(
                resource: Resource(kind: "resource", id: "1", attributes: ["ownerId": "alice@example.com"]),
                actions: ["read", "create", "update", "delete", "publish"])
        ],
        includeMetadata: true
    )
    static let batch = CheckResourcesRequest(
        principal: principal,
        resources: (0..<50).map { i in
            ResourceCheck(
                resource: Resource(
                    kind: "resource", id: String(i), attributes: ["ownerId": .string(i % 2 == 0 ? "bob@example.com" : "alice@example.com")]),
                actions: ["read", "create", "update", "delete", "publish"])
        }
    )

    @Test(.timeLimit(.minutes(10)))
    func checkResourcesRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cerbos-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = CerbosEmbeddedPDP.Configuration(ruleId: EmbeddedPDPIntegrationTests.ruleId)
        configuration.updateInterval = nil
        let pdp = CerbosEmbeddedPDP(configuration: configuration, cache: PolicyBundleCache(directory: directory))
        let clock = ContinuousClock()
        let startBegan = clock.now
        await pdp.start()
        try #require(pdp.status == .ready, "start failed: \(pdp.status)")
        print("start: \(clock.now - startBegan)")
        let firstBegan = clock.now
        _ = try await pdp.checkResources(Self.demo)
        print("BENCH first checkResources after start: \(clock.now - firstBegan)")

        try await measure("status (IPC floor)") { _ = await pdp.checkHealth() }
        try await measure("checkResources (demo)") { _ = try await pdp.checkResources(Self.demo) }
        try await measure("isAllowed") {
            _ = try await pdp.isAllowed(principal: Self.principal, resource: Self.demo.resources[0].resource, action: "read")
        }
        try await measure("checkResources (50 x 5)") { _ = try await pdp.checkResources(Self.batch) }
        try await measure("8 concurrent isAllowed") {
            let tasks = (0..<8).map { _ in
                Task { @MainActor in
                    try await pdp.isAllowed(principal: Self.principal, resource: Self.demo.resources[0].resource, action: "read")
                }
            }
            for task in tasks { _ = try await task.value }
        }
        pdp.stop()
    }

    private func measure(_ name: String, _ body: () async throws -> Void) async throws {
        for _ in 0..<100 { try await body() }
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(Self.iterations)
        for _ in 0..<Self.iterations {
            let start = clock.now
            try await body()
            let elapsed = (clock.now - start).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        samples.sort()
        func at(_ q: Double) -> String { String(format: "%.3f", samples[min(samples.count - 1, Int(q * Double(samples.count)))]) }
        print("BENCH \(name.padding(toLength: 28, withPad: " ", startingAt: 0)) p50 \(at(0.5)) ms  p90 \(at(0.9)) ms  p99 \(at(0.99)) ms")
    }
}
#endif

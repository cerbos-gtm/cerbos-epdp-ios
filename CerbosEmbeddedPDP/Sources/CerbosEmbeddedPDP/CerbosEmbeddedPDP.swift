#if canImport(WebKit)
import Foundation
import Observation

/// An embedded Cerbos policy decision point for iOS and macOS.
///
/// Runs `@cerbos/embedded-client` and the Cerbos WebAssembly engine in a hidden web view, with
/// policy bundles from Cerbos Hub updated in the background and cached on disk for offline starts.
///
/// ```swift
/// let pdp = CerbosEmbeddedPDP(configuration: .init(ruleId: "AVGB9RP6HFBL"))
/// await pdp.start()
/// let allowed = try await pdp.isAllowed(principal: alice, resource: document, action: "view")
/// ```
@MainActor
@Observable
public final class CerbosEmbeddedPDP {

    // MARK: Configuration

    public struct HubCredentials: Sendable, Equatable {
        public var clientId: String
        public var clientSecret: String

        public init(clientId: String, clientSecret: String) {
            self.clientId = clientId
            self.clientSecret = clientSecret
        }
    }

    /// Schema enforcement level for inputs (see the Cerbos schema documentation).
    public enum SchemaEnforcement: String, Sendable {
        case none, warn, reject
    }

    public enum ValidationErrorHandling: String, Sendable {
        /// Validation errors are only included in results.
        case ignore
        /// Validation errors are also delivered to `Configuration.onValidationErrors`.
        case report
        /// Checks with validation errors fail with ``CerbosError/request(_:)``.
        case throwError = "throw"
    }

    public struct Configuration: Sendable {
        /// ID of the embedded PDP rule from the deployment's "Embedded PDP rules" tab in Cerbos Hub.
        public var ruleId: String
        /// Scopes to request when the rule requires (or allows) scoped bundles.
        public var scopes: [String] = []
        /// Cerbos Hub API base URL, defaulting to `https://api.cerbos.cloud`. Must be `https` (plain
        /// `http` only for localhost), as the bridge page's Content Security Policy blocks the rest.
        public var hubBaseURL: URL? = nil
        /// Client credentials for rules that require authentication. Keep them out of source control.
        public var credentials: HubCredentials? = nil
        /// How often to check Hub for policy updates. `nil` disables polling. Minimum 10 seconds.
        public var updateInterval: Duration? = .seconds(60)
        /// Whether downloaded updates replace the active bundle immediately (otherwise call ``activatePendingBundle()``).
        public var activateOnLoad = true
        /// Upper bound for each phase of `start()`: loading the page, then compiling the engine and
        /// downloading the first bundle.
        public var startTimeout: Duration = .seconds(120)
        /// Upper bound for a single check or plan. Evaluation takes milliseconds; this only fires on a stuck engine.
        public var requestTimeout: Duration = .seconds(30)
        /// Aborts a stalled first bundle download so the offline cache can be used. Minimum 1 second.
        public var initialLoadTimeout: Duration = .seconds(20)
        /// When a check fails because the web content process died, rebuild it and retry the check once.
        public var retryAfterRecovery = true
        /// Automatic rebuilds allowed per `restartWindow`. Once exhausted, recovery waits for
        /// ``start()``, ``restart()`` or ``reconfigure(_:)``.
        public var maximumRestarts = 3
        public var restartWindow: Duration = .seconds(600)

        public var defaultPolicyVersion: String? = nil
        public var defaultScope: String? = nil
        public var globals: [String: JSONValue] = [:]
        public var lenientScopeSearch = false
        public var schemaEnforcement: SchemaEnforcement = .none
        public var strictEvaluation = false
        public var userAgent: String? = nil
        /// Extra headers sent with Hub requests.
        public var headers: [String: String] = [:]
        public var validationErrors: ValidationErrorHandling = .ignore

        /// Persist the latest policy bundle so the PDP can start without connectivity.
        public var offlineCache = true

        /// Receives decision log entries (same shape as the JavaScript SDK's `DecisionLogEntry`).
        public var onDecision: (@Sendable (JSONValue) -> Void)? = nil
        /// Receives validation errors when `validationErrors` is `.report`.
        public var onValidationErrors: (@Sendable ([ValidationError]) -> Void)? = nil
        /// Verifies and decodes JWTs passed as auxiliary data. Required to use `AuxData.jwt`.
        public var jwtDecoder: (@Sendable (JWT) async throws -> [String: JSONValue])? = nil

        public init(ruleId: String) {
            self.ruleId = ruleId
        }
    }

    public enum Status: Sendable, Equatable, CustomStringConvertible {
        case idle
        case loading
        case ready
        case failed(CerbosError)

        public var description: String {
            switch self {
            case .idle: return "idle"
            case .loading: return "loading"
            case .ready: return "ready"
            case .failed(let error): return "failed: \(error.localizedDescription)"
            }
        }
    }

    public struct LogLine: Sendable, Identifiable, Equatable {
        public let id = UUID()
        public var date: Date
        public var level: String
        public var message: String
    }

    // MARK: Observable state

    public private(set) var configuration: Configuration
    public private(set) var status: Status = .idle
    /// The policy bundle decisions are currently evaluated against.
    public private(set) var bundle: BundleInfo?
    /// A newer bundle that has been downloaded but not activated (only when `Configuration.activateOnLoad` is `false`).
    public private(set) var pendingBundle: BundleInfo?
    /// Build information of the bundled WebAssembly server.
    public private(set) var server: ServerInfo?
    /// Outcome of the most recent background update check.
    public private(set) var lastPolicyUpdate: PolicyUpdate?
    /// Recent diagnostics from the bridge (warnings, errors, cache activity). Capped at 100 lines.
    public private(set) var logs: [LogLine] = []

    public var isReady: Bool { status == .ready }

    /// Key under which this configuration's policy bundle is cached. Matches the bridge's key.
    public var offlineCacheKey: String {
        // Keep in sync with `bundleCacheKey` in CerbosBridge/src/core.ts.
        var baseURL = configuration.hubBaseURL?.absoluteString ?? "https://api.cerbos.cloud"
        while baseURL.hasSuffix("/") {
            baseURL.removeLast()
        }
        return [
            baseURL,
            configuration.ruleId.trimmingCharacters(in: .whitespacesAndNewlines),
            configuration.scopes.sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    @ObservationIgnored private let host: CerbosWebViewHost
    @ObservationIgnored private let cache: PolicyBundleCache
    @ObservationIgnored private let resourcesError: CerbosError?
    /// Bumped by `stop()`, `reconfigure(_:)` and content process termination. A start attempt from an
    /// older generation abandons itself instead of publishing its outcome.
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startTaskGeneration = 0
    /// The generation under which `status` last became `.ready`.
    @ObservationIgnored private var readyGeneration: Int?
    @ObservationIgnored private var restartTimes: [Date] = []

    // MARK: Lifecycle

    /// - Parameters:
    ///   - configuration: Rule, Hub and engine settings.
    ///   - cache: Where policy bundles are persisted for offline starts.
    public init(configuration: Configuration, cache: PolicyBundleCache = PolicyBundleCache()) {
        self.configuration = configuration
        self.cache = cache
        var directory = URL(fileURLWithPath: "/dev/null")
        var resourcesError: CerbosError?
        do {
            directory = try CerbosWebViewHost.bundledResourcesDirectory()
        } catch {
            resourcesError = error
        }
        self.resourcesError = resourcesError
        self.host = CerbosWebViewHost(resourcesDirectory: directory)
        host.onEvent = { [weak self] event in self?.handle(event) }
        host.onProcessTerminated = { [weak self] in self?.handleProcessTermination() }
    }

    /// Loads the engine and the policy bundle. Idempotent; concurrent callers share one attempt.
    /// Call again after a failure to retry, which also resets the automatic restart budget.
    public func start() async {
        restartTimes.removeAll()
        await startIfNeeded()
    }

    /// Joins the in-flight start when it is still valid, otherwise launches a new attempt unless the
    /// PDP is already ready under the current generation.
    private func startIfNeeded() async {
        // An attempt that stop(), reconfigure(_:) or a process termination invalidated is left to
        // abandon itself (it may be blocked on the old web view) and is not waited for.
        while let inFlight = startTask, startTaskGeneration == startGeneration {
            await inFlight.value
        }
        if status == .ready, readyGeneration == startGeneration {
            return
        }
        let generation = startGeneration
        let task = Task { @MainActor in
            await self.performStart(generation: generation)
            if self.startTaskGeneration == generation {
                self.startTask = nil
            }
        }
        startTask = task
        startTaskGeneration = generation
        await task.value
    }

    /// Applies a new configuration, reusing the compiled engine (much cheaper than ``restart()``).
    /// Supersedes any start still in progress.
    public func reconfigure(_ configuration: Configuration) async {
        self.configuration = configuration
        startGeneration += 1
        restartTimes.removeAll()
        await startIfNeeded()
    }

    /// Discards the current web view and starts again from scratch, recompiling the engine.
    public func restart() async {
        stop()
        await start()
    }

    /// Checks the web content process is still answering and rebuilds it if not. Call it when the app
    /// returns to the foreground, since WebKit may discard the process while the app is suspended.
    /// - Returns: `true` when the PDP is ready after the check.
    @discardableResult
    public func checkHealth() async -> Bool {
        switch status {
        case .ready:
            do {
                let _: BridgeStatusResult = try await host.invoke("status", timeout: .seconds(5), failure: { .initialisation($0) })
                return true
            } catch {
                appendLog(level: "warn", "Health check failed (\(error.localizedDescription)); rebuilding the web view")
                stop()
                await startIfNeeded()
                return status == .ready
            }
        case .failed:
            await startIfNeeded()
            return status == .ready
        case .idle, .loading:
            return false
        }
    }

    /// Stops update polling and releases the web view. `start()` brings the PDP back.
    public func stop() {
        startGeneration += 1
        host.shutdown()
        status = .idle
        bundle = nil
        pendingBundle = nil
    }

    /// Activates a downloaded-but-pending bundle when `Configuration.activateOnLoad` is `false`.
    public func activatePendingBundle() async throws(CerbosError) {
        let _: BridgeIgnoredResult = try await host.invoke("activate", timeout: configuration.requestTimeout, failure: { .request($0) })
    }

    /// Removes the cached policy bundle for this configuration.
    public func clearOfflineCache() async {
        await cache.remove(key: offlineCacheKey)
    }

    // MARK: Checks

    public func checkResources(_ request: CheckResourcesRequest) async throws(CerbosError) -> CheckResourcesResponse {
        try await perform("checkResources", params: request)
    }

    public func checkResource(_ request: CheckResourceRequest) async throws(CerbosError) -> CheckResult {
        try await perform("checkResource", params: request)
    }

    public func isAllowed(_ request: IsAllowedRequest) async throws(CerbosError) -> Bool {
        try await perform("isAllowed", params: request)
    }

    public func isAllowed(
        principal: Principal, resource: Resource, action: String, auxData: AuxData? = nil
    ) async throws(CerbosError) -> Bool {
        try await isAllowed(IsAllowedRequest(principal: principal, resource: resource, action: action, auxData: auxData))
    }

    public func planResources(_ request: PlanResourcesRequest) async throws(CerbosError) -> PlanResourcesResponse {
        try await perform("planResources", params: request)
    }

    // MARK: Internals

    /// Runs a bridge call, and if the web content process died underneath it, rebuilds once and retries.
    private func perform<Result: Decodable>(_ method: String, params: some Encodable) async throws(CerbosError) -> Result {
        try ensureReady()
        do {
            return try await host.invoke(method, params: params, timeout: configuration.requestTimeout, failure: { .request($0) })
        } catch {
            guard error.isWebViewFailure, configuration.retryAfterRecovery else {
                throw error
            }
            appendLog(
                level: "warn", "\(method) failed because the web view is gone (\(error.localizedDescription)); recovering and retrying once"
            )
            // Rebuild even if the termination notice has not arrived yet; if it has, the host already
            // knows the bridge is gone and this joins the restart it triggered.
            if host.isBridgeReady {
                stop()
            }
            await startIfNeeded()
            try ensureReady()
            return try await host.invoke(method, params: params, timeout: configuration.requestTimeout, failure: { .request($0) })
        }
    }

    private func ensureReady() throws(CerbosError) {
        guard status == .ready else {
            throw CerbosError.notReady
        }
    }

    /// One start attempt. After every suspension it checks `generation` is still current before touching state.
    private func performStart(generation: Int) async {
        if let resourcesError {
            status = .failed(resourcesError)
            return
        }
        if let error = Self.validate(hubBaseURL: configuration.hubBaseURL) {
            status = .failed(error)
            return
        }
        status = .loading
        do {
            try await host.start(timeout: configuration.startTimeout)
            guard generation == startGeneration else { return }

            var cachedBundle: BridgeInitParams.CachedBundle?
            if configuration.offlineCache, let cached = await cache.load(key: offlineCacheKey) {
                cachedBundle = .init(key: offlineCacheKey, body: cached.body.base64EncodedString())
                appendLog(level: "info", "Offline cache has bundle \(cached.entry.bundleId) from \(cached.entry.savedAt)")
            }
            guard generation == startGeneration else { return }

            let result: BridgeInitResult = try await host.invoke(
                "init",
                params: initParams(cachedBundle: cachedBundle),
                timeout: configuration.startTimeout,
                failure: { CerbosError.initialisationFailure($0) }
            )
            guard generation == startGeneration else { return }
            bundle = result.bundle
            pendingBundle = result.pending
            server = result.server
            status = .ready
            readyGeneration = generation
            CerbosLog.info(
                "Cerbos embedded PDP ready (bundle \(result.bundle?.bundleId ?? "?"), source \(result.bundle?.source.rawValue ?? "?"))")
        } catch {
            guard generation == startGeneration else {
                // Superseded by stop(), reconfigure(_:) or a restart; that attempt reports its own outcome.
                return
            }
            CerbosLog.error("Cerbos embedded PDP failed to start: \(error.localizedDescription)")
            status = .failed(error)
        }
    }

    /// Rejects URLs the page's Content Security Policy would block (anything but `https:` and loopback
    /// `http:`), giving a clear configuration error instead of an opaque network failure.
    nonisolated static func validate(hubBaseURL url: URL?) -> CerbosError? {
        guard let url else { return nil }
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else {
            return .invalidRequest(reason: "hubBaseURL \(url.absoluteString) must be an absolute https URL")
        }
        switch scheme {
        case "https":
            return nil
        case "http" where ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host):
            return nil
        default:
            return .invalidRequest(
                reason: "hubBaseURL \(url.absoluteString) must use https (plain http is only allowed for localhost)")
        }
    }

    /// Whole-duration conversion; `Duration.components.seconds` alone truncates sub-second values to zero.
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func initParams(cachedBundle: BridgeInitParams.CachedBundle?) -> BridgeInitParams {
        let configuration = configuration
        let intervalSeconds: Double
        if let interval = configuration.updateInterval {
            intervalSeconds = max(10, Self.seconds(interval))
        } else {
            intervalSeconds = 0
        }
        return BridgeInitParams(
            ruleId: configuration.ruleId.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: configuration.scopes,
            hub: .init(
                baseUrl: configuration.hubBaseURL?.absoluteString,
                clientId: configuration.credentials?.clientId,
                clientSecret: configuration.credentials?.clientSecret
            ),
            updateIntervalSeconds: intervalSeconds,
            activateOnLoad: configuration.activateOnLoad,
            // Zero means "no timeout" in the bridge, so never let a short duration round down to it.
            initialLoadTimeoutSeconds: max(1, Self.seconds(configuration.initialLoadTimeout)),
            options: .init(
                defaultPolicyVersion: configuration.defaultPolicyVersion,
                defaultScope: configuration.defaultScope,
                globals: configuration.globals.isEmpty ? nil : configuration.globals,
                lenientScopeSearch: configuration.lenientScopeSearch,
                schemaEnforcement: configuration.schemaEnforcement.rawValue,
                strictEvaluation: configuration.strictEvaluation,
                userAgent: configuration.userAgent,
                headers: configuration.headers.isEmpty ? nil : configuration.headers,
                onValidationError: configuration.validationErrors == .ignore ? nil : configuration.validationErrors.rawValue
            ),
            emitDecisions: configuration.onDecision != nil,
            jwtDecoding: configuration.jwtDecoder != nil,
            cachedBundle: cachedBundle
        )
    }

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .bridgeReady:
            break

        case .status(let bridgeStatus, let error):
            // `init` reports its own outcome; this covers failures after it.
            if bridgeStatus == .failed, status == .ready, let error {
                status = .failed(.initialisation(error))
            }

        case .bundles(let active, let pending):
            if let active, active != bundle {
                appendLog(
                    level: "info",
                    "Policy bundle \(active.bundleId) (revision \(active.ruleRevision)) active, loaded from \(active.source.rawValue)")
            }
            if let pending, pending != pendingBundle {
                appendLog(level: "info", "Policy bundle \(pending.bundleId) downloaded; call activatePendingBundle() to use it")
            }
            bundle = active
            pendingBundle = pending

        case .policyUpdate(let ok, let error, let active, let pending):
            lastPolicyUpdate = PolicyUpdate(date: Date(), error: error, bundle: active)
            if let active {
                bundle = active
            }
            pendingBundle = pending
            if !ok, let error {
                appendLog(level: "warn", "Policy update failed: \(error.message)")
            }

        case .decision(let entry):
            configuration.onDecision?(entry)

        case .validationErrors(let errors):
            configuration.onValidationErrors?(errors)

        case .bundleCache(let key, let body, let bundleId, let ruleRevision):
            guard configuration.offlineCache, let data = Data(base64Encoded: body) else { return }
            let cache = cache
            Task {
                do {
                    try await cache.save(key: key, body: data, bundleId: bundleId, ruleRevision: ruleRevision)
                    self.appendLog(level: "debug", "Cached policy bundle \(bundleId) (\(data.count) bytes) for offline start")
                } catch {
                    self.appendLog(level: "error", "Failed to cache policy bundle: \(error.localizedDescription)")
                }
            }

        case .log(let level, let message):
            appendLog(level: level, message)

        case .jwtDecode(let id, let token, let keySetId):
            decodeJWT(id: id, token: token, keySetId: keySetId)

        case .unknown(let type):
            appendLog(level: "warn", "Unknown bridge event \(type)")
        }
    }

    private func decodeJWT(id: String, token: String, keySetId: String) {
        guard let decoder = configuration.jwtDecoder else {
            host.resolveCallback(id: id, payloadJSON: nil, errorMessage: "No jwtDecoder is configured")
            return
        }
        let host = host
        Task {
            do {
                let claims = try await decoder(JWT(token: token, keySetId: keySetId.isEmpty ? nil : keySetId))
                host.resolveCallback(id: id, payloadJSON: try BridgeJSON.encode(claims), errorMessage: nil)
            } catch {
                host.resolveCallback(id: id, payloadJSON: nil, errorMessage: String(describing: error))
            }
        }
    }

    private func handleProcessTermination() {
        // WebKit may reclaim the content process in the background. Rebuild it, within a budget;
        // the offline cache means this works without connectivity.
        startGeneration += 1
        status = .failed(.webView(reason: "web content process terminated"))
        bundle = nil
        pendingBundle = nil

        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.seconds(configuration.restartWindow))
        restartTimes.removeAll { $0 < windowStart }
        guard restartTimes.count < configuration.maximumRestarts else {
            appendLog(
                level: "error",
                "Web content process terminated \(restartTimes.count) times within \(configuration.restartWindow); "
                    + "not restarting automatically. Call start() to retry."
            )
            return
        }
        restartTimes.append(now)
        appendLog(
            level: "warn",
            "Web content process terminated; restarting (\(restartTimes.count)/\(configuration.maximumRestarts) in the current window)")
        Task { await self.startIfNeeded() }
    }

    private func appendLog(level: String, _ message: String) {
        switch level {
        case "error": CerbosLog.error(message)
        case "warn": CerbosLog.info("warning: \(message)")
        default: CerbosLog.debug(message)
        }
        logs.append(LogLine(date: Date(), level: level, message: message))
        if logs.count > 100 {
            logs.removeFirst(logs.count - 100)
        }
    }
}
#endif

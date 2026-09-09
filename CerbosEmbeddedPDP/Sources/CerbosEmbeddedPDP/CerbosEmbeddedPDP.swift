#if canImport(WebKit)
import Foundation
import Observation

/// An embedded Cerbos policy decision point for iOS and macOS.
///
/// Runs the official `@cerbos/embedded-client` and the `@cerbos/embedded-server` WebAssembly
/// module inside a hidden web view, downloads policy bundles from Cerbos Hub, keeps them updated
/// in the background, and caches the last bundle on disk so the app can start offline.
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
        /// Cerbos Hub API base URL. Defaults to `https://api.cerbos.cloud`.
        public var hubBaseURL: URL? = nil
        /// Client credentials for rules that require authentication. Keep them out of source control.
        public var credentials: HubCredentials? = nil
        /// How often to check Hub for policy updates. `nil` disables polling. Minimum 10 seconds.
        public var updateInterval: Duration? = .seconds(60)
        /// Whether downloaded updates replace the active bundle immediately (otherwise call ``activatePendingBundle()``).
        public var activateOnLoad = true
        /// Upper bound for `start()`: WebAssembly compilation plus the first bundle download.
        public var startTimeout: Duration = .seconds(120)
        /// Upper bound for a single check or plan. Evaluation takes milliseconds; this only fires on a stuck engine.
        public var requestTimeout: Duration = .seconds(30)
        /// The first bundle download is aborted after this long so a stalled connection falls back to the offline cache.
        public var initialLoadTimeout: Duration = .seconds(20)

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

    public let configuration: Configuration
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
            configuration.ruleId.trimmingCharacters(in: .whitespaces),
            configuration.scopes.sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    @ObservationIgnored private let host: CerbosWebViewHost
    @ObservationIgnored private let cache: PolicyBundleCache
    @ObservationIgnored private let resourcesError: CerbosError?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var restartAttempts = 0

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

    /// Loads the WebAssembly module and the policy bundle. Safe to call repeatedly; concurrent
    /// callers share one attempt. Call again after a failure to retry.
    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        if status == .ready {
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
        startTask = nil
    }

    /// Discards the current web view and starts again (for example after changing credentials).
    public func restart() async {
        stop()
        await start()
    }

    /// Stops update polling and releases the web view. `start()` brings the PDP back.
    public func stop() {
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
        try ensureReady()
        return try await host.invoke("checkResources", params: request, timeout: configuration.requestTimeout, failure: { .request($0) })
    }

    public func checkResource(_ request: CheckResourceRequest) async throws(CerbosError) -> CheckResult {
        try ensureReady()
        return try await host.invoke("checkResource", params: request, timeout: configuration.requestTimeout, failure: { .request($0) })
    }

    public func isAllowed(_ request: IsAllowedRequest) async throws(CerbosError) -> Bool {
        try ensureReady()
        return try await host.invoke("isAllowed", params: request, timeout: configuration.requestTimeout, failure: { .request($0) })
    }

    public func isAllowed(
        principal: Principal, resource: Resource, action: String, auxData: AuxData? = nil
    ) async throws(CerbosError) -> Bool {
        try await isAllowed(IsAllowedRequest(principal: principal, resource: resource, action: action, auxData: auxData))
    }

    public func planResources(_ request: PlanResourcesRequest) async throws(CerbosError) -> PlanResourcesResponse {
        try ensureReady()
        return try await host.invoke("planResources", params: request, timeout: configuration.requestTimeout, failure: { .request($0) })
    }

    // MARK: Internals

    private func ensureReady() throws(CerbosError) {
        guard status == .ready else {
            throw CerbosError.notReady
        }
    }

    private func performStart() async {
        status = .loading
        do {
            if let resourcesError {
                throw resourcesError
            }
            try await host.start()

            var cachedBundle: BridgeInitParams.CachedBundle?
            if configuration.offlineCache, let cached = await cache.load(key: offlineCacheKey) {
                cachedBundle = .init(key: offlineCacheKey, body: cached.body.base64EncodedString())
                appendLog(level: "info", "Offline cache has bundle \(cached.entry.bundleId) from \(cached.entry.savedAt)")
            }

            let result: BridgeInitResult = try await host.invoke(
                "init",
                params: initParams(cachedBundle: cachedBundle),
                timeout: configuration.startTimeout,
                failure: { .initialisation($0) }
            )
            bundle = result.bundle
            pendingBundle = result.pending
            server = result.server
            restartAttempts = 0
            status = .ready
            CerbosLog.info(
                "Cerbos embedded PDP ready (bundle \(result.bundle?.bundleId ?? "?"), source \(result.bundle?.source.rawValue ?? "?"))")
        } catch {
            guard status != .idle else {
                // stop() was called while starting; stay idle.
                return
            }
            CerbosLog.error("Cerbos embedded PDP failed to start: \(error.localizedDescription)")
            status = .failed(error)
        }
    }

    private func initParams(cachedBundle: BridgeInitParams.CachedBundle?) -> BridgeInitParams {
        let configuration = configuration
        let intervalSeconds: Double
        if let interval = configuration.updateInterval {
            intervalSeconds = max(10, Double(interval.components.seconds))
        } else {
            intervalSeconds = 0
        }
        return BridgeInitParams(
            ruleId: configuration.ruleId.trimmingCharacters(in: .whitespaces),
            scopes: configuration.scopes,
            hub: .init(
                baseUrl: configuration.hubBaseURL?.absoluteString,
                clientId: configuration.credentials?.clientId,
                clientSecret: configuration.credentials?.clientSecret
            ),
            updateIntervalSeconds: intervalSeconds,
            activateOnLoad: configuration.activateOnLoad,
            initialLoadTimeoutSeconds: Double(configuration.initialLoadTimeout.components.seconds),
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
            // `init` reports its own outcome; this covers later failures (for example after a restart of the page).
            if bridgeStatus == .failed, status == .ready, let error {
                status = .failed(.initialisation(error))
            }

        case .bundle(let info):
            bundle = info
            appendLog(
                level: "info", "Policy bundle \(info.bundleId) (revision \(info.ruleRevision)) loaded from \(info.source.rawValue)")

        case .policyUpdate(let ok, let error, let info):
            lastPolicyUpdate = PolicyUpdate(date: Date(), error: error, bundle: info)
            if let info {
                bundle = info
            }
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
        // WebKit may reclaim the content process while the app is in the background.
        // Rebuild it (the offline cache makes this cheap even without connectivity).
        status = .failed(.webView(reason: "web content process terminated"))
        bundle = nil
        guard restartAttempts < 3 else {
            appendLog(level: "error", "Web content process terminated repeatedly; giving up. Call start() to retry.")
            return
        }
        restartAttempts += 1
        appendLog(level: "warn", "Web content process terminated; restarting (attempt \(restartAttempts))")
        Task { await self.start() }
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

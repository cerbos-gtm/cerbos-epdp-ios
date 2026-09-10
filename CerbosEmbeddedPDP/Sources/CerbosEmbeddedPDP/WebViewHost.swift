#if canImport(WebKit)
import Foundation
import WebKit

/// Owns the hidden `WKWebView` that runs `@cerbos/embedded-client` and the Cerbos WebAssembly module.
///
/// The page, bridge script and `server.wasm` are served from the app bundle through a custom URL
/// scheme, so nothing is fetched from a CDN and WebKit can compile the module with
/// `WebAssembly.instantiateStreaming`. Calls into the page go through `callAsyncJavaScript`, which
/// serialises arguments safely and returns the bridge's JSON envelope; events come back through a
/// script message handler.
@MainActor
final class CerbosWebViewHost: NSObject {
    static let scheme = "cerbos-epdp"
    static let pageURL = URL(string: "\(scheme)://app/index.html")!
    static let eventHandlerName = "cerbosEvents"

    var onEvent: ((BridgeEvent) -> Void)?
    var onProcessTerminated: (() -> Void)?

    private(set) var webView: WKWebView?
    private(set) var isBridgeReady = false
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private let resourcesDirectory: URL

    init(resourcesDirectory: URL) {
        self.resourcesDirectory = resourcesDirectory
    }

    /// Locates the `web` resources copied from `CerbosBridge/build.mjs`.
    static func bundledResourcesDirectory() throws(CerbosError) -> URL {
        guard let url = Bundle.module.url(forResource: "web", withExtension: nil) else {
            throw CerbosError.webView(reason: "bundled web resources are missing; run `npm run build` in CerbosBridge")
        }
        return url
    }

    // MARK: Lifecycle

    /// Creates the web view (if needed), loads the bridge page and waits until the bridge script is ready.
    func start(timeout: Duration = .seconds(30)) async throws(CerbosError) {
        if webView != nil, isBridgeReady {
            return
        }
        shutdown()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BundleSchemeHandler(directory: resourcesDirectory), forURLScheme: Self.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Lockdown Mode removes WebAssembly from web views. The page only ever runs the bundled
        // bridge and engine, so opt this trusted content out when the user has Lockdown Mode on.
        // The setter is only touched in that case; the default already reflects the system setting.
        if configuration.defaultWebpagePreferences.isLockdownModeEnabled {
            CerbosLog.info("Lockdown Mode is enabled; opting the embedded PDP page out for its bundled content")
            configuration.defaultWebpagePreferences.isLockdownModeEnabled = false
        }
        configuration.suppressesIncrementalRendering = true

        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(target: self), name: Self.eventHandlerName)
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if DEBUG
        if #available(iOS 16.4, macOS 13.3, *) {
            webView.isInspectable = true  // Safari > Develop > <device> > Cerbos embedded PDP
        }
        #endif
        self.webView = webView
        isBridgeReady = false

        CerbosLog.info("Loading Cerbos embedded PDP bridge page")
        webView.load(URLRequest(url: Self.pageURL))
        try await awaitBridgeReady(timeout: timeout)
    }

    /// Tears down the web view. `start()` builds a fresh one.
    func shutdown() {
        resumeReady(with: .failure(.webView(reason: "shut down")))
        isBridgeReady = false
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.eventHandlerName)
        self.webView = nil
    }

    private func awaitBridgeReady(timeout: Duration) async throws(CerbosError) {
        if isBridgeReady { return }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeReady(with: .failure(.timeout(operation: "load the bridge page")))
        }
        defer { timeoutTask.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.readyContinuation = continuation
            }
        } catch let error as CerbosError {
            throw error
        } catch {
            throw CerbosError.webView(reason: String(describing: error))
        }
    }

    private func resumeReady(with result: Result<Void, CerbosError>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: Calls into the bridge

    /// Invokes a bridge method and decodes its result. Bridge-side failures are mapped with `failure`.
    /// A `timeout` turns a call that never resolves in the page into ``CerbosError/timeout(operation:)``.
    func invoke<Result: Decodable>(
        _ method: String,
        params: (any Encodable)? = nil,
        timeout: Duration? = nil,
        failure: (BridgeError) -> CerbosError
    ) async throws(CerbosError) -> Result {
        guard webView != nil, isBridgeReady else {
            throw CerbosError.notReady
        }
        var paramsJSON: String?
        if let params {
            paramsJSON = try BridgeJSON.encode(params)
        }
        let envelopeJSON = try await callBridge(method: method, paramsJSON: paramsJSON, timeout: timeout)
        return try BridgeJSON.unwrap(Result.self, envelopeJSON: envelopeJSON, failure: failure)
    }

    private func callBridge(method: String, paramsJSON: String?, timeout: Duration?) async throws(CerbosError) -> String {
        do {
            guard let timeout else {
                return try await evaluateBridgeCall(method: method, paramsJSON: paramsJSON)
            }
            // WebKit cannot cancel a running call, so race it against a timer instead of a task group
            // (which would wait for the JavaScript call to finish before returning).
            let race = BridgeCallRace()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                race.continuation = continuation
                race.timer = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    race.resume(.failure(CerbosError.timeout(operation: method)))
                }
                Task { @MainActor in
                    do {
                        race.resume(.success(try await self.evaluateBridgeCall(method: method, paramsJSON: paramsJSON)))
                    } catch {
                        race.resume(.failure(error))
                    }
                }
            }
        } catch let error as CerbosError {
            throw error
        } catch {
            throw CerbosError.webView(reason: Self.describe(error))
        }
    }

    private func evaluateBridgeCall(method: String, paramsJSON: String?) async throws -> String {
        guard let webView else {
            throw CerbosError.notReady
        }
        // The async overlay uses the `contentWorld:` label; `in:in:` would silently pick the
        // completion-handler overload and return immediately.
        let value = try await webView.callAsyncJavaScript(
            "return await window.CerbosBridge.invoke(method, params);",
            arguments: ["method": method, "params": paramsJSON ?? NSNull()],
            in: nil,
            contentWorld: .page
        )
        guard let envelopeJSON = value as? String else {
            throw CerbosError.invalidResponse(
                reason: "bridge returned \(value.map { String(describing: type(of: $0)) } ?? "nil") instead of a JSON string")
        }
        return envelopeJSON
    }

    /// Answers a `jwtDecode` request from the bridge.
    func resolveCallback(id: String, payloadJSON: String?, errorMessage: String?) {
        guard let webView else { return }
        webView.callAsyncJavaScript(
            "window.CerbosBridge.resolveCallback(id, ok, payload);",
            arguments: ["id": id, "ok": errorMessage == nil, "payload": payloadJSON ?? errorMessage ?? ""],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                CerbosLog.error("resolveCallback failed: \(String(describing: error))")
            }
        }
    }

    // MARK: Events

    fileprivate func receive(_ body: Any) {
        guard let json = body as? String else {
            CerbosLog.error("Ignoring non-string bridge event")
            return
        }
        let event: BridgeEvent
        do {
            event = try BridgeJSON.decode(BridgeEvent.self, from: json)
        } catch {
            CerbosLog.error("Failed to decode bridge event: \(String(describing: error))")
            return
        }
        if case .bridgeReady = event {
            isBridgeReady = true
            resumeReady(with: .success(()))
        }
        onEvent?(event)
    }

    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message
        }
        return nsError.localizedDescription
    }
}

/// Resumes a bridge call's continuation exactly once, from whichever finishes first: the call or its timer.
@MainActor
private final class BridgeCallRace {
    var continuation: CheckedContinuation<String, any Error>?
    var timer: Task<Void, Never>?

    func resume(_ result: Result<String, any Error>) {
        guard let continuation else {
            if case .success = result {
                CerbosLog.debug("A bridge call completed after its timeout; the late result was discarded")
            }
            return
        }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(with: result)
    }
}

// MARK: - WKNavigationDelegate

extension CerbosWebViewHost: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // The page must never navigate anywhere but its own bundled resources.
        decisionHandler(navigationAction.request.url?.scheme == Self.scheme ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        CerbosLog.debug("Bridge page loaded")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resumeReady(with: .failure(.webView(reason: error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resumeReady(with: .failure(.webView(reason: error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        CerbosLog.error("Web content process terminated")
        isBridgeReady = false
        resumeReady(with: .failure(.webView(reason: "web content process terminated")))
        onProcessTerminated?()
    }
}

// MARK: - Script messages

/// Breaks the retain cycle `WKUserContentController` would otherwise create with the host.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: CerbosWebViewHost?

    init(target: CerbosWebViewHost) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == CerbosWebViewHost.eventHandlerName else { return }
        target?.receive(message.body)
    }
}

// MARK: - Bundled resources

/// Serves `index.html`, `bridge.js`, `server.wasm` and `manifest.json` from the app bundle.
@MainActor
private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let files: [String: String] = [
        "index.html": "text/html; charset=utf-8",
        "bridge.js": "text/javascript; charset=utf-8",
        "server.wasm": "application/wasm",
        "manifest.json": "application/json",
    ]
    private static let chunkSize = 4 << 20

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let name = url.lastPathComponent
        guard let mimeType = Self.files[name],
            let data = try? Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
        else {
            CerbosLog.error("Bridge resource not found: \(url.absoluteString)")
            let response = HTTPURLResponse(
                url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
            ]
        )!
        urlSchemeTask.didReceive(response)

        // Hand the (memory-mapped) file over in chunks to bound the size of each IPC message. The
        // loop never suspends, so the task cannot be stopped part-way and needs no cancellation check.
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.chunkSize, data.count)
            urlSchemeTask.didReceive(data.subdata(in: offset..<end))
            offset = end
        }
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Responses are delivered synchronously in `start`, so there is never an in-progress task to stop.
    }
}
#endif

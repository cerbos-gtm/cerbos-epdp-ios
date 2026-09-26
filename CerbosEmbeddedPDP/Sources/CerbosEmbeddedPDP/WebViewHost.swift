#if canImport(WebKit)
import Foundation
import WebKit
import os

/// Owns the hidden `WKWebView` that runs the bridge and the Cerbos WebAssembly engine.
///
/// Resources are served from the package bundle through a custom URL scheme, which lets WebKit
/// stream-compile `server.wasm`. Calls go through `callAsyncJavaScript` (arguments are passed, never
/// interpolated); events come back through a script message handler.
@MainActor
final class CerbosWebViewHost: NSObject {
    static let scheme = "cerbos-epdp"
    static let pageURL = URL(string: "\(scheme)://app/index.html")!
    static let eventHandlerName = "cerbosEvents"
    private static let largeResponseBytes = 8 * 1024
    private static let signposter = OSSignposter(subsystem: CerbosLog.subsystem, category: "Bridge")

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
        // Lockdown Mode removes WebAssembly. The page only runs bundled code, so opt it out, touching
        // the setter only when needed (the default already reflects the system setting).
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

    /// Invokes a bridge method and decodes its result, mapping bridge failures with `failure`.
    /// A call still unresolved after `timeout` throws ``CerbosError/timeout(operation:)``.
    func invoke<Result: Decodable & Sendable>(
        _ method: String,
        params: (any Encodable & Sendable)? = nil,
        timeout: Duration? = nil,
        largeRequest: Bool = false,
        failure: (BridgeError) -> CerbosError
    ) async throws(CerbosError) -> Result {
        guard webView != nil, isBridgeReady else {
            throw CerbosError.notReady
        }
        // Shows each call as an interval in Instruments (os_signpost), in any app that embeds the package.
        let signpost = Self.signposter.beginInterval("Bridge call", id: Self.signposter.makeSignpostID(), "\(method, privacy: .public)")
        defer { Self.signposter.endInterval("Bridge call", signpost) }

        // Coding moves off the main actor only for large payloads: the executor hops cost more
        // (~0.06 ms per call) than coding a typical request on the main thread.
        var paramsJSON: String?
        if let params {
            paramsJSON = largeRequest ? try await BridgeJSON.encodeConcurrently(params) : try BridgeJSON.encode(params)
        }
        let envelopeJSON = try await callBridge(method: method, paramsJSON: paramsJSON, timeout: timeout)
        let envelope =
            envelopeJSON.utf8.count > Self.largeResponseBytes
            ? try await BridgeJSON.decodeEnvelopeConcurrently(Result.self, from: envelopeJSON)
            : try BridgeJSON.decode(BridgeEnvelope<Result>.self, from: envelopeJSON)
        return try BridgeJSON.unwrap(envelope, failure: failure)
    }

    /// The hot path of every decision. Uses the completion-handler API and a `DispatchWorkItem` timer
    /// instead of `Task`s, which measurably cuts latency.
    private func callBridge(method: String, paramsJSON: String?, timeout: Duration?) async throws(CerbosError) -> String {
        guard let webView else {
            throw CerbosError.notReady
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, CerbosError>, Never>) in
            // WebKit cannot cancel a running call; the timer just resolves it first.
            let call = BridgeCall(continuation)
            if let timeout {
                let timer = DispatchWorkItem {
                    MainActor.assumeIsolated { call.finish(.failure(.timeout(operation: method))) }
                }
                call.timer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout.timeInterval, execute: timer)
            }
            webView.callAsyncJavaScript(
                "return window.CerbosBridge.invoke(method, params)",
                arguments: ["method": method, "params": paramsJSON ?? NSNull()],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value as String):
                    call.finish(.success(value))
                case .success(let value):
                    call.finish(.failure(.invalidResponse(reason: "bridge returned \(type(of: value)) instead of a JSON string")))
                case .failure(let error):
                    call.finish(.failure(.webView(reason: Self.describe(error))))
                }
            }
        }
        return try result.get()
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
                CerbosLog.error("resolveCallback failed", detail: String(describing: error))
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
            CerbosLog.error("Failed to decode bridge event", detail: String(describing: error))
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

/// Resumes the continuation exactly once, from the reply or the timer, whichever comes first.
@MainActor
private final class BridgeCall {
    private var continuation: CheckedContinuation<Result<String, CerbosError>, Never>?
    var timer: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Result<String, CerbosError>, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, CerbosError>) {
        guard let continuation else {
            if case .success = result {
                CerbosLog.debug("A bridge call completed after its timeout; the late result was discarded")
            }
            return
        }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(returning: result)
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
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
            CerbosLog.error("Bridge resource not found", detail: url.absoluteString)
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

        // Chunk the memory-mapped file to bound each IPC message. The loop never suspends, so the
        // task cannot be stopped part-way.
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.chunkSize, data.count)
            urlSchemeTask.didReceive(data.subdata(in: offset..<end))
            offset = end
        }
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // `start` responds synchronously, so there is never a task in progress.
    }
}
#endif

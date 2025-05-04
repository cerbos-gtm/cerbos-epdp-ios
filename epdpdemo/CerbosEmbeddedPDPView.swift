import UIKit
import WebKit
import OSLog // For better logging

// Define specific logger for this class
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.cerbos.epdpdemo", category: "CerbosEmbeddedPDPView")

class CerbosEmbeddedPDPView: UIView {

    // MARK: - Public Callbacks
    var onPDPReady: (() -> Void)?
    var onDecision: ((String) -> Void)? // For raw decision logs
    var onPDPLoadError: ((String) -> Void)? // Callback for loading errors

    // MARK: - Private Properties
    private var webView: WKWebView!
    private let bridgeName = "iosBridge" // Must match JS: window.webkit.messageHandlers.<bridgeName>

    // --- State Enum with Equatable Conformance ---
    private enum State: Equatable { // <-- Added Equatable
        case idle
        case loadingHTML
        case htmlLoaded // Base HTML loaded, JS not yet confirmed ready
        case sdkReady   // JS SDK confirmed ready via bridge call
        case loadingPDP // loadCerbosPDP called in JS
        case pdpReady   // PDP bundle loaded, ready for checks
        case error(String)

        // --- Added Equality Check Function ---
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.loadingHTML, .loadingHTML),
                 (.htmlLoaded, .htmlLoaded),
                 (.sdkReady, .sdkReady),
                 (.loadingPDP, .loadingPDP),
                 (.pdpReady, .pdpReady):
                return true // Cases without associated values are equal if same case
            case (.error(let lhsError), .error(let rhsError)):
                return lhsError == rhsError // .error is equal if associated strings are equal
            default:
                return false // All other combinations are not equal
            }
        }
        // --- End of Equality Check Function ---
    }
    // --- End of State Enum ---

    private var currentState: State = .idle {
        didSet {
            // Avoid logging redundant state changes if == is implemented correctly
             if oldValue != currentState {
                 logger.debug("State changed: \(String(describing: oldValue)) -> \(String(describing: self.currentState))")
             }
        }
    }

    // Use Result type for better error handling in callbacks
    typealias CheckCallback = (Result<CheckResourcesResponse, Error>) -> Void
    private var pendingCallbacks = [String: CheckCallback]()
    private var pendingTimeouts = [String: DispatchWorkItem]()
    private let callbackTimeout: TimeInterval = 5.0 // 5 seconds timeout

    // Queue for calls made before PDP is ready
    private var preReadyCallQueue = [(callId: String, jsCode: String)]()
    private var urlToLoad: URL?
    private var loadPDPAfterSDKReady = false

    private lazy var jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // encoder.outputFormatting = .prettyPrinted // For debugging
        return encoder
    }()

    private lazy var jsonDecoder: JSONDecoder = {
        return JSONDecoder()
    }()

    // MARK: - Initialization
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupWebView()
        loadInitialHTML()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupWebView()
        loadInitialHTML()
    }

    deinit {
        logger.info("Deinit CerbosEmbeddedPDPView")
        // Clean up webview resources explicitly
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: bridgeName)
        webView?.removeFromSuperview()
        webView = nil
        // Cancel any pending timeouts
        pendingTimeouts.values.forEach { $0.cancel() }
        pendingCallbacks.removeAll()
        pendingTimeouts.removeAll()
        preReadyCallQueue.removeAll()
    }

    // MARK: - WebView Setup
    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // Add the script message handler
        userContentController.add(self, name: bridgeName)
        configuration.userContentController = userContentController

        // Preferences for running JS in background (optional)
        let preferences = WKPreferences()
        // preferences.javaScriptCanOpenWindowsAutomatically = false // Good practice
        configuration.preferences = preferences

        // Initialize WebView
        webView = WKWebView(frame: bounds, configuration: configuration)
        webView.navigationDelegate = self // Handle navigation events
        webView.uiDelegate = self // Optional: Handle JS alerts/prompts if needed for debugging

        // Make WebView hidden and non-interactive
        webView.isHidden = true
        webView.isUserInteractionEnabled = false
        // Set a minimal frame, but position doesn't strictly matter as it's hidden
        webView.frame = CGRect(x: -1, y: -1, width: 1, height: 1)

        addSubview(webView) // Still needs to be in hierarchy for JS to run reliably
        logger.debug("WKWebView initialized and added as subview.")
    }

    private func loadInitialHTML() {
        guard let htmlPath = Bundle.main.path(forResource: "cerbos_loader", ofType: "html") else {
            logger.error("Failed to find cerbos_loader.html in bundle.")
            updateState(.error("Missing cerbos_loader.html"))
            return
        }
        do {
            let htmlContent = try String(contentsOfFile: htmlPath, encoding: .utf8)
            // Use the bundle URL as the base URL to allow relative resource loading if needed in future
            let bundleUrl = URL(fileURLWithPath: Bundle.main.bundlePath)
            currentState = .loadingHTML // Set initial state before load
            webView.loadHTMLString(htmlContent, baseURL: bundleUrl)
            logger.info("Loading cerbos_loader.html...")
        } catch {
            logger.error("Failed to read cerbos_loader.html: \(error.localizedDescription)")
            updateState(.error("Failed to read HTML file: \(error.localizedDescription)"))
        }
    }

    // MARK: - Public API

    /// Initiates loading of the Cerbos Embedded PDP policy bundle from the specified URL.
    /// Call this only *after* the view is added to the hierarchy and initialized.
    /// The actual loading happens once the internal JS SDK signals it's ready.
    /// - Parameter url: The URL pointing to the Cerbos policy bundle (.wasm or .js).
    public func loadEmbeddedPDP(url: URL) {
        logger.info("Request received to load Cerbos PDP from: \(url.absoluteString)")
        self.urlToLoad = url

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Use the fact that State is now Equatable for cleaner checks
            if self.currentState == .sdkReady {
                // SDK is ready now, trigger load immediately
                self.triggerPDPLoad(url: url)
            } else if self.currentState == .loadingHTML || self.currentState == .htmlLoaded || self.currentState == .idle {
                // SDK not ready yet, flag to load once sdkReady is received
                logger.debug("SDK not ready yet. Will load PDP when SDK signals ready.")
                self.loadPDPAfterSDKReady = true
            } else if self.currentState == .loadingPDP || self.currentState == .pdpReady {
                logger.warning("PDP loading already in progress or completed. Re-loading PDP from \(url.absoluteString).")
                // Reset state before triggering reload if needed, or just trigger
                self.triggerPDPLoad(url: url) // Allow reloading
            } else if case .error(let msg) = self.currentState {
                logger.error("Cannot load PDP, view is in error state: \(msg)")
                self.onPDPLoadError?("Cannot load PDP, view is in error state: \(msg)")
            }
        }
    }

    /// Performs an authorization check against the loaded Cerbos ePDP.
    /// - Parameters:
    ///   - request: The `CheckResourcesRequest` containing principal, resources, and actions.
    ///   - completion: A closure invoked asynchronously with the `CheckResourcesResponse` or an `Error`. Runs on the main thread.
    public func checkResources(request: CheckResourcesRequest, completion: @escaping CheckCallback) {
        let callId = request.requestId ?? UUID().uuidString // Use provided or generate new ID
        var mutableRequest = request
        mutableRequest.requestId = callId // Ensure request ID is set for correlation

        logger.debug("Received checkResources request [\(callId)]")

        guard currentState == .pdpReady else {
            let errorMsg = "Cerbos PDP not ready. Current state: \(String(describing: currentState))"
            logger.warning("[\(callId)] \(errorMsg)")
            if case .error(let specificError) = currentState {
                 // Complete immediately with error if already in error state
                 completion(.failure(CerbosErrorResponse(error: "PDP in error state: \(specificError)", cerbosCallId: callId, requestId: callId)))
            } else {
                logger.info("[\(callId)] Queuing checkResources call until PDP is ready.")
                // Queue the call (serialize *before* queuing)
                do {
                    let jsonData = try jsonEncoder.encode(mutableRequest)
                    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                        throw CerbosErrorResponse(error: "Failed to create UTF8 string from JSON data", cerbosCallId: callId, requestId: callId)
                    }
                     // Escape JSON string for JS literal. Use a more robust method if complex JSON expected.
                     let escapedJsonString = jsonString
                         .replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "'", with: "\\'")
                         .replacingOccurrences(of: "\n", with: "\\n")
                         .replacingOccurrences(of: "\r", with: "\\r")

                    // Store original completion handler
                    pendingCallbacks[callId] = completion
                    // Queue the JS code to be executed later
                    let jsCode = "window.performCheckResources('\(callId)', '\(escapedJsonString)');"
                    preReadyCallQueue.append((callId: callId, jsCode: jsCode))
                    setupTimeout(for: callId) // Set up timeout even for queued calls

                } catch {
                    logger.error("[\(callId)] Failed to serialize request for queuing: \(error.localizedDescription)")
                     completion(.failure(CerbosErrorResponse(error: "Failed to serialize request: \(error.localizedDescription)", cerbosCallId: callId, requestId: callId)))
                }
            }
            return
        }

        // --- PDP is Ready: Execute the call ---
        do {
            let jsonData = try jsonEncoder.encode(mutableRequest)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw CerbosErrorResponse(error: "Failed to create UTF8 string from JSON data", cerbosCallId: callId, requestId: callId)
            }
             // Escape JSON string for JS literal.
            let escapedJsonString = jsonString
                 .replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "'", with: "\\'")
                 .replacingOccurrences(of: "\n", with: "\\n")
                 .replacingOccurrences(of: "\r", with: "\\r")

            let jsCode = "window.performCheckResources('\(callId)', '\(escapedJsonString)');"
            logger.trace("[\(callId)] JS Code to Execute: \(jsCode)") // Use trace level

            executeJavascript(jsCode: jsCode, callId: callId, completion: completion)

        } catch {
            logger.error("[\(callId)] Failed to serialize request or prepare JS call: \(error.localizedDescription)")
            completion(.failure(CerbosErrorResponse(error: "Serialization/JS Prep failed: \(error.localizedDescription)", cerbosCallId: callId, requestId: callId)))
        }
    }

    // MARK: - Private Helpers

    private func updateState(_ newState: State) {
        // Ensure state updates happen on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateState(newState) }
            return
        }
        // Check if state is actually changing before proceeding
        if self.currentState != newState {
            self.currentState = newState
            if case .error(let msg) = newState {
                self.onPDPLoadError?(msg) // Notify listener on error state transition
            }
        }
    }


    private func triggerPDPLoad(url: URL) {
        // Ensure this runs on the main thread for state checking and JS evaluation
        guard Thread.isMainThread else {
             DispatchQueue.main.async { [weak self] in self?.triggerPDPLoad(url: url) }
             return
        }

        guard currentState == .sdkReady || currentState == .pdpReady else { // Allow reloading
            logger.warning("Attempted to trigger PDP load but SDK is not ready or view is in unexpected state: \(String(describing: self.currentState))")
            return
        }

        logger.info("Instructing WebView to load Cerbos PDP from: \(url.absoluteString)")
        let escapedUrl = url.absoluteString.replacingOccurrences(of: "'", with: "\\'")
        let jsCode = "window.loadCerbosPDP('\(escapedUrl)');"

        updateState(.loadingPDP) // Set state before evaluating JS

        webView.evaluateJavaScript(jsCode) { [weak self] _, error in
             // This callback indicates if the JS execution *started*
             // Ensure UI/state updates run on main thread
             DispatchQueue.main.async {
                 guard let self = self else { return }
                 if let error = error {
                     logger.error("Failed to START execute loadCerbosPDP JS command: \(error.localizedDescription)")
                      // If JS execution failed, transition to error state immediately
                     self.updateState(.error("JS execution failed for load command: \(error.localizedDescription)"))
                 } else {
                     logger.debug("loadCerbosPDP JS command evaluation initiated.")
                     // Wait for pdpReady or pdpError message via bridge
                 }
             }
        }
    }

    // Sets up the timeout mechanism for a JS call
    private func setupTimeout(for callId: String) {
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
             // Check if the callback still exists (i.e., hasn't completed or timed out already)
            if let callback = self.pendingCallbacks.removeValue(forKey: callId) {
                logger.warning("JS call timed out for ID: \(callId)")
                let timeoutError = CerbosErrorResponse(error: "Request timed out after \(self.callbackTimeout) seconds", cerbosCallId: callId, requestId: callId)
                 // Ensure callback runs on main thread
                 DispatchQueue.main.async {
                    callback(.failure(timeoutError))
                 }
                self.pendingTimeouts.removeValue(forKey: callId) // Clean up timeout entry
            } else {
                 logger.debug("Timeout fired for \(callId), but callback was already removed (likely completed).")
            }
        }
        pendingTimeouts[callId] = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + callbackTimeout, execute: timeoutWorkItem)
    }

    // Cancels the timeout for a specific JS call (used when response received)
    private func cancelTimeout(for callId: String) {
         if let timeoutWorkItem = pendingTimeouts.removeValue(forKey: callId) {
             timeoutWorkItem.cancel()
             logger.trace("Cancelled timeout for \(callId).")
         }
    }


    private func executeJavascript(jsCode: String, callId: String, completion: @escaping CheckCallback) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.executeJavascript(jsCode: jsCode, callId: callId, completion: completion)
            }
            return
        }

        // Store callback before evaluating JS
        pendingCallbacks[callId] = completion
        setupTimeout(for: callId) // Set up timeout before execution starts

        // Evaluate the JavaScript
        logger.debug("Executing JS for callId: \(callId)")
        webView.evaluateJavaScript(jsCode) { [weak self] _, error in
             // This completion only indicates if JS execution *started*. Result comes via message handler.
             DispatchQueue.main.async { // Ensure cleanup logic is on main thread
                 guard let self = self else { return }
                 if let error = error {
                     logger.error("[\(callId)] Failed to START JS execution: \(error.localizedDescription)")
                     // If JS couldn't even start, clean up and fail immediately
                     if let callback = self.pendingCallbacks.removeValue(forKey: callId) {
                          self.cancelTimeout(for: callId) // Cancel the timeout we just set
                          let jsError = CerbosErrorResponse(error: "JS Execution Error: \(error.localizedDescription)", cerbosCallId: callId, requestId: callId)
                          callback(.failure(jsError))
                     }
                 } else {
                      logger.trace("[\(callId)] JS execution evaluation initiated successfully.")
                 }
             }
        }
    }

    private func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == bridgeName else {
            logger.warning("Received message from unknown bridge: \(message.name)")
            return
        }

        guard let bodyDict = message.body as? [String: Any],
              let type = bodyDict["type"] as? String else {
            logger.error("Received invalid message body format")
            return
        }

        logger.trace("Received message from JS bridge - Type: \(type)") // Body logging removed for brevity/security

        switch type {
        case "sdkReady":
            handleSDKReady()
        case "pdpReady":
            handlePDPReady()
        case "response":
            handleResponse(bodyDict: bodyDict)
        case "decisionLog":
            if let logPayload = bodyDict["payload"] as? String {
                onDecision?(logPayload)
            } else {
                 logger.warning("Received decisionLog with invalid payload format.")
            }
        case "log":
            let level = bodyDict["level"] as? String ?? "info"
            let logPayload = bodyDict["payload"] as? String ?? "No message"
            logFromJS(message: logPayload, level: level)
        case "pdpError":
            let errorMsg = bodyDict["payload"] as? String ?? "Unknown PDP loading error"
            logger.error("Received PDP loading error from JS: \(errorMsg)")
            updateState(.error("PDP Load Failed: \(errorMsg)"))
        case "sdkError":
             let errorMsg = bodyDict["payload"] as? String ?? "Unknown SDK loading error"
             logger.critical("Received SDK loading error from JS: \(errorMsg)")
             updateState(.error("SDK Load Failed: \(errorMsg)"))
        default:
            logger.warning("Received unknown message type from JS: \(type)")
        }
    }

    private func handleSDKReady() {
         logger.info("JavaScript SDK reported ready.")
         // Use Equatable state check
         if currentState == .htmlLoaded || currentState == .loadingHTML {
             updateState(.sdkReady)
             // If loadEmbeddedPDP was called before SDK was ready, trigger it now
             if loadPDPAfterSDKReady, let url = urlToLoad {
                 logger.debug("SDK is now ready, proceeding with queued PDP load.")
                 triggerPDPLoad(url: url)
                 loadPDPAfterSDKReady = false // Reset flag
             }
         } else {
             logger.warning("Received sdkReady signal in unexpected state: \(String(describing: self.currentState))")
         }
    }

    private func handlePDPReady() {
         logger.info(">>> Cerbos PDP is READY! <<<")
         // Allow transition from loadingPDP or sdkReady (initial load), or pdpReady (reload)
         if currentState == .loadingPDP || currentState == .sdkReady || currentState == .pdpReady {
              updateState(.pdpReady)
              onPDPReady?() // Notify listener
              flushPreReadyCallQueue() // Process queued checks
         } else {
             logger.warning("Received pdpReady signal in unexpected state: \(String(describing: self.currentState))")
         }
    }

    private func handleResponse(bodyDict: [String: Any]) {
          guard let callId = bodyDict["callId"] as? String else {
               logger.error("Received response message without 'callId'")
               return
          }

          // Retrieve and remove the callback. IMPORTANT: Do this BEFORE cancelling timeout.
          guard let callback = pendingCallbacks.removeValue(forKey: callId) else {
               logger.warning("Received response for unknown or already timed-out callId: \(callId)")
               // Still attempt to cancel timeout in case of race condition
               cancelTimeout(for: callId)
               return
          }

          // Now that callback is secured, cancel the timeout.
          cancelTimeout(for: callId)

          logger.debug("Processing response for callId: \(callId)")

          if let errorMsg = bodyDict["error"] as? String {
               logger.error("[\(callId)] Received error response from JS: \(errorMsg)")
               let jsError = CerbosErrorResponse(error: "JS Error: \(errorMsg)", cerbosCallId: callId, requestId: callId)
               callback(.failure(jsError))
               return
          }

          guard let responseJsonString = bodyDict["payload"] as? String else {
               logger.error("[\(callId)] Received response message without valid 'payload' string.")
                let formatError = CerbosErrorResponse(error: "Invalid response format from JS (missing payload string)", cerbosCallId: callId, requestId: callId)
               callback(.failure(formatError))
               return
          }

          // Decode the JSON payload string
          do {
                guard let responseData = responseJsonString.data(using: .utf8) else {
                    throw CerbosErrorResponse(error: "Failed to convert response payload string to Data", cerbosCallId: callId, requestId: callId)
                }
                let decodedResponse = try jsonDecoder.decode(CheckResourcesResponse.self, from: responseData)

                // Note: RequestId from JS response might be null if JS had an error *before* processing.
                // The callId is the reliable correlation key here. We pass the decoded response as is.
                 logger.info("[\(callId)] Successfully decoded response.")
                callback(.success(decodedResponse))
          } catch {
                 logger.error("[\(callId)] Failed to decode response JSON: \(error.localizedDescription). JSON: \(responseJsonString)")
                 let decodeError = CerbosErrorResponse(error: "JSON Decoding Failed: \(error.localizedDescription)", cerbosCallId: callId, requestId: callId)
                 callback(.failure(decodeError))
          }
    }

    private func flushPreReadyCallQueue() {
        guard currentState == .pdpReady else {
             logger.warning("Attempted to flush pre-ready queue but PDP is not ready.")
             return
        }
        guard !preReadyCallQueue.isEmpty else {
            logger.debug("Pre-ready queue is empty, nothing to flush.")
            return
        }

        logger.info("Flushing \(self.preReadyCallQueue.count) pre-ready JS calls.")
        let callsToFlush = preReadyCallQueue
        preReadyCallQueue.removeAll() // Clear queue *before* potentially re-queueing via executeJavascript

        for (callId, jsCode) in callsToFlush {
            logger.debug("Executing queued call [\(callId)]")
            // The callback should already be stored in pendingCallbacks from when it was queued
            guard let completion = pendingCallbacks[callId] else {
                 logger.error("[\(callId)] Callback not found for queued call. Skipping.")
                 // Clean up associated timeout if it exists (should have been set during queuing)
                 cancelTimeout(for: callId)
                 continue
            }
            // Re-execute using the standard method (which re-sets up timeout etc.)
            // NOTE: We don't need to call setupTimeout here again, executeJavascript does it.
             // We already cancelled the original timeout when retrieving the callback for the queue flush.
            executeJavascript(jsCode: jsCode, callId: callId, completion: completion)
        }
         logger.debug("Pre-ready queue flushed.")
    }

    private func logFromJS(message: String, level: String) {
        // Use a specific logger category for JS messages
        let jsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.cerbos.epdpdemo", category: "CerbosEmbeddedPDPView.JavaScript")
        switch level.lowercased() {
        case "error":
            jsLogger.error("[JS] \(message)")
        case "warn":
            jsLogger.warning("[JS] \(message)")
        case "info":
            jsLogger.info("[JS] \(message)")
        default: // Includes "log" or unspecified
            jsLogger.debug("[JS] \(message)")
        }
    }
}

// MARK: - WKNavigationDelegate Implementation
extension CerbosEmbeddedPDPView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("WebView finished loading HTML content.")
        // Transition state only if we were loading HTML
        if currentState == .loadingHTML {
             updateState(.htmlLoaded)
             // Now wait for 'sdkReady' message from JS
        } else {
            logger.debug("WebView finished loading, but state was already \(String(describing: self.currentState)). No state change.")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("WebView navigation failed (didFail): \(error.localizedDescription)")
        updateState(.error("WebView navigation failed: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logger.error("WebView provisional navigation failed (didFailProvisional - e.g., initial load): \(error.localizedDescription)")
        updateState(.error("WebView provisional navigation failed: \(error.localizedDescription)"))
    }

     func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
         logger.critical("WebView content process terminated unexpectedly!")
         updateState(.error("WebView process terminated"))
         // Consider recovery strategy: e.g., notify service to retry load
         onPDPLoadError?("WebView process terminated unexpectedly. Please retry.")
    }
}

// MARK: - WKUIDelegate Implementation (Optional)
extension CerbosEmbeddedPDPView: WKUIDelegate {
    // Handle JS alert panels for debugging if needed
    private func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedBy frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
         logger.debug("[JS Alert] \(message)")
         completionHandler() // Automatically dismiss alert after logging
     }
}

// MARK: - WKScriptMessageHandler Implementation
extension CerbosEmbeddedPDPView: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Always route message handling to the main thread for state/UI safety
        DispatchQueue.main.async { [weak self] in
             self?.handleScriptMessage(message)
        }
    }
}

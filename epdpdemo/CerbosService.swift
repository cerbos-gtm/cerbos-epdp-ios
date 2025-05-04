import SwiftUI
import Combine // For ObservableObject
import OSLog // For logging

// Assuming CerbosEmbeddedPDPView and CerbosDataModels are in the same project/module

@MainActor // Ensure published properties are updated on the main thread
class CerbosService: ObservableObject {

    @Published var isReady: Bool = false
    @Published var lastError: String? = nil
    @Published var lastCheckResultSummary: String = "Not checked yet." // Example result display

    // Keep the Cerbos view instance managed by the service
    // Make it private to encapsulate it
    private var cerbosPDPView: CerbosEmbeddedPDPView?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.cerbos.epdpdemo", category: "CerbosService")

    init(bundleURL: URL) {
        logger.info("CerbosService initializing...")
        // Instantiate the view - it doesn't need to be added to any parent view
        // as it's hidden and managed entirely here.
        cerbosPDPView = CerbosEmbeddedPDPView(frame: .zero) // Frame doesn't matter

        setupCallbacks()

        logger.info("Loading Cerbos PDP from URL: \(bundleURL.absoluteString)")
        cerbosPDPView?.loadEmbeddedPDP(url: bundleURL)
    }

    deinit {
        logger.info("CerbosService deinit.")
        // Optional: Explicitly clean up if needed, though CerbosEmbeddedPDPView's deinit should handle it.
        // cerbosPDPView?.destroy() // If you add an explicit destroy method
    }

    private func setupCallbacks() {
        cerbosPDPView?.onPDPReady = { [weak self] in
            // Use Task to ensure execution on the main actor
            Task { @MainActor [weak self] in
                self?.logger.info(">>> Service received PDP Ready <<<")
                self?.isReady = true
                self?.lastError = nil // Clear error on success
                self?.lastCheckResultSummary = "PDP Ready. Perform a check."
            }
        }

        cerbosPDPView?.onPDPLoadError = { [weak self] errorMsg in
            Task { @MainActor [weak self] in
                self?.logger.error("!!! Service received PDP Load Error: \(errorMsg)")
                self?.isReady = false
                self?.lastError = errorMsg
                self?.lastCheckResultSummary = "Error loading PDP."
            }
        }

        cerbosPDPView?.onDecision = { [weak self] logJson in
            // Handle decision logs if needed (e.g., logging)
             self?.logger.trace("Decision Log: \(logJson)") // Trace level for verbosity
        }
    }

    // Method for SwiftUI views to call
    func checkResources(request: CheckResourcesRequest) {
        guard let pdpView = cerbosPDPView else {
            logger.error("Attempted checkResources but Cerbos view is nil.")
            Task { @MainActor in
                self.lastError = "Internal Error: Cerbos view not initialized."
                self.lastCheckResultSummary = "Internal Error."
            }
            return
        }

        guard isReady else {
             logger.warning("Attempted checkResources when PDP is not ready.")
             Task { @MainActor in
                 self.lastCheckResultSummary = "PDP Not Ready. Please wait."
             }
             // Optionally queue the request or return an error state
             return
        }

        logger.info("Service performing checkResources...")
        Task { @MainActor in // Update status immediately on main thread
            self.lastCheckResultSummary = "Checking..."
        }

        // The callback from CerbosEmbeddedPDPView already runs on the main thread,
        // but we wrap the update logic in Task for consistency.
        pdpView.checkResources(request: request) { [weak self] result in
             Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let response):
                     self.logger.info("<<< Service received CheckResources Response >>>")
                     // Process and update published properties
                     self.handleCheckSuccess(response: response)

                case .failure(let error):
                     self.logger.error("<<< Service received CheckResources Failure: \(error.localizedDescription) >>>")
                     if let cerbosError = error as? CerbosErrorResponse {
                         self.lastError = cerbosError.error
                         self.lastCheckResultSummary = "Check Failed: \(cerbosError.error)"
                     } else {
                         self.lastError = error.localizedDescription
                         self.lastCheckResultSummary = "Check Failed: \(error.localizedDescription)"
                     }
                }
             }
        }
    }

    private func handleCheckSuccess(response: CheckResourcesResponse) {
        var allowedActions: [String] = []
        var deniedActions: [String] = []

        response.results.forEach { resultEntry in
            resultEntry.actions.forEach { (action, effect) in
                let resourceId = resultEntry.resource.id
                if effect == .EFFECT_ALLOW {
                    allowedActions.append("\(action) on \(resourceId)")
                } else {
                    deniedActions.append("\(action) on \(resourceId)")
                }
            }
        }
        let allowedString = allowedActions.isEmpty ? "None" : allowedActions.joined(separator: ", ")
        let deniedString = deniedActions.isEmpty ? "None" : deniedActions.joined(separator: ", ")
        self.lastCheckResultSummary = "Allowed: \(allowedString)\nDenied: \(deniedString)"
        self.lastError = nil // Clear error on successful check
    }

    // Optional: Add a retry mechanism if needed
    func retryLoad(bundleURL: URL) {
         logger.info("Retrying PDP load...")
         // Re-create or reset the view and load again
         cerbosPDPView = CerbosEmbeddedPDPView(frame: .zero)
         setupCallbacks()
         Task { @MainActor in
             self.isReady = false
             self.lastError = nil
             self.lastCheckResultSummary = "Retrying load..."
         }
         cerbosPDPView?.loadEmbeddedPDP(url: bundleURL)
    }
}

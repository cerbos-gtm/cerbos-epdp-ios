import Foundation

/// Errors produced by the embedded policy decision point.
public enum CerbosError: Error, Sendable, Equatable {
    /// `start()` has not completed successfully, so checks cannot be evaluated.
    case notReady

    /// The web content process that hosts the WebAssembly module could not be started or was lost.
    case webView(reason: String)

    /// The bridge did not answer in time: the page did not become ready within the start timeout,
    /// or a check or plan exceeded `Configuration.requestTimeout`. `operation` names what timed out.
    case timeout(operation: String)

    /// The engine cannot run: WebAssembly is unavailable in the web view (for example Lockdown Mode)
    /// or the bundled `server.wasm` failed to load or compile.
    case engine(reason: String)

    /// Cerbos Hub rejected or could not serve the policy bundle (see `BridgeError.code` for the gRPC status).
    case policySource(BridgeError)

    /// The embedded client failed to initialise for another reason.
    case initialisation(BridgeError)

    /// The embedded PDP rejected the request (gRPC status semantics, see `BridgeError.code`).
    case request(BridgeError)

    /// The bridge returned a payload that could not be decoded.
    case invalidResponse(reason: String)

    /// A request could not be encoded for the bridge, or a configuration value (for example a
    /// non-HTTPS `hubBaseURL`) cannot be used by it.
    case invalidRequest(reason: String)

    /// Reading from or writing to the on-disk policy bundle cache failed.
    case cache(reason: String)
}

/// An error raised inside the JavaScript bridge, serialised to a stable shape.
public struct BridgeError: Sendable, Equatable, Codable {
    /// `NotOK` (gRPC-style failure from the PDP), `ValidationFailed`, or a JavaScript error name.
    public var name: String
    public var message: String
    /// `engine`, `policySource` or `bridge` for initialisation failures.
    public var kind: String?
    /// gRPC status code for `NotOK` errors (for example `3` for invalid argument, `14` for unavailable).
    public var code: Int?
    public var details: String?
    public var validationErrors: [ValidationError]?
    public var stack: String?

    public init(
        name: String, message: String, kind: String? = nil, code: Int? = nil, details: String? = nil,
        validationErrors: [ValidationError]? = nil, stack: String? = nil
    ) {
        self.name = name
        self.message = message
        self.kind = kind
        self.code = code
        self.details = details
        self.validationErrors = validationErrors
        self.stack = stack
    }
}

extension CerbosError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notReady:
            return "The embedded PDP is not ready."
        case .webView(let reason):
            return "The embedded PDP web content process failed: \(reason)"
        case .timeout(let operation):
            return "Timed out waiting for the embedded PDP to \(operation)."
        case .engine(let reason):
            return "The embedded PDP engine cannot run: \(reason)"
        case .policySource(let error):
            return "Cerbos Hub could not provide the policy bundle: \(error.message)"
        case .initialisation(let error):
            return "Failed to initialise the embedded PDP: \(error.message)"
        case .request(let error):
            return error.details.map { "\(error.message) (\($0))" } ?? error.message
        case .invalidResponse(let reason):
            return "Invalid response from the embedded PDP bridge: \(reason)"
        case .invalidRequest(let reason):
            return "Invalid request: \(reason)"
        case .cache(let reason):
            return "Policy bundle cache error: \(reason)"
        }
    }
}

extension CerbosError {
    /// Maps a failed bridge `init` to the most specific error case using the bridge's classification.
    static func initialisationFailure(_ error: BridgeError) -> CerbosError {
        switch error.kind {
        case "engine":
            return .engine(reason: error.message)
        case "policySource":
            return .policySource(error)
        default:
            return .initialisation(error)
        }
    }

    /// Whether the failure means the web content process is gone and a restart may recover.
    var isWebViewFailure: Bool {
        if case .webView = self { return true }
        return false
    }
}

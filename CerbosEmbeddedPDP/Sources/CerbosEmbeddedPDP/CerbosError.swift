import Foundation

/// Errors produced by the embedded policy decision point.
public enum CerbosError: Error, Sendable, Equatable {
    /// `start()` has not completed successfully, so checks cannot be evaluated.
    case notReady

    /// The web content process that hosts the WebAssembly module could not be started or was lost.
    case webView(reason: String)

    /// `start()` exceeded `startTimeout`, or a check or plan exceeded `requestTimeout`.
    case timeout(operation: String)

    /// WebAssembly is unavailable in the web view, or the bundled `server.wasm` failed to load or compile.
    case engine(reason: String)

    /// Cerbos Hub rejected or could not serve the policy bundle (see `BridgeError.code` for the gRPC status).
    case policySource(BridgeError)

    /// The embedded client failed to initialise for another reason.
    case initialisation(BridgeError)

    /// The embedded PDP rejected the request (gRPC status semantics, see `BridgeError.code`).
    case request(BridgeError)

    /// The bridge returned a payload that could not be decoded.
    case invalidResponse(reason: String)

    /// A request could not be encoded, or a configuration value (such as a non-HTTPS `hubBaseURL`) is invalid.
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
            String(localized: "The embedded PDP is not ready.", bundle: .module)
        case .webView(let reason):
            String(localized: "The embedded PDP web content process failed: \(reason)", bundle: .module)
        case .timeout(let operation):
            String(localized: "Timed out waiting for the embedded PDP to \(operation).", bundle: .module)
        case .engine(let reason):
            String(localized: "The embedded PDP engine cannot run: \(reason)", bundle: .module)
        case .policySource(let error):
            String(localized: "Cerbos Hub could not provide the policy bundle: \(error.message)", bundle: .module)
        case .initialisation(let error):
            String(localized: "Failed to initialise the embedded PDP: \(error.message)", bundle: .module)
        case .request(let error):
            error.details.map { "\(error.message) (\($0))" } ?? error.message
        case .invalidResponse(let reason):
            String(localized: "Invalid response from the embedded PDP bridge: \(reason)", bundle: .module)
        case .invalidRequest(let reason):
            String(localized: "Invalid request: \(reason)", bundle: .module)
        case .cache(let reason):
            String(localized: "Policy bundle cache error: \(reason)", bundle: .module)
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

#if !canImport(Darwin)
// swift-corelibs-foundation has no `String(localized:bundle:)`; Linux only runs the unit tests, in English.
extension String {
    fileprivate init(localized value: String, bundle: Bundle) {
        self = value
    }
}
#endif

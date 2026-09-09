import Foundation

/// Errors produced by the embedded policy decision point.
public enum CerbosError: Error, Sendable, Equatable {
    /// `start()` has not completed successfully, so checks cannot be evaluated.
    case notReady

    /// The web content process that hosts the WebAssembly module could not be started or was lost.
    case webView(reason: String)

    /// The bridge script did not become ready in time.
    case timeout(operation: String)

    /// The embedded client failed to initialise (WASM instantiation or initial policy bundle load).
    case initialisation(BridgeError)

    /// The embedded PDP rejected the request (gRPC status semantics, see `BridgeError.code`).
    case request(BridgeError)

    /// The bridge returned a payload that could not be decoded.
    case invalidResponse(reason: String)

    /// A request could not be encoded for the bridge.
    case invalidRequest(reason: String)

    /// Reading from or writing to the on-disk policy bundle cache failed.
    case cache(reason: String)
}

/// An error raised inside the JavaScript bridge, serialised to a stable shape.
public struct BridgeError: Sendable, Equatable, Codable {
    /// `NotOK` (gRPC-style failure from the PDP), `ValidationFailed`, or a JavaScript error name.
    public var name: String
    public var message: String
    /// gRPC status code for `NotOK` errors (for example `3` for invalid argument, `14` for unavailable).
    public var code: Int?
    public var details: String?
    public var validationErrors: [ValidationError]?
    public var stack: String?

    public init(
        name: String, message: String, code: Int? = nil, details: String? = nil, validationErrors: [ValidationError]? = nil,
        stack: String? = nil
    ) {
        self.name = name
        self.message = message
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

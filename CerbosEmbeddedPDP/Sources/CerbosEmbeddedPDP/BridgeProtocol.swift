import Foundation

// Wire types shared with `CerbosBridge/src/core.ts` and `bridge.ts`. Keep the two in sync.

enum BridgeStatus: String, Decodable, Sendable {
    case idle, loading, ready, failed
}

struct BridgeEnvelope<Result: Decodable>: Decodable {
    var ok: Bool
    var result: Result?
    var error: BridgeError?
}

/// Marker for bridge methods that return no meaningful value.
struct BridgeIgnoredResult: Decodable {
    init(from decoder: any Decoder) throws {}
}

struct BridgeInitParams: Encodable {
    struct Hub: Encodable {
        var baseUrl: String?
        var clientId: String?
        var clientSecret: String?
    }

    struct Options: Encodable {
        var defaultPolicyVersion: String?
        var defaultScope: String?
        var globals: [String: JSONValue]?
        var lenientScopeSearch: Bool?
        var schemaEnforcement: String?
        var strictEvaluation: Bool?
        var userAgent: String?
        var headers: [String: String]?
        var onValidationError: String?
    }

    struct CachedBundle: Encodable {
        var key: String
        var body: String
    }

    var ruleId: String
    var scopes: [String]
    var hub: Hub
    var updateIntervalSeconds: Double
    var activateOnLoad: Bool
    var initialLoadTimeoutSeconds: Double
    var options: Options
    var emitDecisions: Bool
    var jwtDecoding: Bool
    var cachedBundle: CachedBundle?
}

struct BridgeInitResult: Decodable {
    var status: BridgeStatus
    var bundle: BundleInfo?
    var pending: BundleInfo?
    var server: ServerInfo
}

struct BridgeStatusResult: Decodable {
    var status: BridgeStatus
    var bundle: BundleInfo?
    var pending: BundleInfo?
    var error: BridgeError?
}

/// Events pushed by the bridge through the `cerbosEvents` script message handler.
enum BridgeEvent: Decodable, Sendable {
    case bridgeReady
    case status(BridgeStatus, error: BridgeError?)
    case bundles(active: BundleInfo?, pending: BundleInfo?)
    case policyUpdate(ok: Bool, error: BridgeError?, bundle: BundleInfo?, pending: BundleInfo?)
    case decision(JSONValue)
    case validationErrors([ValidationError])
    case bundleCache(key: String, body: String, bundleId: String, ruleRevision: String)
    case log(level: String, message: String)
    case jwtDecode(id: String, token: String, keySetId: String)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, status, error, bundle, active, pending, ok, entry, errors, key, body, bundleId, ruleRevision, level, message, id, token,
            keySetId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "bridgeReady":
            self = .bridgeReady
        case "status":
            self = .status(
                try container.decode(BridgeStatus.self, forKey: .status),
                error: try container.decodeIfPresent(BridgeError.self, forKey: .error)
            )
        case "bundles":
            self = .bundles(
                active: try container.decodeIfPresent(BundleInfo.self, forKey: .active),
                pending: try container.decodeIfPresent(BundleInfo.self, forKey: .pending)
            )
        case "policyUpdate":
            self = .policyUpdate(
                ok: try container.decode(Bool.self, forKey: .ok),
                error: try container.decodeIfPresent(BridgeError.self, forKey: .error),
                bundle: try container.decodeIfPresent(BundleInfo.self, forKey: .bundle),
                pending: try container.decodeIfPresent(BundleInfo.self, forKey: .pending)
            )
        case "decision":
            self = .decision(try container.decodeIfPresent(JSONValue.self, forKey: .entry) ?? .null)
        case "validationErrors":
            self = .validationErrors(try container.decodeIfPresent([ValidationError].self, forKey: .errors) ?? [])
        case "bundleCache":
            self = .bundleCache(
                key: try container.decode(String.self, forKey: .key),
                body: try container.decode(String.self, forKey: .body),
                bundleId: try container.decodeIfPresent(String.self, forKey: .bundleId) ?? "",
                ruleRevision: try container.decodeIfPresent(String.self, forKey: .ruleRevision) ?? ""
            )
        case "log":
            self = .log(
                level: try container.decodeIfPresent(String.self, forKey: .level) ?? "info",
                message: try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            )
        case "jwtDecode":
            self = .jwtDecode(
                id: try container.decode(String.self, forKey: .id),
                token: try container.decodeIfPresent(String.self, forKey: .token) ?? "",
                keySetId: try container.decodeIfPresent(String.self, forKey: .keySetId) ?? ""
            )
        default:
            self = .unknown(type: type)
        }
    }
}

/// JSON coding configured for the bridge's wire format (ISO 8601 dates with fractional seconds).
enum BridgeJSON {
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
            }
            return date
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        return encoder
    }

    static func encode<T: Encodable>(_ value: T) throws(CerbosError) -> String {
        do {
            let data = try makeEncoder().encode(value)
            guard let string = String(data: data, encoding: .utf8) else {
                throw CerbosError.invalidRequest(reason: "request is not valid UTF-8")
            }
            return string
        } catch let error as CerbosError {
            throw error
        } catch {
            throw CerbosError.invalidRequest(reason: String(describing: error))
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws(CerbosError) -> T {
        do {
            return try makeDecoder().decode(type, from: Data(string.utf8))
        } catch {
            throw CerbosError.invalidResponse(reason: String(describing: error))
        }
    }

    /// Unwraps a bridge envelope, mapping bridge-side failures to ``CerbosError``.
    static func unwrap<T: Decodable>(_ type: T.Type, envelopeJSON: String, failure: (BridgeError) -> CerbosError) throws(CerbosError) -> T {
        let envelope = try decode(BridgeEnvelope<T>.self, from: envelopeJSON)
        if envelope.ok {
            guard let result = envelope.result else {
                throw CerbosError.invalidResponse(reason: "envelope is missing its result")
            }
            return result
        }
        throw failure(envelope.error ?? BridgeError(name: "Error", message: "unknown bridge error"))
    }
}

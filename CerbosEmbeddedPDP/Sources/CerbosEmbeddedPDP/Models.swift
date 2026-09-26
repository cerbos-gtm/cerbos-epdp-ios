import Foundation

// Request and response types mirror the `@cerbos/core` JSON shapes the bridge forwards to
// `@cerbos/embedded-client` (`attr` is exposed as `attributes` in Swift).

// MARK: - Requests

public struct Principal: Sendable, Hashable, Codable {
    public var id: String
    public var roles: [String]
    public var attributes: [String: JSONValue]
    public var policyVersion: String?
    public var scope: String?

    public init(id: String, roles: [String], attributes: [String: JSONValue] = [:], policyVersion: String? = nil, scope: String? = nil) {
        self.id = id
        self.roles = roles
        self.attributes = attributes
        self.policyVersion = policyVersion
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case id, roles, policyVersion, scope
        case attributes = "attr"
    }
}

public struct Resource: Sendable, Hashable, Codable {
    public var kind: String
    public var id: String
    public var attributes: [String: JSONValue]
    public var policyVersion: String?
    public var scope: String?

    public init(kind: String, id: String, attributes: [String: JSONValue] = [:], policyVersion: String? = nil, scope: String? = nil) {
        self.kind = kind
        self.id = id
        self.attributes = attributes
        self.policyVersion = policyVersion
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case kind, id, policyVersion, scope
        case attributes = "attr"
    }
}

/// A resource and the actions to check on it.
public struct ResourceCheck: Sendable, Hashable, Codable {
    public var resource: Resource
    public var actions: [String]

    public init(resource: Resource, actions: [String]) {
        self.resource = resource
        self.actions = actions
    }
}

/// A JWT passed as auxiliary data. Your `jwtDecoder` verifies it; the engine only sees the claims.
public struct JWT: Sendable, Hashable, Codable {
    public var token: String
    public var keySetId: String?

    public init(token: String, keySetId: String? = nil) {
        self.token = token
        self.keySetId = keySetId
    }
}

public struct AuxData: Sendable, Hashable, Codable {
    public var jwt: JWT?

    public init(jwt: JWT? = nil) {
        self.jwt = jwt
    }
}

public struct CheckResourcesRequest: Sendable, Hashable, Codable {
    public var principal: Principal
    public var resources: [ResourceCheck]
    public var auxData: AuxData?
    public var includeMetadata: Bool
    public var requestId: String?

    public init(
        principal: Principal, resources: [ResourceCheck], auxData: AuxData? = nil, includeMetadata: Bool = false, requestId: String? = nil
    ) {
        self.principal = principal
        self.resources = resources
        self.auxData = auxData
        self.includeMetadata = includeMetadata
        self.requestId = requestId
    }
}

public struct CheckResourceRequest: Sendable, Hashable, Codable {
    public var principal: Principal
    public var resource: Resource
    public var actions: [String]
    public var auxData: AuxData?
    public var includeMetadata: Bool
    public var requestId: String?

    public init(
        principal: Principal, resource: Resource, actions: [String], auxData: AuxData? = nil, includeMetadata: Bool = false,
        requestId: String? = nil
    ) {
        self.principal = principal
        self.resource = resource
        self.actions = actions
        self.auxData = auxData
        self.includeMetadata = includeMetadata
        self.requestId = requestId
    }
}

public struct IsAllowedRequest: Sendable, Hashable, Codable {
    public var principal: Principal
    public var resource: Resource
    public var action: String
    public var auxData: AuxData?
    public var requestId: String?

    public init(principal: Principal, resource: Resource, action: String, auxData: AuxData? = nil, requestId: String? = nil) {
        self.principal = principal
        self.resource = resource
        self.action = action
        self.auxData = auxData
        self.requestId = requestId
    }
}

/// The resource kind (and optional known attributes) to plan a query for.
public struct PlanResource: Sendable, Hashable, Codable {
    public var kind: String
    public var attributes: [String: JSONValue]
    public var policyVersion: String?
    public var scope: String?

    public init(kind: String, attributes: [String: JSONValue] = [:], policyVersion: String? = nil, scope: String? = nil) {
        self.kind = kind
        self.attributes = attributes
        self.policyVersion = policyVersion
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case kind, policyVersion, scope
        case attributes = "attr"
    }
}

public struct PlanResourcesRequest: Sendable, Hashable, Codable {
    public var principal: Principal
    public var resource: PlanResource
    public var actions: [String]
    public var auxData: AuxData?
    public var includeMetadata: Bool
    public var requestId: String?

    public init(
        principal: Principal, resource: PlanResource, actions: [String], auxData: AuxData? = nil, includeMetadata: Bool = false,
        requestId: String? = nil
    ) {
        self.principal = principal
        self.resource = resource
        self.actions = actions
        self.auxData = auxData
        self.includeMetadata = includeMetadata
        self.requestId = requestId
    }

    public init(
        principal: Principal, resource: PlanResource, action: String, auxData: AuxData? = nil, includeMetadata: Bool = false,
        requestId: String? = nil
    ) {
        self.init(
            principal: principal, resource: resource, actions: [action], auxData: auxData, includeMetadata: includeMetadata,
            requestId: requestId)
    }
}

// MARK: - Responses

public enum Effect: String, Sendable, Codable {
    case allow = "EFFECT_ALLOW"
    case deny = "EFFECT_DENY"

    /// Unknown effects decode as a denial (fail closed) so the rest of a batch keeps its decisions.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = Effect(rawValue: raw) {
            self = known
        } else {
            CerbosLog.error("Unknown effect \(raw) in a check result; treating it as a denial")
            self = .deny
        }
    }
}

public struct ResourceIdentifier: Sendable, Hashable, Codable {
    public var kind: String
    public var id: String
    public var policyVersion: String?
    public var scope: String?

    public init(kind: String, id: String, policyVersion: String? = nil, scope: String? = nil) {
        self.kind = kind
        self.id = id
        self.policyVersion = policyVersion
        self.scope = scope
    }
}

public struct ValidationError: Sendable, Hashable, Codable {
    public var path: String
    public var message: String
    /// `SOURCE_PRINCIPAL` or `SOURCE_RESOURCE`.
    public var source: String

    public init(path: String, message: String, source: String) {
        self.path = path
        self.message = message
        self.source = source
    }
}

/// A value produced by a policy rule's `output` expression.
public struct OutputResult: Sendable, Hashable, Codable {
    public var source: String
    public var value: JSONValue

    public init(source: String, value: JSONValue) {
        self.source = source
        self.value = value
    }
}

public struct EffectMetadata: Sendable, Hashable, Codable {
    public var matchedPolicy: String
    public var matchedScope: String

    public init(matchedPolicy: String, matchedScope: String) {
        self.matchedPolicy = matchedPolicy
        self.matchedScope = matchedScope
    }
}

public struct CheckResultMetadata: Sendable, Hashable, Codable {
    public var actions: [String: EffectMetadata]
    public var effectiveDerivedRoles: [String]

    public init(actions: [String: EffectMetadata] = [:], effectiveDerivedRoles: [String] = []) {
        self.actions = actions
        self.effectiveDerivedRoles = effectiveDerivedRoles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decodeIfPresent([String: EffectMetadata].self, forKey: .actions) ?? [:]
        effectiveDerivedRoles = try container.decodeIfPresent([String].self, forKey: .effectiveDerivedRoles) ?? []
    }
}

/// The decision for one resource. Returned by `checkResource`, and per resource by `checkResources`.
public struct CheckResult: Sendable, Hashable, Codable {
    public var resource: ResourceIdentifier
    public var actions: [String: Effect]
    public var validationErrors: [ValidationError]
    /// Only populated when the request set `includeMetadata`.
    public var metadata: CheckResultMetadata?
    public var outputs: [OutputResult]

    public init(
        resource: ResourceIdentifier, actions: [String: Effect], validationErrors: [ValidationError] = [],
        metadata: CheckResultMetadata? = nil, outputs: [OutputResult] = []
    ) {
        self.resource = resource
        self.actions = actions
        self.validationErrors = validationErrors
        self.metadata = metadata
        self.outputs = outputs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resource = try container.decode(ResourceIdentifier.self, forKey: .resource)
        actions = try container.decodeIfPresent([String: Effect].self, forKey: .actions) ?? [:]
        validationErrors = try container.decodeIfPresent([ValidationError].self, forKey: .validationErrors) ?? []
        metadata = try container.decodeIfPresent(CheckResultMetadata.self, forKey: .metadata)
        outputs = try container.decodeIfPresent([OutputResult].self, forKey: .outputs) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case resource, actions, validationErrors, metadata, outputs
    }

    /// Whether the action is allowed. Unknown actions are treated as denied.
    public func isAllowed(_ action: String) -> Bool {
        actions[action] == .allow
    }

    public var allowedActions: [String] {
        actions.filter { $0.value == .allow }.keys.sorted()
    }

    public var allAllowed: Bool {
        !actions.isEmpty && actions.values.allSatisfy { $0 == .allow }
    }
}

public struct CheckResourcesResponse: Sendable, Hashable, Codable {
    public var requestId: String
    public var cerbosCallId: String
    public var results: [CheckResult]

    public init(requestId: String, cerbosCallId: String = "", results: [CheckResult]) {
        self.requestId = requestId
        self.cerbosCallId = cerbosCallId
        self.results = results
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId) ?? ""
        cerbosCallId = try container.decodeIfPresent(String.self, forKey: .cerbosCallId) ?? ""
        results = try container.decodeIfPresent([CheckResult].self, forKey: .results) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case requestId, cerbosCallId, results
    }

    public func result(kind: String, id: String) -> CheckResult? {
        results.first { $0.resource.kind == kind && $0.resource.id == id }
    }

    /// Whether the action is allowed on the identified resource. Missing resources are treated as denied.
    public func isAllowed(kind: String, id: String, action: String) -> Bool {
        result(kind: kind, id: id)?.isAllowed(action) ?? false
    }
}

public enum PlanKind: String, Sendable, Codable {
    case alwaysAllowed = "KIND_ALWAYS_ALLOWED"
    case alwaysDenied = "KIND_ALWAYS_DENIED"
    case conditional = "KIND_CONDITIONAL"
}

public struct PlanResourcesResponse: Sendable, Hashable, Codable {
    public var requestId: String
    public var cerbosCallId: String
    public var kind: PlanKind
    /// The filter expression tree when `kind` is `.conditional` (same shape as the JavaScript SDK's `PlanExpression`).
    public var condition: JSONValue?
    public var validationErrors: [ValidationError]
    public var metadata: JSONValue?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId) ?? ""
        cerbosCallId = try container.decodeIfPresent(String.self, forKey: .cerbosCallId) ?? ""
        kind = try container.decode(PlanKind.self, forKey: .kind)
        condition = try container.decodeIfPresent(JSONValue.self, forKey: .condition)
        validationErrors = try container.decodeIfPresent([ValidationError].self, forKey: .validationErrors) ?? []
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }

    enum CodingKeys: String, CodingKey {
        case requestId, cerbosCallId, kind, condition, validationErrors, metadata
    }
}

// MARK: - Bundle and server information

public enum BundleSource: String, Sendable, Codable {
    /// Downloaded from Cerbos Hub during this session.
    case network
    /// Replayed from the on-disk cache because the initial download failed.
    case cache
}

/// Identifies the policy bundle currently loaded in the embedded PDP.
public struct BundleInfo: Sendable, Hashable, Codable {
    public var bundleId: String
    public var ruleRevision: String
    public var source: BundleSource
    public var receivedAt: Date

    public init(bundleId: String, ruleRevision: String, source: BundleSource, receivedAt: Date) {
        self.bundleId = bundleId
        self.ruleRevision = ruleRevision
        self.source = source
        self.receivedAt = receivedAt
    }
}

/// Build information of the bundled `@cerbos/embedded-server` WebAssembly module.
public struct ServerInfo: Sendable, Hashable, Codable {
    public var version: String
    public var commit: String
    public var builtAt: Date

    public init(version: String, commit: String, builtAt: Date) {
        self.version = version
        self.commit = commit
        self.builtAt = builtAt
    }
}

/// Outcome of a background policy bundle update check.
public struct PolicyUpdate: Sendable, Equatable {
    public var date: Date
    public var error: BridgeError?
    public var bundle: BundleInfo?

    public var succeeded: Bool { error == nil }
}

import Foundation

// --- Add/Uncomment this Enum ---
enum JSONValue: Codable, Hashable { // Add Hashable if needed elsewhere
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case dictionary([String: JSONValue])
    case null

    // Custom initializer to handle decoding various types
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        // Decode Double *after* Int to avoid decoding Ints as Doubles (e.g., 5 becomes 5.0)
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .dictionary(value); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type found"))
    }

    // Custom encoder to write the underlying value
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    // Helper to get the underlying value (optional)
    var rawValue: Any? {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map { $0.rawValue }
        case .dictionary(let v): return v.mapValues { $0.rawValue }
        case .null: return nil
        }
    }
}
// --- End of Enum ---

// Change the typealias to use the concrete JSONValue enum
typealias Attributes = [String: JSONValue] // <-- CHANGE THIS

// --- Rest of your Data Models ---

// No change needed here structurally, but `attr` now uses [String: JSONValue]?
struct CheckResourcesRequest: Codable {
    var requestId: String? = UUID().uuidString
    let principal: Principal
    let resources: [ResourceAction]
    let includeMeta: Bool?
    let auxData: AuxData?
}

// No change needed here structurally
struct Principal: Codable {
    let id: String
    let roles: [String]
    let policyVersion: String?
    let scope: String?
    let attr: Attributes? // This now correctly uses [String: JSONValue]?
}

// No change needed here structurally
struct ResourceAction: Codable {
    let resource: Resource
    let actions: [String]
}

// No change needed here structurally
struct Resource: Codable {
    let id: String
    let kind: String
    let policyVersion: String?
    let scope: String?
    let attr: Attributes? // This now correctly uses [String: JSONValue]?
}

// No change needed here structurally
struct AuxData: Codable {
    let jwt: Attributes? // This now correctly uses [String: JSONValue]?
}

// --- Response Structures ---
// No change needed here structurally
struct CheckResourcesResponse: Codable {
    let requestId: String?
    let results: [ResultEntry]
    let error: String?
    let cerbosCallId: String?
}

// No change needed here structurally
struct ResultEntry: Codable {
    let resource: ResourceIdentifier
    let actions: [String: Effect]
    let validationErrors: [ValidationError]?
    let meta: Meta?
    let outputs: [OutputEntry]?
}

// No change needed here structurally
struct ResourceIdentifier: Codable {
    let id: String
    let kind: String
    let policyVersion: String?
    let scope: String?
}

// No change needed here structurally
struct ValidationError: Codable {
    let path: String
    let message: String
    let source: String
}

// No change needed here structurally
struct Meta: Codable {
    let actions: [String: ActionMeta]?
    let effectiveDerivedRoles: [String]?
}

// No change needed here structurally
struct ActionMeta: Codable {
    let matchedPolicy: String?
    let matchedRule: String?
}

// CHANGE the type of 'value' here too
struct OutputEntry: Codable {
    let source: String
    let value: JSONValue // <-- CHANGE THIS (was AttributeValue/Codable)
}

// No change needed here
enum Effect: String, Codable {
    case EFFECT_ALLOW
    case EFFECT_DENY
    case EFFECT_UNSPECIFIED
}

// No change needed here
struct CerbosErrorResponse: Error, Codable {
    let error: String
    let cerbosCallId: String?
    let requestId: String?
    var results: [ResultEntry]? = []
}

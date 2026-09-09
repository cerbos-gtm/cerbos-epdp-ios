import Foundation
import Testing

@testable import CerbosEmbeddedPDP

@Suite("Request encoding")
struct RequestEncodingTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let string = try BridgeJSON.encode(value)
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("checkResources matches the @cerbos/core request shape")
    func checkResourcesShape() throws {
        let request = CheckResourcesRequest(
            principal: Principal(id: "alice", roles: ["USER"], attributes: ["tier": "PREMIUM", "level": 3, "beta": true]),
            resources: [
                ResourceCheck(resource: Resource(kind: "resource", id: "1", attributes: ["ownerId": "alice"]), actions: ["read", "update"])
            ],
            includeMetadata: true,
            requestId: "req-1"
        )
        let object = try json(request)

        #expect(object["includeMetadata"] as? Bool == true)
        #expect(object["requestId"] as? String == "req-1")
        #expect(object["auxData"] == nil, "nil optionals must be omitted")

        let principal = try #require(object["principal"] as? [String: Any])
        #expect(principal["id"] as? String == "alice")
        #expect(principal["roles"] as? [String] == ["USER"])
        let attr = try #require(principal["attr"] as? [String: Any], "attributes encode under `attr`")
        #expect(attr["tier"] as? String == "PREMIUM")
        #expect(attr["level"] as? Double == 3)
        #expect(attr["beta"] as? Bool == true)
        #expect(principal["policyVersion"] == nil)

        let resources = try #require(object["resources"] as? [[String: Any]])
        let resource = try #require(resources.first?["resource"] as? [String: Any])
        #expect(resource["kind"] as? String == "resource")
        #expect((resource["attr"] as? [String: Any])?["ownerId"] as? String == "alice")
        #expect(resources.first?["actions"] as? [String] == ["read", "update"])
    }

    @Test("JWT aux data and plan requests")
    func auxDataAndPlan() throws {
        let plan = PlanResourcesRequest(
            principal: Principal(id: "alice", roles: ["USER"]),
            resource: PlanResource(kind: "document"),
            action: "view",
            auxData: AuxData(jwt: JWT(token: "abc", keySetId: "auth0"))
        )
        let object = try json(plan)
        #expect(object["actions"] as? [String] == ["view"])
        let jwt = try #require((object["auxData"] as? [String: Any])?["jwt"] as? [String: Any])
        #expect(jwt["token"] as? String == "abc")
        #expect(jwt["keySetId"] as? String == "auth0")
        #expect((object["resource"] as? [String: Any])?["kind"] as? String == "document")
    }
}

@Suite("Response decoding")
struct ResponseDecodingTests {
    // Captured from the bridge smoke test (CerbosBridge/test/smoke.mjs).
    static let checkResourcesJSON = """
    {"ok":true,"result":{"requestId":"7fabe13a-412a-410c-aeb4-d4b427fc56be","cerbosCallId":"","results":[
      {"resource":{"kind":"resource","id":"1","policyVersion":"","scope":""},
       "actions":{"read":"EFFECT_ALLOW","update":"EFFECT_DENY"},
       "allowedActions":["read"],
       "validationErrors":[{"path":"/tier","message":"expected string","source":"SOURCE_PRINCIPAL"}],
       "metadata":{"actions":{"read":{"matchedPolicy":"resource.resource.vdefault","matchedScope":""},"update":{"matchedPolicy":"NO_MATCH","matchedScope":""}},"effectiveDerivedRoles":["owner"]},
       "outputs":[{"source":"resource.resource.vdefault#rule-001","value":{"greeting":"hi","n":1}}]},
      {"resource":{"kind":"resource","id":"2"},"actions":{"read":"EFFECT_DENY"}}
    ]}}
    """

    @Test("checkResources envelope")
    func checkResources() throws {
        let response = try BridgeJSON.unwrap(CheckResourcesResponse.self, envelopeJSON: Self.checkResourcesJSON, failure: { .request($0) })
        #expect(response.results.count == 2)
        #expect(response.isAllowed(kind: "resource", id: "1", action: "read"))
        #expect(!response.isAllowed(kind: "resource", id: "1", action: "update"))
        #expect(!response.isAllowed(kind: "resource", id: "1", action: "unknown"))
        #expect(!response.isAllowed(kind: "resource", id: "missing", action: "read"))

        let first = try #require(response.result(kind: "resource", id: "1"))
        #expect(first.allowedActions == ["read"])
        #expect(!first.allAllowed)
        #expect(first.validationErrors.first?.source == "SOURCE_PRINCIPAL")
        #expect(first.metadata?.actions["read"]?.matchedPolicy == "resource.resource.vdefault")
        #expect(first.metadata?.effectiveDerivedRoles == ["owner"])
        #expect(first.outputs.first?.value["greeting"]?.stringValue == "hi")
        #expect(first.outputs.first?.value["n"]?.intValue == 1)

        let second = try #require(response.result(kind: "resource", id: "2"))
        #expect(second.metadata == nil)
        #expect(second.validationErrors.isEmpty)
        #expect(second.outputs.isEmpty)
    }

    @Test("failed envelope maps to CerbosError with gRPC code")
    func failedEnvelope() throws {
        let json = #"{"ok":false,"error":{"name":"NotOK","message":"gRPC error 3 (INVALID_ARGUMENT): bad request","code":3,"details":"bad request"}}"#
        #expect(throws: CerbosError.request(BridgeError(name: "NotOK", message: "gRPC error 3 (INVALID_ARGUMENT): bad request", code: 3, details: "bad request"))) {
            _ = try BridgeJSON.unwrap(CheckResourcesResponse.self, envelopeJSON: json, failure: { .request($0) })
        }
    }

    @Test("plan and init results")
    func planAndInit() throws {
        let plan = try BridgeJSON.unwrap(
            PlanResourcesResponse.self,
            envelopeJSON: #"{"ok":true,"result":{"requestId":"r","cerbosCallId":"","validationErrors":[],"kind":"KIND_CONDITIONAL","condition":{"operator":"eq","operands":[{"name":"request.resource.attr.ownerId"},{"value":"alice"}]}}}"#,
            failure: { .request($0) }
        )
        #expect(plan.kind == .conditional)
        #expect(plan.condition?["operator"]?.stringValue == "eq")

        let initResult = try BridgeJSON.unwrap(
            BridgeInitResult.self,
            envelopeJSON: #"{"ok":true,"result":{"status":"ready","bundle":{"bundleId":"SPPO3BI3O0ON0K59","ruleRevision":"8","source":"network","receivedAt":"2026-09-09T11:20:53.082Z"},"server":{"version":"0.55.0","commit":"2901f64","builtAt":"2026-08-13T09:19:02.287Z"}}}"#,
            failure: { .initialisation($0) }
        )
        #expect(initResult.status == .ready)
        #expect(initResult.bundle?.source == .network)
        #expect(initResult.bundle?.receivedAt == BridgeJSON.parseDate("2026-09-09T11:20:53.082Z"))
        #expect(initResult.server.version == "0.55.0")
    }
}

@Suite("Bridge events")
struct BridgeEventTests {
    private func decode(_ json: String) throws -> BridgeEvent {
        try BridgeJSON.decode(BridgeEvent.self, from: json)
    }

    @Test func allEventTypes() throws {
        if case .bridgeReady = try decode(#"{"type":"bridgeReady"}"#) {} else { Issue.record("bridgeReady") }

        if case .status(let status, let error) = try decode(#"{"type":"status","status":"failed","error":{"name":"Error","message":"boom"}}"#) {
            #expect(status == .failed)
            #expect(error?.message == "boom")
        } else { Issue.record("status") }

        if case .bundle(let info) = try decode(#"{"type":"bundle","bundle":{"bundleId":"B","ruleRevision":"2","source":"cache","receivedAt":"2026-09-09T11:20:53Z"}}"#) {
            #expect(info.bundleId == "B")
            #expect(info.source == .cache)
        } else { Issue.record("bundle") }

        if case .policyUpdate(let ok, let error, let bundle) = try decode(#"{"type":"policyUpdate","ok":false,"error":{"name":"NotOK","message":"unavailable","code":14}}"#) {
            #expect(!ok)
            #expect(error?.code == 14)
            #expect(bundle == nil)
        } else { Issue.record("policyUpdate") }

        if case .decision(let entry) = try decode(#"{"type":"decision","entry":{"callId":"01M","method":{"name":"CheckResources"}}}"#) {
            #expect(entry["callId"]?.stringValue == "01M")
        } else { Issue.record("decision") }

        if case .validationErrors(let errors) = try decode(#"{"type":"validationErrors","errors":[{"path":"/a","message":"m","source":"SOURCE_RESOURCE"}]}"#) {
            #expect(errors.count == 1)
        } else { Issue.record("validationErrors") }

        if case .bundleCache(let key, let body, let bundleId, let ruleRevision) = try decode(#"{"type":"bundleCache","key":"k","body":"AAEC","bundleId":"B","ruleRevision":"3"}"#) {
            #expect(key == "k")
            #expect(Data(base64Encoded: body) == Data([0, 1, 2]))
            #expect(bundleId == "B")
            #expect(ruleRevision == "3")
        } else { Issue.record("bundleCache") }

        if case .log(let level, let message) = try decode(#"{"type":"log","level":"warn","message":"careful"}"#) {
            #expect(level == "warn")
            #expect(message == "careful")
        } else { Issue.record("log") }

        if case .jwtDecode(let id, let token, let keySetId) = try decode(#"{"type":"jwtDecode","id":"jwt-1","token":"t","keySetId":""}"#) {
            #expect(id == "jwt-1")
            #expect(token == "t")
            #expect(keySetId.isEmpty)
        } else { Issue.record("jwtDecode") }

        if case .unknown(let type) = try decode(#"{"type":"somethingNew"}"#) {
            #expect(type == "somethingNew")
        } else { Issue.record("unknown") }
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func literalsAndRoundTrip() throws {
        let value: JSONValue = ["name": "alice", "age": 30, "ratio": 0.5, "admin": false, "tags": ["a", "b"], "nothing": nil]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
        #expect(decoded["age"]?.intValue == 30)
        #expect(decoded["ratio"]?.intValue == nil)
        #expect(decoded["tags"]?[1]?.stringValue == "b")
        #expect(decoded["nothing"]?.isNull == true)
        #expect(decoded["missing"] == nil)
    }
}

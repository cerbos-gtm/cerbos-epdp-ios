import CerbosEmbeddedPDP
import Foundation

/// The demo's access check, against the sample `resource` policy: `ADMIN` can do anything; `USER`
/// can `read`/`create`, and `update`/`delete`/`publish` only resources they own.
struct DemoScenario: Equatable {
    static let roles = ["USER", "ADMIN"]
    static let actions = ["read", "create", "update", "delete", "publish"]
    static let resourceKind = "resource"

    var principalId = "alice@example.com"
    var role = "USER"
    var ownsResource = true

    var ownerId: String {
        ownsResource ? principalId : "someone-else@example.com"
    }

    func request() -> CheckResourcesRequest {
        CheckResourcesRequest(
            principal: Principal(id: principalId, roles: [role], attributes: ["tier": "PREMIUM"]),
            resources: [
                ResourceCheck(
                    resource: Resource(kind: Self.resourceKind, id: "1", attributes: ["ownerId": .string(ownerId)]),
                    actions: Self.actions
                )
            ],
            includeMetadata: true
        )
    }
}

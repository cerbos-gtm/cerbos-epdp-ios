import CerbosEmbeddedPDP
import Foundation

/// The access check exercised by the demo UI. It targets the sample policy used by the Cerbos
/// GTM demos: a `resource` kind where `ADMIN` can do anything, `USER` can `read`/`create`, and
/// `USER` can `update`/`delete`/`publish` only resources they own (`R.attr.ownerId == P.id`).
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

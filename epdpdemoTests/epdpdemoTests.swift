import CerbosEmbeddedPDP
import Testing

@testable import epdpdemo

struct DemoScenarioTests {
    @Test func ownedResourceUsesPrincipalAsOwner() {
        let scenario = DemoScenario(principalId: "alice@example.com", role: "USER", ownsResource: true)
        let request = scenario.request()
        #expect(request.principal.roles == ["USER"])
        #expect(request.resources.first?.resource.kind == DemoScenario.resourceKind)
        #expect(request.resources.first?.resource.attributes["ownerId"] == "alice@example.com")
        #expect(request.resources.first?.actions == DemoScenario.actions)
        #expect(request.includeMetadata)
    }

    @Test func foreignResourceUsesAnotherOwner() {
        let scenario = DemoScenario(principalId: "alice@example.com", role: "ADMIN", ownsResource: false)
        #expect(scenario.request().resources.first?.resource.attributes["ownerId"] == "someone-else@example.com")
    }
}

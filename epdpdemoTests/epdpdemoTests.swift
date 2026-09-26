import CerbosEmbeddedPDP
import Foundation
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

struct HubSettingsTests {
    @Test func credentialsNeedBothClientIdAndSecret() {
        let withoutSecret = HubSettings.configuration(ruleId: "RULE", hubBaseURL: "", clientId: "id", clientSecret: "")
        #expect(withoutSecret.credentials == nil)

        let full = HubSettings.configuration(ruleId: "RULE", hubBaseURL: "", clientId: "  id  ", clientSecret: "secret")
        #expect(full.credentials == .init(clientId: "id", clientSecret: "secret"))
    }

    @Test func invalidHubURLFallsBackToTheDefault() {
        func hubURL(_ text: String) -> URL? {
            HubSettings.configuration(ruleId: "RULE", hubBaseURL: text, clientId: "", clientSecret: "").hubBaseURL
        }
        #expect(hubURL("http://example.com") == nil)
        #expect(hubURL("https://hub.example.com") == URL(string: "https://hub.example.com"))
    }
}

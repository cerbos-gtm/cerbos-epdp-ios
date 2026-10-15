#if canImport(WebKit)
import Foundation
import Testing

@testable import CerbosEmbeddedPDP

@Suite("Configuration validation")
struct ConfigurationValidationTests {
    @Test(
        "accepts https and loopback http Hub URLs",
        arguments: [
            nil,
            "https://api.cerbos.cloud",
            "HTTPS://hub.example.com:8443/",
            "http://localhost:3592",
            "http://127.0.0.1:9",
            "http://[::1]:3592",
        ])
    func acceptsSecureOrLoopback(urlString: String?) {
        let url = urlString.map { URL(string: $0)! }
        #expect(CerbosEmbeddedPDP.validate(hubBaseURL: url) == nil)
    }

    @Test(
        "rejects insecure and relative Hub URLs",
        arguments: [
            "http://hub.example.com",
            "http://10.0.0.5:3592",
            "api.example.com",
            "ftp://hub.example.com",
        ])
    func rejectsInsecure(urlString: String) throws {
        let error = try #require(CerbosEmbeddedPDP.validate(hubBaseURL: URL(string: urlString)!))
        guard case .invalidRequest(let reason) = error else {
            Issue.record("expected invalidRequest, got \(error)")
            return
        }
        #expect(reason.contains(urlString))
    }

    @Test("an insecure Hub URL fails start() as a configuration error, without touching the network")
    @MainActor
    func startFailsFast() async {
        let pdp = CerbosEmbeddedPDP(
            configuration: {
                var configuration = CerbosEmbeddedPDP.Configuration(ruleId: "AVGB9RP6HFBL")
                configuration.hubBaseURL = URL(string: "http://hub.example.com")!
                return configuration
            }())
        await pdp.start()
        // No web view means the page never loaded, so nothing reached the network.
        #expect(pdp.host.webView == nil)
        guard case .failed(.invalidRequest) = pdp.status else {
            Issue.record("expected a configuration failure, got \(pdp.status)")
            return
        }
    }
}
#endif

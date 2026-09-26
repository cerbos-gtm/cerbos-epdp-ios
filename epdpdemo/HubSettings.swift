import CerbosEmbeddedPDP
import Foundation

/// The Hub settings the demo persists: rule, URL and client ID in `UserDefaults`, the secret in the Keychain.
enum HubSettings {
    static let defaultRuleId = "AVGB9RP6HFBL"

    enum Key {
        static let ruleId = "cerbos.hub.ruleId"
        static let baseURL = "cerbos.hub.baseURL"
        static let clientId = "cerbos.hub.clientId"
    }

    static func configuration(
        ruleId: String, hubBaseURL: String, clientId: String, clientSecret: String
    )
        -> CerbosEmbeddedPDP.Configuration
    {
        var configuration = CerbosEmbeddedPDP.Configuration(ruleId: ruleId)
        configuration.hubBaseURL = HubURLValidation.url(from: hubBaseURL)
        let clientId = clientId.trimmingCharacters(in: .whitespaces)
        if !clientId.isEmpty, !clientSecret.isEmpty {
            configuration.credentials = .init(clientId: clientId, clientSecret: clientSecret)
        }
        return configuration
    }

    /// The configuration last applied in the settings sheet, used for the first start.
    static func savedConfiguration(defaults: UserDefaults = .standard) -> CerbosEmbeddedPDP.Configuration {
        configuration(
            ruleId: defaults.string(forKey: Key.ruleId) ?? defaultRuleId,
            hubBaseURL: defaults.string(forKey: Key.baseURL) ?? "",
            clientId: defaults.string(forKey: Key.clientId) ?? "",
            clientSecret: Keychain.string(for: Keychain.clientSecretKey) ?? ""
        )
    }
}

import CerbosEmbeddedPDP
import SwiftUI

@main
struct epdpdemoApp: App {
    // One PDP for the whole app: each instance owns a web view and compiles the engine.
    @State private var pdp = CerbosEmbeddedPDP(configuration: HubSettings.savedConfiguration())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pdp)
                .task { await pdp.start() }
        }
    }
}

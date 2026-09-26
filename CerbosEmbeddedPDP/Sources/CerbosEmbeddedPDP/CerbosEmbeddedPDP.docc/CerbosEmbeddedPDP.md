# ``CerbosEmbeddedPDP``

Evaluate Cerbos policies on the device, with policy bundles from Cerbos Hub.

## Overview

``CerbosEmbeddedPDP/CerbosEmbeddedPDP`` runs the Cerbos WebAssembly engine in a hidden web view.
It downloads the policy bundle for a Cerbos Hub embedded PDP rule, keeps it up to date in the
background, and caches it on disk so the app can start offline. Decisions are evaluated locally and
reach Swift in well under a millisecond.

Create one instance for the app and share it through the SwiftUI environment:

```swift
@main
struct MyApp: App {
    @State private var pdp = CerbosEmbeddedPDP(configuration: .init(ruleId: "AVGB9RP6HFBL"))

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(pdp)
                .task { await pdp.start() }
        }
    }
}
```

Then check everything a screen needs in one call:

```swift
let response = try await pdp.checkResources(CheckResourcesRequest(
    principal: Principal(id: "alice", roles: ["USER"]),
    resources: [ResourceCheck(resource: Resource(kind: "document", id: "1"), actions: ["read", "update"])]
))
let canUpdate = response.isAllowed(kind: "document", id: "1", action: "update")
```

## Topics

### Running the engine

- ``CerbosEmbeddedPDP/CerbosEmbeddedPDP``
- ``CerbosEmbeddedPDP/CerbosEmbeddedPDP/Configuration``
- ``CerbosEmbeddedPDP/CerbosEmbeddedPDP/Status``
- ``CerbosError``

### Checking access

- ``CheckResourcesRequest``
- ``CheckResourcesResponse``
- ``CheckResourceRequest``
- ``CheckResult``
- ``IsAllowedRequest``
- ``Principal``
- ``Resource``
- ``ResourceCheck``
- ``AuxData``
- ``JWT``

### Query planning

- ``PlanResourcesRequest``
- ``PlanResourcesResponse``

### Policy bundles

- ``BundleInfo``
- ``PolicyBundleCache``
- ``PolicyUpdate``

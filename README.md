# Cerbos embedded PDP on iOS

[![CI](https://github.com/cerbos-gtm/cerbos-epdp-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/cerbos-gtm/cerbos-epdp-ios/actions/workflows/ci.yml)

Runs a [Cerbos](https://www.cerbos.dev) embedded policy decision point (ePDP) on iOS. Policies
come from Cerbos Hub, are evaluated on the device by the Cerbos WebAssembly engine, update in the
background, and are cached for offline starts.

```
epdpdemo/            SwiftUI demo app (iOS 26, Swift 6)
CerbosEmbeddedPDP/   Swift package wrapping the engine (iOS 18+, macOS 15+)
CerbosBridge/        Node project that builds the JavaScript bridge and stages the WASM
```

## Getting started

**Run the demo.** With Xcode 26, open `epdpdemo.xcodeproj` and run. It uses a public Hub rule, so
no account is needed.

**Use the package.** Add `CerbosEmbeddedPDP/` to your app as a local package
(**File > Add Package Dependencies… > Add Local…**):

```swift
import CerbosEmbeddedPDP

let pdp = CerbosEmbeddedPDP(configuration: .init(ruleId: "AVGB9RP6HFBL"))
await pdp.start()

let document = Resource(kind: "resource", id: "1", attributes: ["ownerId": "alice"])
let response = try await pdp.checkResources(CheckResourcesRequest(
    principal: Principal(id: "alice", roles: ["USER"]),
    resources: [ResourceCheck(resource: document, actions: ["read", "update"])]
))
let canUpdate = response.isAllowed(kind: "resource", id: "1", action: "update")
```

`checkResource`, `isAllowed` and `planResources` are also available. The class is `@Observable`, so
`status`, `bundle`, `lastPolicyUpdate` and `logs` can drive SwiftUI directly.

**Use your own Hub rule.** Create an
[ePDP rule](https://docs.cerbos.dev/cerbos-hub/deployments-epdp-rules) in your Hub deployment and
pass its ID as `ruleId`; set `credentials` if the rule requires authentication. In the demo, enter
them under **Cerbos Hub settings** in the toolbar (the secret is kept in the Keychain).

**JWTs.** Pass `AuxData(jwt:)` with a request and set `Configuration.jwtDecoder`. Your decoder
verifies the token natively; the engine only sees the claims.

## How it works

The engine (`server.wasm`, about 20 MB) is Go compiled for a JavaScript host, and `JSContext` has
no WebAssembly, so it runs in a hidden `WKWebView`. Your app only talks to `CerbosEmbeddedPDP`.

```
SwiftUI ─▶ CerbosEmbeddedPDP (@Observable, @MainActor)
              │  callAsyncJavaScript(JSON)          ▲ script messages (JSON events)
              ▼                                     │
           hidden WKWebView ── cerbos-epdp://app/  (custom URL scheme, app bundle)
              ├─ index.html + bridge.js  (@cerbos/embedded-client, bundled with esbuild)
              └─ server.wasm             (streamed into WebAssembly.compileStreaming)
                        │
                        └─ Cerbos Hub: BundleService/GetBundle
```

The page, bridge and engine ship as package resources served by a `WKURLSchemeHandler`; only
policy bundles come from the network. Requests mirror `@cerbos/core` as `Codable` types.

## Runtime behaviour

- **Offline cache.** The latest bundle is saved to Application Support (excluded from backup),
  keyed by Hub URL, rule ID and scopes. It is used only when the *first* download fails for network
  or server reasons (offline, `initialLoadTimeout` of 20 s, 5xx/408/429, captive portal). A 4xx
  (unknown or disabled rule, revoked credentials) fails `start()`, so revocation takes effect on
  the next cold start.
- **Timeouts.** `startTimeout` (120 s) and `requestTimeout` (30 s, per check) throw
  `CerbosError.timeout`.
- **Lifecycle.** `start()` is idempotent. `reconfigure(_:)` changes rule or credentials without
  recompiling the engine; `restart()` rebuilds everything. A killed web content process is rebuilt
  automatically and the interrupted check retried once. Call `checkHealth()` on returning to the
  foreground so a dead page is rebuilt before the first real check.
- **Updates.** Hub is polled every `updateInterval` (60 s; `nil` disables). Set
  `activateOnLoad = false` to hold updates in `pendingBundle` until `activatePendingBundle()`.
- **One instance per rule.** Each instance owns a web view and compiles the engine; share one from
  your app model rather than creating one per screen.
- **Latency.** A decision reaches Swift in about 0.2 ms (M-series Mac, release build); roughly
  0.13 ms of that is the web view round trip, so batch what a screen needs into one
  `checkResources` call. `start()` runs a throwaway check before reporting ready, so the first
  real decision skips the ~20 ms JIT warm-up.
- **Debugging.** In Debug builds the web view is inspectable from Safari's Develop menu.

## Upgrading the Cerbos SDK

```sh
cd CerbosBridge
npm install                         # after bumping @cerbos/* in package.json
npm run typecheck && npm run build  # regenerates CerbosEmbeddedPDP/Sources/CerbosEmbeddedPDP/Resources/web
npm test                            # runs the built bridge in Node against the real WASM and Hub
```

The build verifies the `server.wasm` checksum and records versions in `manifest.json`. Generated
assets are committed, so the Xcode project builds without Node. `npm run bench` measures in-page
decision latency (excluding the native round trip); for the full round trip run
`CERBOS_BENCH=1 swift test -c release --filter DecisionLatencyBenchmark` in `CerbosEmbeddedPDP`.

## Tests and CI

- `cd CerbosEmbeddedPDP && swift test`: unit tests (macOS, Linux) and Hub integration tests (macOS).
- `cd CerbosBridge && npm test`: bridge smoke test in Node, including the offline-cache rules.
- Xcode test targets: the integration test inside the app on the simulator, and a UI test.

Integration tests need network access and use a public demo rule; override it with
`CERBOS_RULE_ID` (`TEST_RUNNER_CERBOS_RULE_ID` under `xcodebuild`). CI runs everything on pull
requests and pushes to `main`, checks that committed bridge assets match a fresh build, and runs
`swift format lint --strict`.

## Security notes

- Client credentials in a shipped app can be extracted. Prefer public rules with policy filtering,
  or a backend-for-frontend, as the
  [Hub docs recommend](https://docs.cerbos.dev/cerbos-hub/deployments-epdp-rules#_browser_applications).
- The page's Content Security Policy allows only the bundled script, WebAssembly and HTTPS (or
  localhost) connections; `hubBaseURL` is validated the same way. The page uses a non-persistent
  data store and never navigates off its own scheme.
- The page opts out of Lockdown Mode, which removes WebAssembly; it only runs bundled code.

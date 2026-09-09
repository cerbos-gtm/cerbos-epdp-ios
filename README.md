# Cerbos embedded PDP on iOS

[![CI](https://github.com/cerbos-gtm/cerbos-epdp-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/cerbos-gtm/cerbos-epdp-ios/actions/workflows/ci.yml)

A SwiftUI demo that runs a [Cerbos](https://www.cerbos.dev) embedded policy decision point
(ePDP) on the device: policies are downloaded from Cerbos Hub, evaluated locally by the Cerbos
WebAssembly engine, kept up to date in the background, and cached for offline starts.

```
epdpdemo/            SwiftUI demo app (iOS 26, Swift 6)
CerbosEmbeddedPDP/   Swift package: the ePDP engine wrapper (`CerbosEmbeddedPDP`)
CerbosBridge/        Node project that builds the JavaScript bridge and stages the WASM assets
```

## How it works

The current Cerbos ePDP has two parts (see the
[Hub docs](https://docs.cerbos.dev/cerbos-hub/deployments-epdp-rules)):

- `@cerbos/embedded-server` ships `server.wasm`, the policy evaluation engine (Go compiled to
  WebAssembly, about 20 MB). It contains no policies.
- `@cerbos/embedded-client` downloads a policy bundle for an *ePDP rule* from Cerbos Hub, loads it
  into the engine, and polls Hub for updates.

The engine is built for a JavaScript host (`GOOS=js`), so on iOS it runs inside a hidden `WKWebView`
where WebKit gives WebAssembly a JIT. There is no JavaScriptCore-only route: `JSContext` has no
WebAssembly, and running a 20 MB Go runtime in a native interpreter would take seconds to start.
The web view is an implementation detail; the app only ever talks to `CerbosEmbeddedPDP`.

```
SwiftUI ─▶ CerbosEmbeddedPDP (@Observable, @MainActor)
              │  callAsyncJavaScript(JSON)          ▲ script messages (JSON events)
              ▼                                     │
           hidden WKWebView ── cerbos-epdp://app/  (custom URL scheme, app bundle)
              ├─ index.html + bridge.js  (@cerbos/embedded-client bundled with esbuild)
              └─ server.wasm            (streamed into WebAssembly.instantiateStreaming)
                        │
                        └─ Cerbos Hub: BundleService/GetBundle (rule ID, optional credentials)
```

### What the wrapper adds on top of the SDK

- **No CDN, no network for the runtime.** The bridge script and `server.wasm` are app resources,
  served to the page by a `WKURLSchemeHandler` with the right MIME type. The WASM is memory-mapped
  and streamed, never base64-encoded or copied through `postMessage`.
- **Offline cold start.** The SDK keeps policies in memory only. The bridge observes the Hub
  `GetBundle` responses, hands each bundle to Swift for persistence (`PolicyBundleCache`,
  Application Support, excluded from backup), and replays the last one if the initial download
  fails. Later update checks always go to Hub.
- **Typed, structured bridge.** Requests are `Codable` types mirroring `@cerbos/core`; results,
  gRPC status codes and validation errors come back as `CerbosError` / `BridgeError`. Nothing is
  string-interpolated into JavaScript.
- **Lifecycle handling.** Idempotent `start()`, readiness with timeout, automatic rebuild when WebKit
  discards the content process in the background, `stop()`/`restart()` for credential changes.
- **JWT verification stays native.** Pass `AuxData.jwt` and supply `Configuration.jwtDecoder`; the
  bridge asks the app to verify and decode the token, the engine only sees the claims.
- **Diagnostics.** Bridge logs, bundle metadata (ID, rule revision, source) and update outcomes are
  observable; in Debug builds the web view is inspectable from Safari.

## Using `CerbosEmbeddedPDP`

```swift
import CerbosEmbeddedPDP

var configuration = CerbosEmbeddedPDP.Configuration(ruleId: "AVGB9RP6HFBL")
configuration.credentials = .init(clientId: clientId, clientSecret: clientSecret) // if the rule requires it
configuration.updateInterval = .seconds(60)
configuration.jwtDecoder = { jwt in try await MyAuth.verify(jwt.token) }

let pdp = CerbosEmbeddedPDP(configuration: configuration)
await pdp.start()

let response = try await pdp.checkResources(CheckResourcesRequest(
    principal: Principal(id: "alice", roles: ["USER"], attributes: ["tier": "PREMIUM"]),
    resources: [
        ResourceCheck(resource: Resource(kind: "resource", id: "1", attributes: ["ownerId": "alice"]),
                      actions: ["read", "update"])
    ]
))
response.isAllowed(kind: "resource", id: "1", action: "update")
```

`checkResource`, `isAllowed` and `planResources` are also available. Batch the resources a screen
needs into one `checkResources` call: each call is one round trip to the web content process.

Observable state: `status`, `bundle`, `server`, `lastPolicyUpdate`, `logs`.

## Building

Requirements: Xcode 26 (Swift 6.2), iOS 26 SDK. Node is only needed to upgrade the Cerbos SDK.

Open `epdpdemo.xcodeproj` and run. The demo starts with a public demo rule; enter your own rule ID
(and client credentials for authenticated rules) and tap **Restart**. The secret is stored in the
Keychain, never in source.

### Upgrading the Cerbos SDK / engine

```sh
cd CerbosBridge
npm install                       # bump @cerbos/* versions in package.json first
npm run typecheck && npm run build  # regenerates CerbosEmbeddedPDP/Sources/.../Resources/web
npm test                          # runs the built bridge in Node against the real WASM and Hub
```

`build.mjs` verifies `server.wasm` against the checksum published in `@cerbos/embedded-server`
and writes `manifest.json` with the versions in use. The generated assets are committed so the
Xcode project builds without Node.

### Tests

- `cd CerbosEmbeddedPDP && swift test` — request/response coding, bridge events, bundle cache
  (runs on macOS and Linux).
- `cd CerbosBridge && npm test` — end-to-end bridge smoke test: online init, checks, plan, JWT
  callback, structured errors, offline start from the cached bundle.
- Integration test (`epdpdemoTests/EmbeddedPDPIntegrationTests.swift`, and a macOS copy in the
  package tests): starts a real `CerbosEmbeddedPDP` against the public demo rule inside the app on
  the simulator, runs checks and a plan, verifies the bundle was cached, then restarts with an
  unreachable Hub URL and asserts it comes up from the cache. Needs network access; set
  `CERBOS_RULE_ID` to use another public rule.
- The Xcode test target also covers the demo's request builder.
- CI (`.github/workflows/ci.yml`) runs all of the above on every push and pull request: the bridge
  on Node 22 (and checks the committed assets match the build), the package on Linux and macOS,
  and the app on the iOS simulator with Xcode 26. Dependabot keeps the npm packages and workflow
  actions current. Formatting is enforced with `swift format` (`.swift-format`).

## Behaviour worth knowing

- **Offline cache policy.** The last bundle is replayed only when the first download fails for a
  reason that is not the client's fault: no network, DNS failure, a stalled connection (aborted
  after `initialLoadTimeout`, 20 s by default), a Hub 5xx/429, or a captive portal answering with
  HTML. A 4xx (disabled rule, unknown rule, bad or revoked credentials) fails `start()` instead, so
  revoking access takes effect on the next cold start.
- **Timeouts.** `start()` fails with `CerbosError.timeout` after `startTimeout` (120 s), and each
  check after `requestTimeout` (30 s). Evaluation takes milliseconds; these only fire on a stuck
  engine or a hung network.
- **Deferred activation.** With `activateOnLoad = false`, `bundle` stays on the active bundle and a
  downloaded update appears in `pendingBundle` until `activatePendingBundle()`.
- **Web view hardening.** The page opts out of Lockdown Mode for its own trusted content (Lockdown
  removes WebAssembly), runs under a Content Security Policy that allows only the bundled script,
  WebAssembly compilation and HTTPS connections, and compiles the engine module once per page so
  `reconfigure(_:)` and policy reloads never recompile it. A lost web content process is rebuilt
  automatically (at most `maximumRestarts` per `restartWindow`), a check interrupted by that
  loss is retried once, and `checkHealth()` on returning to the foreground rebuilds a dead page
  before the first real check. Failures are classified as `engine` (WebAssembly missing or
  broken), `policySource` (Hub rejected the request) or `initialisation`.
- **Update cadence.** The SDK's loader polls on its interval and has no "check now"; after a long
  time in the background the next check happens within one interval. `restart()` forces a fresh
  download at the cost of recompiling the WebAssembly module.
- **One instance per rule.** Each `CerbosEmbeddedPDP` owns a web view and compiles the 20 MB engine.
  Share one instance (for example from your app model) rather than creating one per screen.
- **Cache keys.** The offline cache is keyed by Hub URL (trailing slashes ignored), rule ID and
  scopes; changing any of them starts from an empty cache.
- **Plain-HTTP Hub URLs** (self-hosted, non-TLS) are blocked by App Transport Security unless the
  app adds an exception.
- **CI depends on the public demo rule** and on Hub being reachable from the runners.

## Security notes

- Client credentials in a shipped app can be extracted; prefer public rules with policy filtering
  (resources, actions, roles, scopes) or a backend-for-frontend, as the Hub docs recommend.
- The page never navigates away from its own scheme and has a non-persistent website data store.

// In-page decision latency: `CerbosBridge.invoke`, JSON in to JSON out, in Node against the built
// bridge, the real server.wasm and a Hub bundle. The native round trip is measured by the Swift
// package's DecisionLatencyBenchmark.
// Usage: npm run build && npm run bench [-- <iterations>]
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = path.dirname(fileURLToPath(import.meta.url));
const webDir = path.resolve(here, "..", "..", "CerbosEmbeddedPDP", "Sources", "CerbosEmbeddedPDP", "Resources", "web");
const ruleId = process.env.CERBOS_RULE_ID ?? "AVGB9RP6HFBL";
const iterations = Number(process.argv[2] ?? 2000);

const wasmBytes = await readFile(path.join(webDir, "server.wasm"));
const realFetch = globalThis.fetch.bind(globalThis);
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (url === "server.wasm" || url.endsWith("/server.wasm")) {
    return new Response(wasmBytes, { status: 200, headers: { "content-type": "application/wasm" } });
  }
  return realFetch(input, init);
};
globalThis.window = globalThis;
globalThis.webkit = { messageHandlers: { cerbosEvents: { postMessage: () => {} } } };
vm.runInThisContext(await readFile(path.join(webDir, "bridge.js"), "utf8"), { filename: "bridge.js" });
const bridge = globalThis.CerbosBridge;

const init = JSON.parse(await bridge.invoke("init", JSON.stringify({ ruleId, updateIntervalSeconds: 0 })));
if (!init.ok) throw new Error(init.error.message);

// The demo app's request: one resource, five actions, metadata included.
const demo = JSON.stringify({
  principal: { id: "alice@example.com", roles: ["USER"], attr: { tier: "PREMIUM" } },
  resources: [
    { resource: { kind: "resource", id: "1", attr: { ownerId: "alice@example.com" } }, actions: ["read", "create", "update", "delete", "publish"] },
  ],
  includeMetadata: true,
});
// A screen's worth of resources in one call.
const batch = JSON.stringify({
  principal: { id: "alice@example.com", roles: ["USER"], attr: { tier: "PREMIUM" } },
  resources: Array.from({ length: 50 }, (_, i) => ({
    resource: { kind: "resource", id: String(i), attr: { ownerId: i % 2 ? "alice@example.com" : "bob@example.com" } },
    actions: ["read", "create", "update", "delete", "publish"],
  })),
});

async function measure(name, method, params) {
  for (let i = 0; i < 200; i++) await bridge.invoke(method, params);
  const samples = new Float64Array(iterations);
  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    await bridge.invoke(method, params);
    samples[i] = performance.now() - start;
  }
  samples.sort();
  const at = (q) => samples[Math.min(samples.length - 1, Math.floor(q * samples.length))].toFixed(3);
  console.log(`${name.padEnd(28)} p50 ${at(0.5)} ms  p90 ${at(0.9)} ms  p99 ${at(0.99)} ms`);
}

await measure("checkResources (demo)", "checkResources", demo);
await measure("checkResources (50 x 5)", "checkResources", batch);
await measure("isAllowed", "isAllowed", JSON.stringify({ principal: JSON.parse(demo).principal, resource: JSON.parse(demo).resources[0].resource, action: "read" }));
await bridge.invoke("stop", null);

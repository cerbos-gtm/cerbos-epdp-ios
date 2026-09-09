import { fromBinary } from "@bufbuild/protobuf";
import { GetBundleResponseSchema } from "@cerbos/api/cerbos/cloud/epdp/v2/epdp_pb";

/**
 * Offline cache for Cerbos Hub policy bundles.
 *
 * `@cerbos/embedded-client` keeps the downloaded policy bundle in memory only, so a cold start
 * without connectivity has no policies to evaluate. This module transparently observes the
 * Hub `BundleService/GetBundle` responses made by the client's `PolicyLoader`:
 *
 * - every successful response containing a bundle is handed to the native host for persistence;
 * - if the *initial* load fails (offline, DNS, Hub outage), the most recently persisted response
 *   for the same rule is replayed once, so the app starts with the last known policies.
 *
 * Subsequent update checks still go to Hub as usual; a failed update never replays the cache,
 * because the loader already holds an active bundle in that case.
 */

export interface BundleInfo {
  bundleId: string;
  ruleRevision: string;
  source: "network" | "cache";
  receivedAt: string;
}

export interface BundleCacheHost {
  persist(entry: { key: string; body: string; bundleId: string; ruleRevision: string }): void;
  log(level: "debug" | "info" | "warn" | "error", message: string): void;
}

const getBundlePath = "/cerbos.cloud.epdp.v2.BundleService/GetBundle";

export class HubBundleCache {
  private installed = false;
  private key = "";
  private cached: Uint8Array | undefined;
  private cachedContentType = "application/proto";
  private loadedOnce = false;
  private _current: BundleInfo | undefined;

  public onBundle?: (info: BundleInfo) => void;

  public constructor(private readonly host: BundleCacheHost) {}

  public get current(): BundleInfo | undefined {
    return this._current;
  }

  /** Prepares the cache for a (re)initialised client. */
  public configure(key: string, cachedBody: string | undefined): void {
    this.key = key;
    this.loadedOnce = false;
    this._current = undefined;
    this.cached = cachedBody ? decodeBase64(cachedBody) : undefined;
    this.install();
  }

  private install(): void {
    if (this.installed) {
      return;
    }
    this.installed = true;

    const originalFetch = globalThis.fetch.bind(globalThis);

    globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      if (!this.isGetBundle(input)) {
        return originalFetch(input, init);
      }

      let response: Response;
      try {
        response = await originalFetch(input, init);
      } catch (error) {
        const fallback = this.fallback(`network error: ${String(error)}`);
        if (fallback) {
          return fallback;
        }
        throw error;
      }

      if (!response.ok) {
        const fallback = this.fallback(`HTTP ${response.status}`);
        if (fallback) {
          void response.body?.cancel().catch(() => undefined);
          return fallback;
        }
        return response;
      }

      await this.observe(response);
      return response;
    };
  }

  private isGetBundle(input: RequestInfo | URL): boolean {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    return url.includes(getBundlePath);
  }

  private async observe(response: Response): Promise<void> {
    try {
      const bytes = new Uint8Array(await response.clone().arrayBuffer());
      const message = fromBinary(GetBundleResponseSchema, bytes, { readUnknownFields: false });

      switch (message.result.case) {
        case "bundle": {
          const metadata = message.result.value.metadata;
          const bundleId = metadata?.bundleId ?? "";
          const ruleRevision = metadata?.ruleRevision.toString() ?? "";
          this.cached = bytes;
          this.cachedContentType = response.headers.get("content-type") ?? this.cachedContentType;
          this.loadedOnce = true;
          this.setCurrent({ bundleId, ruleRevision, source: "network", receivedAt: new Date().toISOString() });
          this.host.persist({ key: this.key, body: encodeBase64(bytes), bundleId, ruleRevision });
          break;
        }
        case "notModified":
          this.loadedOnce = true;
          break;
        default:
          break;
      }
    } catch (error) {
      // Not a binary bundle response (for example an error payload); nothing to cache.
      this.host.log("debug", `Ignoring GetBundle response: ${String(error)}`);
    }
  }

  private fallback(reason: string): Response | undefined {
    if (this.loadedOnce || !this.cached) {
      return undefined;
    }

    let bundleId = "";
    let ruleRevision = "";
    try {
      const message = fromBinary(GetBundleResponseSchema, this.cached, { readUnknownFields: false });
      if (message.result.case === "bundle") {
        bundleId = message.result.value.metadata?.bundleId ?? "";
        ruleRevision = message.result.value.metadata?.ruleRevision.toString() ?? "";
      }
    } catch {
      this.host.log("warn", "Cached policy bundle is unreadable; ignoring it.");
      this.cached = undefined;
      return undefined;
    }

    this.loadedOnce = true;
    this.host.log("warn", `Policy bundle download failed (${reason}); using cached bundle ${bundleId}.`);
    this.setCurrent({ bundleId, ruleRevision, source: "cache", receivedAt: new Date().toISOString() });

    return new Response(this.cached.slice(), {
      status: 200,
      headers: { "content-type": this.cachedContentType },
    });
  }

  private setCurrent(info: BundleInfo): void {
    this._current = info;
    this.onBundle?.(info);
  }
}

export function encodeBase64(bytes: Uint8Array): string {
  const withToBase64 = bytes as Uint8Array & { toBase64?: () => string };
  if (typeof withToBase64.toBase64 === "function") {
    return withToBase64.toBase64();
  }
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

export function decodeBase64(base64: string): Uint8Array {
  const ctor = Uint8Array as typeof Uint8Array & { fromBase64?: (value: string) => Uint8Array };
  if (typeof ctor.fromBase64 === "function") {
    return ctor.fromBase64(base64);
  }
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

import { fromBinary } from "@bufbuild/protobuf";
import { GetBundleResponseSchema } from "@cerbos/api/cerbos/cloud/epdp/v2/epdp_pb";

/**
 * Offline cache for Hub policy bundles. `@cerbos/embedded-client` keeps bundles in memory only, so
 * this wraps `fetch` to observe `GetBundle` responses and hand each bundle to the native host.
 *
 * If the *initial* load fails for network or server reasons (offline, stalled, 5xx, captive
 * portal), the persisted response is replayed once. A 4xx (disabled rule, revoked credentials) is
 * never masked, and later update failures never replay, since the loader already has a bundle.
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
  private initialLoadTimeoutMs = 20_000;
  /**
   * Bumped by `configure()`. A request from an earlier session belongs to a stopped loader; it must
   * not be observed or replay the cache, or it would consume the current session's fallback.
   */
  private session = 0;
  private _current: BundleInfo | undefined;

  public onBundle?: (info: BundleInfo) => void;

  public constructor(private readonly host: BundleCacheHost) {}

  public get current(): BundleInfo | undefined {
    return this._current;
  }

  /** Prepares the cache for a (re)initialised client. */
  public configure(key: string, cachedBody: string | undefined, initialLoadTimeoutMs = 20_000): void {
    this.session++;
    this.key = key;
    this.initialLoadTimeoutMs = initialLoadTimeoutMs;
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

      const session = this.session;
      const initialLoad = !this.loadedOnce;
      let response: Response;
      try {
        response = await originalFetch(input, initialLoad ? this.withInitialLoadTimeout(init) : init);
      } catch (error) {
        if (session !== this.session) {
          // Superseded while in flight (typically the abort from stopping the old loader).
          throw error;
        }
        // Offline, DNS failure, connection refused, or the initial-load timeout.
        const fallback = this.fallback(`network error: ${String(error)}`);
        if (fallback) {
          return fallback;
        }
        throw error;
      }

      if (session !== this.session) {
        // Superseded while in flight: hand the response to the (already stopped) loader untouched.
        return response;
      }

      if (!response.ok) {
        // Only server-side trouble falls back. Replaying on a client error would let a revoked
        // bundle keep working on every cold start.
        if (this.isRetryableStatus(response.status)) {
          const fallback = this.fallback(`HTTP ${response.status}`);
          if (fallback) {
            void response.body?.cancel().catch(() => undefined);
            return fallback;
          }
        }
        return response;
      }

      const validated = await this.observe(response);
      if (validated === "invalid") {
        // A 200 that is not a bundle (captive portal, proxy error page, HTML login page).
        const fallback = this.fallback("response is not a policy bundle");
        if (fallback) {
          return fallback;
        }
      }
      return response;
    };
  }

  /** Bounds the very first bundle download so a stalled connection cannot block start-up forever. */
  private withInitialLoadTimeout(init: RequestInit | undefined): RequestInit | undefined {
    if (this.initialLoadTimeoutMs <= 0 || typeof AbortSignal.timeout !== "function") {
      return init;
    }
    const timeout = AbortSignal.timeout(this.initialLoadTimeoutMs);
    const signal = init?.signal && typeof AbortSignal.any === "function" ? AbortSignal.any([init.signal, timeout]) : timeout;
    return { ...init, signal };
  }

  private isRetryableStatus(status: number): boolean {
    return status >= 500 || status === 408 || status === 429;
  }

  private isGetBundle(input: RequestInfo | URL): boolean {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    return url.includes(getBundlePath);
  }

  private async observe(response: Response): Promise<"bundle" | "notModified" | "invalid"> {
    let bytes: Uint8Array;
    try {
      bytes = new Uint8Array(await response.clone().arrayBuffer());
    } catch (error) {
      this.host.log("warn", `Could not read GetBundle response: ${String(error)}`);
      return "invalid";
    }

    let message;
    try {
      message = fromBinary(GetBundleResponseSchema, bytes, { readUnknownFields: false });
    } catch (error) {
      this.host.log("warn", `GetBundle response is not a bundle: ${String(error)}`);
      return "invalid";
    }

    switch (message.result.case) {
      case "bundle": {
        const metadata = message.result.value.metadata;
        const bundleId = metadata?.bundleId ?? "";
        const ruleRevision = metadata?.ruleRevision.toString() ?? "";
        if (!bundleId) {
          return "invalid";
        }
        this.cached = bytes;
        this.cachedContentType = response.headers.get("content-type") ?? this.cachedContentType;
        this.loadedOnce = true;
        this.setCurrent({ bundleId, ruleRevision, source: "network", receivedAt: new Date().toISOString() });
        this.host.persist({ key: this.key, body: encodeBase64(bytes), bundleId, ruleRevision });
        return "bundle";
      }
      case "notModified":
        this.loadedOnce = true;
        return "notModified";
      default:
        return "invalid";
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

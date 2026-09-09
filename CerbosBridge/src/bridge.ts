/**
 * WebKit entry point. Loaded by `index.html` inside the hidden `WKWebView` that hosts the
 * Cerbos embedded PDP. The native side calls `CerbosBridge.invoke(method, paramsJSON)` via
 * `callAsyncJavaScript` and receives events through the `cerbosEvents` script message handler.
 */
import type { JWT } from "@cerbos/core";

import type { BridgeEvent } from "./core.js";
import { CerbosBridgeCore } from "./core.js";

interface MessageHandler {
  postMessage(message: unknown): unknown;
}

interface WebKitWindow {
  webkit?: {
    messageHandlers?: {
      cerbosEvents?: MessageHandler;
    };
  };
  CerbosBridge?: {
    invoke(method: string, paramsJSON: string | null | undefined): Promise<string>;
    resolveCallback(id: string, ok: boolean, payload: string): boolean;
  };
}

const webkitWindow = globalThis as unknown as WebKitWindow;
const eventHandler = webkitWindow.webkit?.messageHandlers?.cerbosEvents;

function emit(event: BridgeEvent): void {
  try {
    eventHandler?.postMessage(JSON.stringify(event));
  } catch {
    // The host is gone; nothing useful to do.
  }
}

// Native callbacks (JWT decoding) are request/response over two one-way channels: the bridge
// emits a `jwtDecode` event and the host answers with `CerbosBridge.resolveCallback`.
const callbackTimeoutMs = 30_000;
let callbackCounter = 0;
const pendingCallbacks = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();

function requestFromHost(event: Extract<BridgeEvent, { id: string }>): Promise<unknown> {
  return new Promise((resolve, reject) => {
    pendingCallbacks.set(event.id, { resolve, reject });
    setTimeout(() => {
      if (pendingCallbacks.delete(event.id)) {
        reject(new Error("Timed out waiting for the native host"));
      }
    }, callbackTimeoutMs);
    emit(event);
  });
}

const core = new CerbosBridgeCore({
  emit,
  loadWasm: async () => {
    // Served by the native URL scheme handler with `Content-Type: application/wasm`,
    // so WebKit compiles it with `WebAssembly.instantiateStreaming` (no base64, no copies).
    const response = await fetch("server.wasm");
    if (!response.ok) {
      throw new Error(`Failed to load server.wasm: HTTP ${response.status}`);
    }
    return response;
  },
  decodeJWTPayload: async (jwt: JWT) => {
    const id = `jwt-${Date.now()}-${callbackCounter++}`;
    const payload = await requestFromHost({ type: "jwtDecode", id, token: jwt.token, keySetId: jwt.keySetId ?? "" });
    if (typeof payload !== "object" || payload === null) {
      throw new Error("Native decodeJWTPayload returned an invalid payload");
    }
    return payload as Record<string, never>;
  },
});

webkitWindow.CerbosBridge = {
  invoke: (method, paramsJSON) => core.invokeJSON(method, paramsJSON),
  resolveCallback: (id, ok, payload) => {
    const pending = pendingCallbacks.get(id);
    if (!pending) {
      return false;
    }
    pendingCallbacks.delete(id);
    if (ok) {
      try {
        pending.resolve(JSON.parse(payload));
      } catch (error) {
        pending.reject(new Error(`Invalid callback payload: ${String(error)}`));
      }
    } else {
      pending.reject(new Error(payload || "Native callback failed"));
    }
    return true;
  },
};

// Surface uncaught problems from the headless page in the native logs.
if (typeof globalThis.addEventListener === "function") {
  globalThis.addEventListener("error", (event) => {
    emit({ type: "log", level: "error", message: `Uncaught error: ${event.message}` });
  });
  globalThis.addEventListener("unhandledrejection", (event) => {
    emit({ type: "log", level: "error", message: `Unhandled rejection: ${String(event.reason)}` });
  });
}
for (const level of ["warn", "error"] as const) {
  const original = console[level].bind(console);
  console[level] = (...args: unknown[]) => {
    original(...args);
    emit({ type: "log", level, message: args.map((arg) => (arg instanceof Error ? arg.message : String(arg))).join(" ") });
  };
}

emit({ type: "bridgeReady" });

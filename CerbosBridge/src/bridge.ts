/**
 * WebKit entry point, loaded by `index.html` in the hidden `WKWebView`. Swift calls
 * `CerbosBridge.invoke(method, paramsJSON)` via `callAsyncJavaScript`; events go back through the
 * `cerbosEvents` script message handler.
 */
import type { JWT } from "@cerbos/core";

import type { BridgeEvent } from "./core.js";
import { CerbosBridgeCore, EngineError } from "./core.js";

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

// Compiled once per page and reused by every `init`, so reconfiguring or retrying a failed policy
// load skips the 20 MB compile. Only a new page (such as after a lost content process) recompiles.
let compiledModule: Promise<WebAssembly.Module> | undefined;

function loadEngineModule(): Promise<WebAssembly.Module> {
  if (typeof WebAssembly === "undefined" || typeof WebAssembly.compileStreaming !== "function") {
    return Promise.reject(new EngineError("WebAssembly streaming compilation is not available in this web view"));
  }
  compiledModule ??= (async () => {
    // Served as `application/wasm` by the native scheme handler, so WebKit streams it straight
    // into the compiler.
    let response: Response;
    try {
      response = await fetch("server.wasm");
    } catch (error) {
      throw new EngineError(`Failed to load server.wasm: ${String(error)}`);
    }
    if (!response.ok) {
      throw new EngineError(`Failed to load server.wasm: HTTP ${response.status}`);
    }
    try {
      return await WebAssembly.compileStreaming(response);
    } catch (error) {
      throw new EngineError(`Failed to compile server.wasm: ${String(error)}`);
    }
  })();
  compiledModule.catch(() => {
    compiledModule = undefined;
  });
  return compiledModule;
}

const core = new CerbosBridgeCore({
  emit,
  loadWasm: loadEngineModule,
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

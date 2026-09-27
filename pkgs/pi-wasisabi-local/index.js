// pi-wasisabi-local: registers this machine's local model server with pi, and
// reaches it over its UNIX SOCKET.
//
// Why an extension rather than a models.json entry:
//
//   1. pi's providers speak HTTP to a host:port. The local server listens on a
//      unix socket (see wasisabi's modules/services/llm.nix for why), and the
//      anonctl-jailed accounts can reach nothing else without a hole punched
//      in their jail. So the transport has to be taught, and only code can.
//   2. The provider entry is READ from /etc/wasisabi/llm.json, which the NixOS
//      module writes from the same values that start the server. A model swap
//      therefore reaches pi with no file in anyone's home to update, and
//      models.json stays the user's own file for their own providers.
//
// How the transport works: requests to one sentinel origin are served by
// node:http over the socket; every other request goes to the fetch that was
// installed before us, untouched. The OpenAI SDK that pi uses resolves
// `globalThis.fetch` when it builds a client, and pi builds one per request,
// so wrapping the global is enough. The wrap is installed ONCE per process:
// wherever hosts many sessions in one process and each loads this extension.
//
// No dependencies, deliberately: this file is consumed by absolute store path
// and must load with nothing but node's standard library.

import fs from "node:fs";
import http from "node:http";
import { Readable } from "node:stream";

const CONFIG_PATH = process.env.WASISABI_LLM_CONFIG || "/etc/wasisabi/llm.json";
const SENTINEL_ORIGIN = "http://wasisabi-llm.invalid";
const WRAPPED = Symbol.for("wasisabi.llm.fetchWrapped");

function readConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  } catch {
    return null;
  }
}

function canUseSocket(socketPath) {
  try {
    fs.accessSync(socketPath, fs.constants.R_OK | fs.constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

async function bodyBytes(input, init) {
  const body = init?.body;
  if (body == null) {
    if (input instanceof Request && input.body) return Buffer.from(await input.arrayBuffer());
    return undefined;
  }
  if (typeof body === "string") return Buffer.from(body);
  if (body instanceof Uint8Array) return Buffer.from(body);
  if (body instanceof ArrayBuffer) return Buffer.from(new Uint8Array(body));
  // Anything else (a stream, a Blob, FormData): let Request normalise it.
  return Buffer.from(await new Request(SENTINEL_ORIGIN, { method: "POST", body, duplex: "half" }).arrayBuffer());
}

function unixFetch(socketPath, input, init = {}) {
  const url = new URL(input instanceof Request ? input.url : String(input));
  const method = (init.method || (input instanceof Request ? input.method : "GET")).toUpperCase();
  const headers = {};
  new Headers(init.headers || (input instanceof Request ? input.headers : undefined)).forEach((v, k) => {
    headers[k] = v;
  });
  const signal = init.signal || (input instanceof Request ? input.signal : undefined);

  return bodyBytes(input, init).then(
    (body) =>
      new Promise((resolve, reject) => {
        headers.host = "localhost";
        if (body) headers["content-length"] = String(body.length);
        const req = http.request(
          { socketPath, method, path: url.pathname + url.search, headers },
          (res) => {
            const out = new Headers();
            for (const [k, v] of Object.entries(res.headers)) {
              if (Array.isArray(v)) v.forEach((x) => out.append(k, x));
              else if (v != null) out.set(k, String(v));
            }
            const noBody = method === "HEAD" || [101, 204, 205, 304].includes(res.statusCode);
            resolve(
              new Response(noBody ? null : Readable.toWeb(res), {
                status: res.statusCode,
                statusText: res.statusMessage,
                headers: out,
              }),
            );
          },
        );
        req.on("error", (err) => {
          reject(
            new TypeError(`fetch failed: local model socket ${socketPath}: ${err.message}`, { cause: err }),
          );
        });
        if (signal) {
          const abort = () => req.destroy(signal.reason ?? new DOMException("aborted", "AbortError"));
          if (signal.aborted) abort();
          else signal.addEventListener("abort", abort, { once: true });
        }
        if (body) req.write(body);
        req.end();
      }),
  );
}

function installSocketFetch(socketPath) {
  if (globalThis[WRAPPED]) return;
  const inner = globalThis.fetch;
  globalThis.fetch = function wasisabiFetch(input, init) {
    const href = input instanceof Request ? input.url : String(input);
    if (href.startsWith(SENTINEL_ORIGIN + "/")) return unixFetch(socketPath, input, init);
    return inner.call(this, input, init);
  };
  globalThis[WRAPPED] = true;
}

export default function (pi) {
  const cfg = readConfig();
  if (!cfg || !Array.isArray(cfg.models) || cfg.models.length === 0) return;

  // The socket when this account may use it; the loopback port otherwise
  // (an account outside the socket's group, or a machine without the socket).
  let baseUrl;
  if (cfg.socketPath && canUseSocket(cfg.socketPath)) {
    installSocketFetch(cfg.socketPath);
    baseUrl = `${SENTINEL_ORIGIN}/v1`;
  } else if (cfg.tcpUrl) {
    baseUrl = cfg.tcpUrl;
  } else {
    // Register anyway, so the failure is a clear connection error naming the
    // socket rather than a model that silently is not there.
    installSocketFetch(cfg.socketPath);
    baseUrl = `${SENTINEL_ORIGIN}/v1`;
  }

  pi.registerProvider(cfg.provider || "local", {
    name: "Local model (this machine)",
    baseUrl,
    apiKey: "none",
    api: "openai-completions",
    models: cfg.models.map((m) => ({
      id: m.id,
      name: m.name || m.id,
      reasoning: Boolean(m.reasoning),
      input: m.input || ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: m.contextWindow || 32768,
      maxTokens: m.maxTokens || 8192,
    })),
  });
}

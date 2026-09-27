/**
 * Vercel Edge Function adapter for the proxy.
 *
 * The proxy in ../src/index.ts is a plain `fetch(request, env)` handler that
 * uses only Web APIs, which is exactly what a Vercel Edge Function is. This
 * file forwards every request to it with `process.env` standing in for the
 * Cloudflare `env` bindings, so the same code runs on both platforms.
 *
 * vercel.json rewrites every path to this function and passes the original
 * path in the `path` query parameter, so the proxy sees "/claude",
 * "/transcribe", "/analysis/health" exactly as it does on Cloudflare.
 */

import proxyWorker from "../src/index";

export const config = { runtime: "edge" };

export default function handler(request: Request): Promise<Response> {
  const incomingURL = new URL(request.url);
  const originalPath = incomingURL.searchParams.get("path") ?? "";
  incomingURL.searchParams.delete("path");
  incomingURL.pathname = "/" + originalPath.replace(/^\/+/, "");
  const forwardedRequest = new Request(incomingURL.toString(), request);
  return proxyWorker.fetch(forwardedRequest, process.env as Record<string, string | undefined>);
}

/**
 * Root-level Vercel entry point.
 *
 * The Vercel project is connected to this GitHub repo, so every push deploys
 * from the repo root. This file wraps the worker's edge adapter so a root
 * deploy serves the same proxy as a deploy from worker/. `config` must be
 * declared here, literally: Vercel reads it statically and a re-export is not
 * seen, which turns the function into a Node one and breaks the handler.
 */

import proxyHandler from "../worker/api/proxy";

export const config = { runtime: "edge" };

export default function handler(request: Request): Promise<Response> {
  return proxyHandler(request);
}

/**
 * Root-level Vercel entry point.
 *
 * The Vercel project is connected to this GitHub repo, so every push deploys
 * from the repo root. This file re-exports the worker's edge adapter so a root
 * deploy serves the same proxy as a deploy from worker/.
 */

export { config, default } from "../worker/api/proxy";

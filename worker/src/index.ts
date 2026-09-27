/**
 * Sounder Proxy Worker
 *
 * Holds every third-party API key so the macOS app never ships with one.
 * The app talks to this Worker; the Worker talks to the upstream APIs.
 *
 * Routes:
 *   GET  /health            → which upstreams are configured (no secrets returned)
 *   POST /claude            → Anthropic Messages API (Claude: vision + tool-forced JSON) — the main model
 *   POST /chat              → Fireworks chat completions (OpenAI-compatible, vision + JSON schema, streaming passthrough)
 *   POST /transcribe        → Fireworks Whisper (multipart passthrough, returns {"text": ...})
 *   POST /tts               → ElevenLabs text-to-speech (optional; 503 when no key is configured)
 *   POST /transcribe-token  → AssemblyAI short-lived streaming token (optional legacy path; 503 when no key)
 *   ANY  /analysis/*        → passthrough to the Python analysis service when ANALYSIS_BACKEND_URL is set
 *
 * Secrets (wrangler secret put ...): ANTHROPIC_API_KEY, FIREWORKS_API_KEY, ELEVENLABS_API_KEY, ASSEMBLYAI_API_KEY
 * Vars (wrangler.toml): FIREWORKS_CHAT_MODEL, FIREWORKS_TRANSCRIPTION_MODEL, ELEVENLABS_VOICE_ID, ANALYSIS_BACKEND_URL
 */

interface Env {
  ANTHROPIC_API_KEY?: string;
  CLAUDE_MODEL?: string;
  FIREWORKS_API_KEY?: string;
  FIREWORKS_CHAT_MODEL?: string;
  FIREWORKS_TRANSCRIPTION_MODEL?: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  ASSEMBLYAI_API_KEY?: string;
  ANALYSIS_BACKEND_URL?: string;
}

const FIREWORKS_CHAT_COMPLETIONS_URL = "https://api.fireworks.ai/inference/v1/chat/completions";
// Fireworks serves whisper-v3-turbo from a dedicated audio host. The prod host
// returns 401 for keys that are only enabled for the turbo deployment, so we
// default to the turbo host and let wrangler.toml override it if needed.
const FIREWORKS_TRANSCRIPTION_URL = "https://audio-turbo.us-virginia-1.direct.fireworks.ai/v1/audio/transcriptions";
const DEFAULT_FIREWORKS_CHAT_MODEL = "accounts/fireworks/routers/kimi-k3-fast";
const ANTHROPIC_MESSAGES_URL = "https://api.anthropic.com/v1/messages";
const DEFAULT_CLAUDE_MODEL = "claude-sonnet-5";
const DEFAULT_FIREWORKS_TRANSCRIPTION_MODEL = "whisper-v3-turbo";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    try {
      if (url.pathname === "/health" && request.method === "GET") {
        return handleHealth(env);
      }

      if (url.pathname.startsWith("/analysis/")) {
        return await handleAnalysisPassthrough(request, env, url);
      }

      if (request.method !== "POST") {
        return jsonResponse({ error: "Method not allowed" }, 405);
      }

      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/claude") {
        return await handleClaude(request, env);
      }

      if (url.pathname === "/transcribe") {
        return await handleTranscribe(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse({ error: String(error) }, 500);
    }

    return jsonResponse({ error: "Not found" }, 404);
  },
};

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function handleHealth(env: Env): Response {
  return jsonResponse({
    ok: true,
    claudeConfigured: Boolean(env.ANTHROPIC_API_KEY),
    claudeModel: env.CLAUDE_MODEL || DEFAULT_CLAUDE_MODEL,
    fireworksConfigured: Boolean(env.FIREWORKS_API_KEY),
    chatModel: env.FIREWORKS_CHAT_MODEL || DEFAULT_FIREWORKS_CHAT_MODEL,
    transcriptionModel: env.FIREWORKS_TRANSCRIPTION_MODEL || DEFAULT_FIREWORKS_TRANSCRIPTION_MODEL,
    elevenLabsConfigured: Boolean(env.ELEVENLABS_API_KEY),
    assemblyAIConfigured: Boolean(env.ASSEMBLYAI_API_KEY),
    analysisBackendConfigured: Boolean(env.ANALYSIS_BACKEND_URL),
  });
}

/**
 * Forwards an OpenAI-style chat completion request to Fireworks. The app sends
 * the full body (messages, response_format, max_tokens...). If the app omits
 * the model, the Worker fills in the configured default so the model choice can
 * be changed with a redeploy rather than an app rebuild.
 */
async function handleChat(request: Request, env: Env): Promise<Response> {
  if (!env.FIREWORKS_API_KEY) {
    return jsonResponse({ error: "FIREWORKS_API_KEY is not configured on the Worker" }, 503);
  }

  let requestBody: Record<string, unknown>;
  try {
    requestBody = (await request.json()) as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "Request body must be JSON" }, 400);
  }

  if (!requestBody.model) {
    requestBody.model = env.FIREWORKS_CHAT_MODEL || DEFAULT_FIREWORKS_CHAT_MODEL;
  }

  const upstreamResponse = await fetch(FIREWORKS_CHAT_COMPLETIONS_URL, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.FIREWORKS_API_KEY}`,
      "content-type": "application/json",
      accept: requestBody.stream ? "text/event-stream" : "application/json",
    },
    body: JSON.stringify(requestBody),
  });

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/chat] Fireworks error ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") || "application/json",
      "cache-control": "no-cache",
    },
  });
}

/**
 * Forwards an Anthropic Messages API request (vision + tool-forced JSON) to
 * Claude. The default model is injected when the app omits it.
 */
async function handleClaude(request: Request, env: Env): Promise<Response> {
  if (!env.ANTHROPIC_API_KEY) {
    return jsonResponse({ error: "ANTHROPIC_API_KEY is not configured on the Worker" }, 503);
  }

  let requestBody: Record<string, unknown>;
  try {
    requestBody = (await request.json()) as Record<string, unknown>;
  } catch {
    return jsonResponse({ error: "Request body must be JSON" }, 400);
  }
  if (!requestBody.model) {
    requestBody.model = env.CLAUDE_MODEL || DEFAULT_CLAUDE_MODEL;
  }

  const upstreamResponse = await fetch(ANTHROPIC_MESSAGES_URL, {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(requestBody),
  });

  const responseText = await upstreamResponse.text();
  if (!upstreamResponse.ok) {
    console.error(`[/claude] Anthropic error ${upstreamResponse.status}: ${responseText}`);
  }
  return new Response(responseText, {
    status: upstreamResponse.status,
    headers: { "content-type": "application/json", "cache-control": "no-cache" },
  });
}

/**
 * Forwards a multipart transcription upload (file + model + prompt fields) to
 * Fireworks Whisper. The multipart body is streamed through untouched; only the
 * auth header is added. Fireworks' audio host expects the raw key, not "Bearer".
 */
async function handleTranscribe(request: Request, env: Env): Promise<Response> {
  if (!env.FIREWORKS_API_KEY) {
    return jsonResponse({ error: "FIREWORKS_API_KEY is not configured on the Worker" }, 503);
  }

  const contentType = request.headers.get("content-type") || "";
  if (!contentType.startsWith("multipart/form-data")) {
    return jsonResponse({ error: "Expected multipart/form-data with a 'file' field" }, 400);
  }

  // Stream the multipart body through untouched. Re-parsing it with formData()
  // and re-encoding added seconds per clip in wrangler's local runtime. The app
  // always includes the model field itself.
  const upstreamResponse = await fetch(FIREWORKS_TRANSCRIPTION_URL, {
    method: "POST",
    headers: {
      authorization: env.FIREWORKS_API_KEY,
      "content-type": contentType,
    },
    body: request.body,
  });

  const responseText = await upstreamResponse.text();
  if (!upstreamResponse.ok) {
    console.error(`[/transcribe] Fireworks audio error ${upstreamResponse.status}: ${responseText}`);
  }

  return new Response(responseText, {
    status: upstreamResponse.status,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY || !env.ELEVENLABS_VOICE_ID) {
    return jsonResponse({ error: "ElevenLabs is not configured on the Worker" }, 503);
  }

  const body = await request.text();
  const upstreamResponse = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${env.ELEVENLABS_VOICE_ID}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!upstreamResponse.ok) {
    const errorBody = await upstreamResponse.text();
    console.error(`[/tts] ElevenLabs API error ${upstreamResponse.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: upstreamResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") || "audio/mpeg",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  if (!env.ASSEMBLYAI_API_KEY) {
    return jsonResponse({ error: "AssemblyAI is not configured on the Worker" }, 503);
  }

  const upstreamResponse = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: { authorization: env.ASSEMBLYAI_API_KEY },
    }
  );

  const responseText = await upstreamResponse.text();
  if (!upstreamResponse.ok) {
    console.error(`[/transcribe-token] AssemblyAI token error ${upstreamResponse.status}: ${responseText}`);
  }

  return new Response(responseText, {
    status: upstreamResponse.status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Optional passthrough to the Python analysis service (Modal or any host), so a
 * deployed app can reach a private backend without knowing its URL. The path
 * after /analysis is forwarded verbatim: /analysis/analyze → {backend}/analyze.
 */
async function handleAnalysisPassthrough(request: Request, env: Env, url: URL): Promise<Response> {
  if (!env.ANALYSIS_BACKEND_URL) {
    return jsonResponse({ error: "ANALYSIS_BACKEND_URL is not configured on the Worker" }, 503);
  }

  const backendBase = env.ANALYSIS_BACKEND_URL.replace(/\/$/, "");
  const forwardedPath = url.pathname.replace(/^\/analysis/, "");
  const upstreamResponse = await fetch(`${backendBase}${forwardedPath}${url.search}`, {
    method: request.method,
    headers: { "content-type": request.headers.get("content-type") || "application/json" },
    body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
  });

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") || "application/json",
    },
  });
}

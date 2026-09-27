# Sounder

**A screen buddy that reads your data off the pixels, trains a model in seconds, and draws the answer on your screen.**

Hold `Control + Option` over any spreadsheet and ask out loud. Sounder screenshots the display under your cursor, reads the table with on-device OCR, fits a model to it on a small Python service, and draws the answer *in place*: red circles around anomalous rows, importance bars docked under the real column headers, a fitted curve over your own chart. Then it tells you what it found. No copy-paste, no upload, no plugin.

Built at **HackGT 13** for the *Oracle of the Deep* track.

> **Disclosure.** Client shell forked from [Clicky](https://github.com/farzaa/clicky) (MIT) for window/capture/hotkey/TTS plumbing. Extraction (OCR grid reconstruction + ink-gap segmentation), analysis services, grounding-by-ID, drawing layer, mode router, voice tools, planner contract and synthetic-data pipeline are original work built during HackGT 13. Upstream `LICENSE` is kept; ours is `LICENSE-SOUNDER`.

## What it does

| You say | What happens on screen | What it says |
|---|---|---|
| "what's weird here?" | up to 6 rows circled in red, numbered | one spoken reason per row: "row 412: MonthlyCharges is 3.1 times the median; tenure is only 15 percent of the median" |
| "what actually drives churn?" | bars under every column header, width ∝ importance, top driver glows | "Contract and tenure explain most of it… trained in 0.4 seconds on 300 rows, held-out AUC 0.84" |
| "fit this" (with a chart on screen) | curve + 95% band drawn over the chart | "a linear curve fits y against x best, r squared 0.97" |
| anything else | cursor flies to the element it means, related text highlighted | Clicky-style spoken answer (General mode) |

Edit a flagged cell and the same question re-runs automatically once the screen settles; the circle disappears if the row is fixed.

## Architecture

```
[Mac app, Swift]                                            [Cloudflare Worker]      [Python service]
hotkey ─► native capture ─► Vision OCR ─► ink-gap segmenter ─► TableExtractor       (holds FIREWORKS_API_KEY)
              │                 │                                  │
              │                 └─► elements[] {id, bbox, text}    ├─ confidence < 0.9 ─► ⌘A ⌘C clipboard TSV, aligned to OCR rows
              │                                                    ▼
              ├─► /transcribe (Fireworks whisper-v3-turbo) ◄── push-to-talk WAV
              ├─► planner: /chat (Fireworks kimi-k3-fast, JSON schema) ── sees column names only ──► {task, target_col, k…}
              │                                                                                        │
              │                                                                    POST /analyze ◄─────┘
              │                                                        IsolationForest · HistGradientBoosting + permutation importance · AIC curve fit
              ▼                                                                                        │
DrawingLayer (circle_rows · bars_under_headers · curve · highlight) ◄── row ids / importances / curve points ◄┘
AVSpeechSynthesizer (or ElevenLabs via /tts) ◄── deterministic sentence from the numbers, optionally rephrased by the LLM
```

**Coordinate contract.** Every box is in *capture pixels* (top-left origin of the captured display) until the drawing layer scales it to overlay points: `point = pixel × (displayPoints / capturePixels)`. The overlay window covers exactly the captured display, so no other transform exists. The panel's **Calibrate overlay** button outlines every text line it can read for 5 s: if the boxes sit on the text, the mapping is right.

**Grounding by ID, never by coordinate.** The vision model receives a Set-of-Mark screenshot (numbered tags) plus the element list and returns an element id; the renderer resolves the box. Drawings for Data mode never depend on model prose at all, they come from `results.json`.

**Anti-hallucination.** The planner sees column names, types and row count, never cell values. Spoken numbers are assembled by the analysis service; the LLM may rephrase, and the app rejects a rephrase that drops any number.

## Numbers so far (synthetic Sheets-style screenshot, 2880×1800 Retina, harness in this repo)

| Metric | Value |
|---|---|
| OCR (Vision, accurate, warm) | 0.25–0.4 s |
| Table rebuilt from OCR | 26×8, 8/8 headers, spreadsheet row numbers recovered |
| Cell-value accuracy vs ground truth | ~90% (misses are O/0 confusions in synthetic IDs) |
| Chart axis calibration error | < 2 px |
| Analysis: drivers (HistGradientBoosting, 1200 rows) | < 1 s train, held-out AUC > 0.7 on synthetic churn |
| Planner round trip (Fireworks kimi-k3-fast, JSON schema) | ~1.3 s |
| Whisper round trip (Fireworks, via Worker, warm) | ~0.2 s |

Real-screenshot eval and the RF-DETR extractor numbers are still to be recorded (see *Status*).

## Run it

Requirements: macOS 14.2+, Xcode 15+ (built with Xcode 26), Node 18+, Python 3.11+.

### 1. Worker (holds the Fireworks key)

```bash
cd worker
npm install
cp .dev.vars.example .dev.vars        # put FIREWORKS_API_KEY=fw_... in it
npx wrangler dev --port 8787          # local proxy at http://127.0.0.1:8787
```

Deploying instead: `npx wrangler secret put FIREWORKS_API_KEY && npx wrangler deploy`, then set `SounderWorkerBaseURL` in `leanring-buddy/Info.plist` to the printed URL.

### 2. Analysis service

```bash
cd services
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn analysis.app:app --port 8000
```

Or deploy to Modal (`modal deploy modal_app.py`) and set `SounderAnalysisBaseURL` in Info.plist.

### 3. App

```bash
open leanring-buddy.xcodeproj
```

Select the `leanring-buddy` scheme (the typo is upstream), check the signing team under *Signing & Capabilities*, `Cmd+R`. Grant Microphone, Accessibility, Screen Recording and Screen Content from the menu bar panel, press **Start**. The panel shows whether the Worker and analysis service are reachable, the mode picker (Auto / General / Data), the last run's latency breakdown, and the calibration self-test.

Do **not** build from the terminal with `xcodebuild`: it invalidates the TCC permissions the demo depends on.

### Demo script (Telco churn CSV in Google Sheets at 100% zoom, one display)

1. "what's weird here?" → circles + reasons.
2. "what actually drives churn?" → bars under headers, AUC and train time spoken.
3. Edit a flagged cell → auto re-run.
4. Tab with a chart: "fit this" → curve + band.
5. Panel → *Last run* shows capture / OCR / plan / model / total seconds.

## Configuration (`leanring-buddy/Info.plist`)

| Key | Default | Meaning |
|---|---|---|
| `SounderWorkerBaseURL` | `http://127.0.0.1:8787` | Cloudflare Worker proxy |
| `SounderAnalysisBaseURL` | `http://127.0.0.1:8000` | Python analysis service |
| `SounderChatModel` | `accounts/fireworks/routers/kimi-k3-fast` | Fireworks model (must support images + JSON schema) |
| `SounderSpeechOutputProvider` | `system` | `system` (AVSpeechSynthesizer, offline) or `elevenlabs` |
| `SounderUsesLLMNarration` | `true` | Let the LLM rephrase result sentences (numbers are verified) |
| `VoiceTranscriptionProvider` | `fireworks` | `fireworks`, `apple` (offline), `assemblyai`, `openai` |
| `PostHogAPIKey` | unset | Analytics stay off unless set |

Panel toggles: **Clipboard fallback** (⌘A/⌘C when OCR < 90%), **Offline voice** (Apple Speech), **Show Sounder** (persistent vs. transient cursor).

## Status vs. the PRD

| PRD item | Status |
|---|---|
| Hotkey, native capture, overlay with verified coordinates | done (+ calibration self-test) |
| Clipboard extraction path wired to analysis + drawing | done, gated on OCR confidence |
| `anomaly`, `drivers` end to end | done, tested against synthetic Telco-shaped data |
| `fit` over a detected chart | done for numeric axes; date/categorical axes not calibrated |
| Speech-to-speech voice with typed tools | Fireworks Whisper → Fireworks LLM (JSON-schema planner) → system voice. Grok Voice was replaced by Fireworks per the team's key; ElevenLabs optional |
| General mode with Set-of-Mark grounding by ID | done (OCR text elements; no icon/button detector yet) |
| Edit-and-re-run diffing | done (table region watcher, fires once the screen settles) |
| Offline fallback | Apple Speech + keyword planner + local analysis service; General mode needs the network |
| Trained screenshot extractor (RF-DETR) | synthetic data generator runs; `train.py` / `serve.py` are scaffolds, not yet trained (needs GPU) |
| Modal deployment | `modal_app.py` written, not deployed (needs an account) |
| Golden-path recording, Devpost, slide | not started |

## Repo layout

```
leanring-buddy/                 Swift app (Clicky fork)
  CompanionManager.swift          mode router + interaction pipeline
  Sounder/Backend/                SounderModels, FireworksChatClient, AnalysisServiceClient
  Sounder/Capture/                native-resolution ScreenCaptureKit capture
  Sounder/Grounding/              Vision OCR, ink-gap segmenter, Set-of-Mark renderer
  Sounder/Extraction/             TableExtractor, ChartRegionDetector, ClipboardTableExtractor, ScreenChangeWatcher
  Sounder/Overlay/                DrawingPrimitives + DrawingLayerView
  Sounder/Router/                 GeneralModePipeline, DataModePipeline
  Sounder/Voice/                  Fireworks Whisper provider, SpeechOutputClient
worker/                         Cloudflare Worker proxy (/chat, /transcribe, /tts, /health, /analysis/*)
services/                       Python: analysis service (tested), Modal wrapper, synth data generator, extractor scaffolds
```

See `CLAUDE.md` for the full architecture notes and coding conventions.

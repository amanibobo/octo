<h1>
  <img src="docs/brand/octo-sprite.svg" width="44" align="absmiddle" alt="Octo">&nbsp; Octo
</h1>

**A screen buddy for clinicians: it reads the chart on screen, catches drug interactions and dosing problems, surfaces new evidence, and speaks, without shipping patient text to any model.**

Hold `Control + Option` over an EHR chart, a med list, or a PubMed page and ask out loud. Octo screenshots the display under your cursor, runs on-device OCR and on-device entity extraction (drugs, doses, frequencies, conditions, labs, age, sex), normalizes drugs to RxNorm concepts, and sends **only concept IDs and numbers** to a small service that checks interactions, label dosing and renal rules. The findings come back as a spoken answer in Octo's own words, with the numbers verified against the rules engine, and evidence lookups hold up a clickable paper card. The chart itself stays untouched.

Built at **HackGT 13** for the Impiricus challenge ("invent the next way we engage HCPs") and the *Oracle of the Deep* track. General mode (ask anything about the screen, it points and can pull up a paper, image or video) and Agent mode (it operates the Mac: opens apps, clicks, types) are the other two modes of the same buddy.


## Why this is a new HCP engagement channel

- **In the workflow, at the moment of relevance.** Voice plus on-screen drawing inside the chart the clinician is already looking at. Not SMS, not a portal.
- **Compliant by construction.** Raw screen text never leaves the laptop. The outbound payload is scanned before every request; the console prints `🔒 outbound: 6 drug concepts, 5 condition concepts, 6 numeric values, 0 raw words`.
- **A disclosed content slot.** The evidence badge is where sponsored medical information (a label update, a trial readout) can appear in context, opt-in and labeled "Sponsored medical information". The demo ships one placeholder slot for HFpEF.
- **Measurable.** Interactions caught, dosing flags raised, pairs checked, seconds from question to drawing.

## Demo (synthetic patient in `demo/chart.html`, 90 seconds)

| You say | On screen | Spoken |
|---|---|---|
| "anything wrong with this med list?" | red link warfarin ↔ fluconazole (major), orange link fluconazole ↔ atorvastatin, underline under the metformin dose, footnotes | "three things to flag. warfarin plus fluconazole is a major interaction: fluconazole inhibits CYP2C9 and raises warfarin exposure; INR climbs within days; monitor INR closely or choose an alternative antifungal. …" |
| "what's new for HFpEF?" | badge next to HFpEF, references drawer with FINEARTS-HF, STEP-HFpEF, DELIVER, plus one labeled sponsored slot | "the newest trial for hfpef is FINEARTS-HF, NEJM 2024: finerenone reduced worsening heart failure events…" |
| edit the med list (cells are editable), wait a second | the same check re-runs and redraws | "updated. …" |

Open `demo/chart.html` in a browser at 100% zoom. The patient is 71, AF on warfarin, new fluconazole, metformin 1000 mg BID with eGFR 38, HFpEF.

## Data mode (spreadsheets)

| You say | What happens on screen | What it says |
|---|---|---|
| "what's weird here?" | up to 6 rows circled in red, numbered | one spoken reason per row: "row 412: MonthlyCharges is 3.1 times the median; tenure is only 15 percent of the median" |
| "what actually drives churn?" | bars under every column header, width ∝ importance, top driver glows | "Contract and tenure explain most of it… trained in 0.4 seconds on 300 rows, held-out AUC 0.84" |
| "fit this" (with a chart on screen) | curve + 95% band drawn over the chart | "a linear curve fits y against x best, r squared 0.97" |
| anything else | cursor flies to the element it means, related text highlighted | Clicky-style spoken answer (General mode) |

Edit a flagged cell and the same question re-runs automatically once the screen settles; the circle disappears if the row is fixed.

## Architecture

```
[Mac app, Swift]                                                      [Cloudflare Worker]       [Modal]
hotkey ─► native capture ─► Vision OCR ─► ink-gap segmenter ─┬─► ClinicalEntityExtractor      (FIREWORKS + ELEVENLABS keys)
                                                             │   drugs→RXCUI, doses, freq,
                                                             │   conditions→ICD-10, labs, age, sex
                                                             │        │ concept IDs + numbers only (privacy scan)
                                                             │        ▼
                                                             │   POST /clinical/check ──────────────────────────► interactions (seed set), label max dose,
                                                             │   POST /clinical/evidence ────────────────────────► renal rules (CKD-EPI 2021), age rules
                                                             │                                                    PubMed live → seeded cache; sponsored slot
                                                             ├─► TableExtractor ─► /analyze (anomaly · drivers · fit)
                                                             └─► elements[] {id,bbox,text} ─► /chat (Fireworks kimi-k3-fast, Set-of-Mark) for General mode
Apple on-device speech ─► keyword router ─► mode ─► DrawingLayer (link · underline · badge · footnotes · circle · bars · curve) ─► ElevenLabs flash
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
| Planner | 0 s for anomaly/drivers/fit phrasing (keyword router); Fireworks kimi-k3-fast ~1.2 s with `reasoning_effort: none` when consulted |
| General-mode vision answer (1280px Set-of-Mark, ≤100 elements) | ~1.2 s |
| Whisper round trip (Fireworks) | 0.2–10 s, erratic on clips over ~5 s, hence on-device transcription by default |
| ElevenLabs flash per sentence (via Worker) | ~0.3 s; OCR runs during transcription so it adds nothing on the critical path |
| Clinical NER (BiomedBERT, fine-tuned this weekend) | BC5CDR test entity F1 0.893; synthetic med-line DOSE/FREQ F1 1.00; 44 s training on A10G |

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

The app ships pointing at the deployed Modal instance (`https://amanibobo1--sounder-analysis-serve.modal.run`, deployed with `modal deploy modal_app.py`, one container kept warm). Run uvicorn locally and switch `SounderAnalysisBaseURL` in Info.plist when you want to work offline.

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
| `SounderAnalysisBaseURL` | `https://amanibobo1--sounder-analysis-serve.modal.run` | Python analysis service (Modal, one warm container). Set to `http://127.0.0.1:8000` to use a local uvicorn |
| `SounderChatModel` | `accounts/fireworks/routers/kimi-k3-fast` | Fireworks model (must support images + JSON schema) |
| `SounderSpeechOutputProvider` | `elevenlabs` | `elevenlabs` (Worker `/tts`, ~0.3 s per sentence, pipelined), `kokoro` (Modal, no key; `services/modal_tts.py`) or `system` (offline) |
| `SounderTTSBaseURL` | Modal Kokoro URL | Only used with the `kokoro` provider |
| `SounderUsesLLMNarration` | `false` | Let the LLM rephrase result sentences (adds 2–5 s; numbers are verified) |
| `VoiceTranscriptionProvider` | `fireworks` | Cloud transcription backend when the panel's "On-device transcription" toggle is off. On-device Apple Speech is the default because Fireworks Whisper measured 2–10 s per clip |
| `PostHogAPIKey` | unset | Analytics stay off unless set |

Panel toggles: **Clipboard fallback** (⌘A/⌘C when OCR < 90%), **On-device transcription** (Apple Speech, default on; off = Fireworks Whisper), **Show Octo** (persistent vs. transient cursor).

## Status vs. the PRDs

| Item | Status |
|---|---|
| Rx: OCR → entities → RxNorm → interactions + dosing + renal → drawn links/underlines/footnotes → spoken | done, verified on the rendered demo chart (6/6 drugs with RXCUI, 5 conditions, labs, age, sex; 3 findings) |
| Rx: privacy boundary enforced in code | done: payload scanned, `0 raw words` logged per request |
| Rx: evidence badge + citations + disclosed sponsored slot | done; PubMed live with seeded cache fallback (PubMed returned 500s during the build) |
| Rx: edit-and-re-run | done (watches the med list region) |
| Rx: trained NER (BiomedBERT fine-tune) | **trained** on Modal A10G (`services/ner/train_ner.py`, 44 s, 2 epochs, BC5CDR + 6k synthetic med lines). Held-out entity F1: **0.893** on BC5CDR (chemical 0.937, disease 0.843), 1.00 on synthetic med lines (DOSE/FREQ). Weights + `metrics.json` on the `sounder-ner` volume; ONNX export still pending (`optimum` module). On-device extraction in the app is still the dictionary + regex pass; wiring the ONNX model in is the next step |
| Rx: DDInter database | download host unreachable; 75 curated pairs with mechanisms ship instead (`services/clinical/data/interactions.json`) |
| Data: anomaly / drivers / fit, clipboard fallback, re-run | done (see Data mode) |
| General: Set-of-Mark grounding by ID | done |
| Voice | Apple on-device speech → ElevenLabs flash, pipelined; Fireworks Whisper optional |
| Modal | analysis + clinical service deployed with one warm container |
| Worker deploy to Cloudflare, golden-path recording, Devpost, slide | not started |

## Repo layout

```
leanring-buddy/                 Swift app (Clicky fork)
  CompanionManager.swift          mode router + interaction pipeline
  Sounder/Backend/                SounderModels, FireworksChatClient, AnalysisServiceClient
  Sounder/Capture/                native-resolution ScreenCaptureKit capture
  Sounder/Grounding/              Vision OCR, ink-gap segmenter, Set-of-Mark renderer
  Sounder/Extraction/             TableExtractor, ChartRegionDetector, ClipboardTableExtractor, ScreenChangeWatcher
  Sounder/Overlay/                DrawingPrimitives + DrawingLayerView
  Sounder/Clinical/               ClinicalLexicon (+ drug_lexicon.json), ClinicalEntityExtractor, ClinicalServiceClient
  Sounder/Router/                 GeneralModePipeline, DataModePipeline, ClinicalModePipeline
  Sounder/Voice/                  Fireworks Whisper provider, SpeechOutputClient
worker/                         Cloudflare Worker proxy (/chat, /transcribe, /tts, /health, /analysis/*)
services/                       Python: analysis + clinical service (tested), Modal wrapper, seed data, synth data generator, extractor scaffolds
demo/chart.html                 synthetic patient chart (editable med list) for the Rx demo
```

See `CLAUDE.md` for the full architecture notes and coding conventions.

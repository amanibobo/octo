# Octo - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app (fork of Clicky, MIT). Lives entirely in the macOS status bar (no dock icon, no main window). Push-to-talk (ctrl+option) captures the display under the cursor at native resolution, runs **on-device Vision OCR**, rebuilds any spreadsheet table from the word boxes, and routes the spoken question:

- **Rx mode** (primary demo, Impiricus): `ClinicalEntityExtractor` finds drugs (RxNorm lexicon `drug_lexicon.json`, 15k names), doses, frequencies, conditions (ICD-10 aliases), labs, age and sex on device; `ClinicalModePipeline` builds a concept-only payload, asserts no raw OCR words leak (`privacyReport`), calls `/clinical/check` (interactions seed set, label max dose, CKD-EPI 2021 renal rules, age rules) or `/clinical/evidence` (PubMed live → seeded cache, plus the disclosed sponsored slot) and draws `link` / `underline` / `badge` / `footnoteDrawer` primitives.
- **Data mode**: a JSON-schema planner (Fireworks LLM, sees column names only) picks `anomaly` / `drivers` / `fit`; the Python analysis service (`services/analysis`) trains/fits a model and returns row ids, importances or curve points; the overlay draws circles around rows, importance bars under headers, or a curve over the user's chart; the result is spoken from the numbers.
- **General mode**: Set-of-Mark screenshot + element list → Fireworks vision model returns an element **ID** to point at (never coordinates); the blue cursor flies there.

Voice: Fireworks Whisper (`whisper-v3-turbo`) for speech-to-text, `AVSpeechSynthesizer` for speech out by default (ElevenLabs optional). All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app. The Fireworks key for local dev lives in `worker/.dev.vars` (gitignored).

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **LLM**: Claude (`claude-sonnet-5` via the proxy `/claude`, Anthropic Messages API; Opus 5.5 and Fable 5.1 were slower because they reason before answering, and fast mode is not enabled for this org) for General, Rx narration, Agent and media lookup. Fireworks kimi-k3-fast remains behind `/chat`. General-mode answers and Agent actions are JSON-schema constrained.
- **Speech-to-Text**: Apple on-device Speech by default (transcript ready at key-up; panel toggle "On-device transcription"). Fireworks Whisper via Worker `/transcribe` when off (measured 2–10 s per clip, erratic). AssemblyAI/OpenAI providers kept but unused.
- **Text-to-Speech**: ElevenLabs `eleven_flash_v2_5` via Worker `/tts` by default (`ElevenLabsTTSClient`: sentence-pipelined queue, fixed filler phrases pre-synthesized at launch). Alternatives: `kokoro` (Kokoro-82M on Modal, `services/modal_tts.py`, ~4 s per long sentence on CPU) and `system` (AVSpeechSynthesizer, never picks macOS novelty voices).
- **Latency rules**: capture+OCR start at hotkey release and run during transcription; keyword planner first, LLM planner only in forced Data mode; `reasoning_effort: none`; 1280px Set-of-Mark image, ≤100 elements; LLM narration off. Auto mode enters Data only for tables passing `isPlausibleDataTable` (≥4 rows, ≥2 typed columns, real header names, confidence ≥ 0.6).
- **Screen Capture**: ScreenCaptureKit at native (Retina) resolution of the display under the cursor; own windows excluded so drawings never feed back into OCR.
- **OCR / grounding**: Apple Vision `VNRecognizeTextRequest` (accurate, no language correction). `InkSegmenter` re-splits each OCR line at real ink gaps in the bitmap because Vision's word boxes are padded. Elements get sequential IDs (Set-of-Mark).
- **Table extraction**: `TableExtractor` (rows by y-clustering → longest evenly pitched run → column separators from the x-coverage profile → header/gutter detection → column typing → confidence). Clipboard fallback (⌘A/⌘C TSV, aligned to OCR rows) when confidence < 0.9.
- **Analysis**: Python FastAPI (`services/analysis`): IsolationForest + robust-z reasons, HistGradientBoosting + permutation importance with held-out AUC/R², AIC-selected curve fit. Optional TabPFN. Deployed on Modal at `https://amanibobo1--sounder-analysis-serve.modal.run` (`services/modal_app.py`, `min_containers=1`); the app's Info.plist points there by default, `http://127.0.0.1:8000` for local uvicorn.
- **Drawing**: `DrawingPrimitive` list rendered by `DrawingLayerView` inside every overlay window. All geometry in capture pixels; `CaptureGeometry` scales to overlay points.
- **Element Pointing**: element ID → bbox centre → `detectedElementScreenLocation` (global AppKit coords); the blue cursor animates along a bezier arc as in Clicky.
- **Edit-and-re-run**: `ScreenChangeWatcher` samples the table region for ~12 s after a Data result and re-runs the same plan once pixels change and settle.
- **Concurrency**: `@MainActor` default isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), async/await; CPU-heavy OCR/extraction code is `nonisolated` and runs in detached tasks.
- **Analytics**: PostHog via `ClickyAnalytics.swift`, **disabled unless `PostHogAPIKey` is in Info.plist**.

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `GET /health` | — | Which upstreams are configured |
| `POST /chat` | `api.fireworks.ai/inference/v1/chat/completions` | OpenAI-compatible chat (vision, JSON schema, streaming passthrough); default model injected |
| `POST /transcribe` | `audio-turbo.us-virginia-1.direct.fireworks.ai/v1/audio/transcriptions` | Whisper (`whisper-v3-turbo`), multipart passthrough. Note: this host wants the raw key, no `Bearer` |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | Optional ElevenLabs TTS (503 without key) |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Optional legacy AssemblyAI token (503 without key) |
| `ANY /analysis/*` | `ANALYSIS_BACKEND_URL` | Optional passthrough to the deployed analysis service |

Worker secrets: `FIREWORKS_API_KEY` (required), `ELEVENLABS_API_KEY`, `ASSEMBLYAI_API_KEY` (optional)
Worker vars: `FIREWORKS_CHAT_MODEL`, `FIREWORKS_TRANSCRIPTION_MODEL`, `ELEVENLABS_VOICE_ID`, `ANALYSIS_BACKEND_URL`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Notch Island (DynamicNotch model)**: On Macs with a notch, `NotchPanelManager` replaces the dropdown. One large transparent canvas `NSPanel` (640×720, `.borderless, .nonactivatingPanel`, level `mainMenu + 3`, `constrainFrameRect` override, `acceptsMouseMovedEvents`) is pinned to the top-centre of the notch screen and delegated to a private SkyLight space (`SkyLightOperator`, dlsym'd, silent fallback) so it renders above the menu bar. The island is pure SwiftUI inside it (`NotchIslandView`): a `NotchSilhouetteShape` with animatable top/bottom corner radii that morphs between the collapsed notch (notch + 12 pt wide) and the 440 pt card with a spring (response 0.5, damping 0.75); the window never resizes. A 30 Hz timer expands on hover (0.10 s dwell) and collapses 0.55 s after the pointer leaves; a global click monitor collapses on outside clicks. The view reports its rendered size (`measuredIslandSize`) so the hover zone tracks the animation. Notch metrics come from `safeAreaInsets.top` and the gap between `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`.

**Pinned context**: `UserContextStore` (Application Support/Octo/Context) holds notes, links (fetched once, kept as a title + plain-text excerpt) and images (downscaled JPEG) the user adds from the notch's Context page (paperclip button: text field, Paste, Image…, drag-and-drop). `CompanionManager` snapshots `promptBundle()` at the start of every interaction and passes it to General (text + up to 2 images after the screenshot), Agent (text), Rx narration (text; its numbers are allowed in the verified narration) and media lookup. It never enters the Rx concept payload.

**Rx draws nothing**: findings are spoken (and listed in the report); the chart stays clean. Evidence offers a clickable card instead of badges.

**Screen rewind**: `ScreenHistoryRecorder` keeps a rolling 15-minute, in-memory buffer (max 600 frames) of the display under the cursor: 1 fps capture, a 32×18 grayscale fingerprint skips unchanged ticks, changed frames get an 800 px JPEG thumbnail plus fast Vision OCR (boxes scaled to thumbnail pixels). Paused while an interaction captures. `RewindIntent.detect` (phrases like "ago", "earlier", "what did that error say", with "N minutes ago" parsed) is routed before every mode; `search` scores lines by keyword overlap with a time prior and falls back to `NLEmbedding` sentence distance; `RewindPanelManager` shows the frame with matched lines highlighted and a scrub bar over the buffer; the spoken answer is Claude constrained to that frame's text, with the matched lines as fallback. Toggle: Settings › Memory.

**Dwell to ask**: while the hotkey is held, the gesture sampler tracks whether the cursor rests within 8 pt for 0.9 s. On release with no transcript within 1.3 s, `runInteraction(transcript: "what is this?", isDwellInteraction: true)` runs General mode with a 360×220 pt region around the dwell point and a prompt note that the user said nothing. Toggle: Settings › Memory.

**Notch card vignettes**: `NotchModeVignetteView` draws a tiny animated "Octo in use" scene per mode in a `Canvas` (General flies to a line, Rx links two rows, Agent clicks three targets, Auto cycles). No image assets.

**Debug hook** (DEBUG builds only): a question written to `~/Library/Logs/Sounder/ask.txt` runs as if spoken (typed-question watcher in `CompanionManager`), which is how rewind and any mode are exercised without a microphone.

**Gesture trail**: while the hotkey is held, `gestureTrailPoints` (timestamped) feed `GestureTrailView`, a Canvas on an animation timeline that draws each segment with opacity/width decaying over `gestureTrailLifetime` (1.1 s); points are pruned every tick and keep fading after release. The raw `gesturePathPointsGlobal` still defines the circled region.

**Quick intents on a circled region** (`QuickIntents.swift`, no model call): `DictateIntent` ("type …") clicks the region and types; `InkMathIntent` ("times 1.2", "plus 15 percent", "sum these") computes on the numbers inside and draws a `= result` badge; `ExtractIntent` ("copy this table as csv/json/markdown") copies the region to the clipboard, using `TableExtractor` when confident and otherwise `ExtractIntent.grid` (word boxes → row clusters + x-band columns), with every used cell highlighted. Routed before media/agent in `performInteraction`.

**Routes and whiteboard (General mode)**: the answer schema carries `route_element_ids`/`route_labels`/`route_kind` (`flow` draws numbered `.arrow` primitives between elements via `DrawingOpsBuilder.route`; `guide` starts a guided path that lights each step as the user clicks it, using global/local mouse monitors) and `sketch_diagram` (conceptual questions → `WhiteboardPipeline` returns a node/edge JSON, `WhiteboardPanelManager` lays it out in layers and sketches it in the emptiest margin, wiped on the next hotkey or after 50 s).

**Translate in place**: `TranslateIntent` ("translate this to spanish", "in english") → OCR lines in the circled region, or every line whose `NLLanguageRecognizer` language differs from the target → `TranslatePipeline` (Claude JSON, one translation per index) → `.textPatch` primitives painted over each line at its size, on a background sampled by `BackgroundColorSampler` from the strips just above and below the box, with dark/light text chosen by luminance.

**Accessibility grounding**: `AccessibilityElementReader` walks the frontmost app's windows (and menu bar) through the AX API and returns labelled controls with frames in global CG points; `CompanionManager.mergeAccessibilityElements` converts them to capture pixels and appends them to the OCR elements as kind `ax:<role>` (static text OCR already found is skipped; up to 80 AX elements, 160 total). `ScreenAnalysis.accessibilityElementsByID` keeps the AX handles. Agent mode presses `ax:` elements with `AXPress` and focuses text fields via AX before typing, falling back to pointer clicks. "read me this dialog/window" (`DialogReaderIntent`) reads the focused window's texts and controls in reading order and highlights them.

**Agent accuracy loop**: the decision schema carries `expected_outcome` (kept in history) and the prompt forbids "done" without on-screen evidence; when the model claims done, `verifyCompletion` looks at a fresh screenshot and returns `{achieved, evidence, next_hint}`; a failed verdict goes into the history and the loop continues (max 2 verifications). A Spotify playbook (search URL → play the top result → check the now-playing bar) is in the system prompt. Verified: "open spotify and play matches by che" played the right track in 7 steps, 47 s.

**Camera as context**: `CameraIntent` ("what am i holding", "read this page", "camera") → `CameraContextPanelManager` shows a glass card with an unmirrored `AVCaptureVideoPreviewLayer`, grabs the newest frame from an `AVCaptureVideoDataOutput`, runs accurate Vision OCR, draws the recognized lines over the preview, and `GeneralModePipeline.answerAboutCameraFrame` answers from the frame + text; the OCR text is pinned as context and the card hides after 60 s. Needs `NSCameraUsageDescription`.

**Read aloud** (`ReadingIntents.swift`): "read this to me" builds a `ReadAloudScript` (lines of the circled region, else the frontmost window via the AX window frame → paragraphs by gaps/headings → `NLTokenizer` sentences that remember their lines); each sentence is spoken (`speak` then `waitForSpeechToFinish`, polling `speechOutput.isPlaying`) while its lines are highlighted with a margin bar. The session survives a hotkey interruption: "skip"/"next"/"skip this section", "explain that" (General mode on the current sentence, then resume), "go back", "continue" (re-reads the screen when the visible text was finished), "stop". Any other question ends the session. Captions are suppressed while reading.

**Make readable**: `ReadableIntent` → `ReadabilityPipeline.structure` (headings, key-point lines, up to 5 definitions, spoken summary) drawn as `.marginBar` + underline on headings, yellow `.highlight` on key points, `.badge` definitions at line ends.

**Rewrite in place**: circle a paragraph, say "clearer" / "shorter" / "fix this" → `ReadabilityPipeline.rewrite` returns unchanged/changed segments → `.textBlock` paints the rewritten paragraph over the block on a sampled background with changed spans marked; the text also goes to the clipboard.

**Agent rehearsal**: with "Rehearse before acting" on (off by default; or per task with "rehearse …" / "… show me the plan first"), an agent task is first planned (`AgentModePipeline.plan`, 2–8 steps with element ids only for targets visible now) and acted out: a numbered route over the visible targets plus a translucent ghost buddy (`ghostCursorGlobalPoint`/`ghostStepLabel` rendered in `OverlayWindow`) that walks the steps in ~5 s with each step annotated. Then Octo waits (45 s) for the next transcript: "go"/"yes" runs `runAgentMode` with the approved plan folded into its notes; "cancel"/"no" drops it; anything else is a redirect that re-plans and rehearses again.

**Card sizes and tips**: `NotchIslandState.isLarge` (persisted `octoNotchLarge`) switches the card between 440 and 660 pt; pages read the width from the `notchCardWidth` environment value. Large mode shows a bigger vignette, extra per-mode hints and the last four runs (`recentInteractionReports`). `NotchInfoTip` is the hover "i" explanation used across the card and settings. Settings is a vertical-tab layout (`NotchSettingsView.Section`: Hotkey, Voice, Memory, Buddy, Services, About).

**Precise grounding (General mode)**: the model returns `highlights: [{element_id, quote}]` and `point_quote`; `GeneralModePipeline.groundedRect` accepts a highlight only if the quote is really in that element's text and shrinks it to the shortest run of OCR words containing the quote, so a word gets lit, not its line. A circled region only offers elements at least 60 % inside it, and highlights/points outside the offered set are impossible. Dropped highlights are logged with 🎯.

**Glass cards**: `GlassCardBackground` (system `glassEffect` on macOS 26, `NSVisualEffectView` blur below) backs the rewind card.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background. The chord is a user-recordable `PushToTalkChord` (modifiers, optionally plus one key; persisted as JSON under `octoPushToTalkChord`, legacy preset key migrated). Settings › Hotkey has a Record button: the same tap enters a recording mode (`beginRecordingChord`) and finishes on keyDown (modifiers + key) or when every modifier is released (modifier-only chord); Esc, an invalid chord or 10 s cancels. Presets remain as pills.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Octo" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Coordinate Contract**: Every box from OCR/extraction/analysis is in capture pixels (top-left origin of the captured display image). `CaptureGeometry` converts to overlay points (`pixel × displayPoints / capturePixels`) and to global AppKit coordinates for cursor pointing. The panel's "Calibrate overlay" outlines every OCR line for 5 s as a visual self-test.

**Grounding by ID**: The LLM never emits pixel coordinates. It receives numbered elements (Set-of-Mark) and returns IDs; Data-mode drawings are built from analysis results (row indices / column names), never from prose.

**Agent runs always plan first**: `runAgentMode` asks for a plan (`xhigh`) unless a rehearsal already produced one, shows it on the task card, and passes it to every decide call; each action reports `plan_step` so the card ticks the right row, unplanned actions get a new row. "Screen changed" uses the changed-cell fraction as well as the mean, so a Spotlight-sized window counts.

**Claude call hygiene**: every `completeJSON` passes an `effort` (`xhigh` plan, `high` act/verify, `medium` answers, `low` narration/translation) and enough `max_tokens` that a `max_tokens` stop is treated as an error. Element-id fields get a per-turn `enum` of the ids on screen (`JSONSchemaTools.settingEnum`); nullable enums must be `anyOf` (`nullableEnum`). Tools are **not** `strict`: strict mode compiles a grammar per distinct schema (~2 s, every turn with per-turn enums; measured 14 s per answer). The agent may answer `ask_user` / `cannot_determine` instead of guessing; each history line ends with "screen changed" / "no visible change" and a repeat or two dead actions inject a redirect note.

**Planner sees no data**: The Data-mode planner prompt contains column names, types and the row count only. Spoken numbers are produced by the analysis service; the LLM may rephrase and the app rejects a rephrase that drops any number.

**OCR warm-up**: Vision loads its text models on the first request (~7 s). `ScreenTextRecognizer.warmUp()` runs at launch so the first hotkey costs ~0.4 s.

**Element caps**: OCR keeps up to 240 lines, General sends up to 240 elements, Agent up to 320 (OCR plus up to 80 accessibility elements appended after). A dense IDE screen has 200+ lines; a cap below that makes the model say "i don't see it" for anything past it.

**Zoom pass (off)**: `GeneralModePipeline.zoomPass` sends a native-resolution crop around the first pass's targets with only the tags inside and asks the model to confirm or correct ids and quotes. Kept behind `isZoomPassEnabled` for experiments; see the grounding eval numbers before turning it on.

**Vision word boxes are padded**: `VNRecognizedText.boundingBox(for:)` returns boxes padded to roughly the line height, collapsing real 16 px cell gaps to ~3 px. `InkSegmenter` re-splits lines using a luminance projection profile; cell gaps are ≥ 0.36 × line height, spaces are not. Thin 2 px segments (a "1") must be kept.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. `CompanionAppDelegate` creates `MenuBarPanelManager` and starts `CompanionManager`. |
| `CompanionManager.swift` | ~720 | State machine and **mode router**. Owns dictation, shortcut monitor, overlay, drawing layer, speech output, both pipelines, service health polling, the calibration self-test and the edit-and-re-run watcher. `performInteraction` = capture → OCR → table/chart → route → draw → speak. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle (fallback on Macs without a notch; the status item toggles the notch otherwise). |
| `NotchPanelManager.swift` | ~250 | Notch canvas panel, hover/outside-click expand-collapse, notch geometry. |
| `NotchPanelContentView.swift` | ~210 | Expanded card: status, mode capsule + per-mode description and example, last run, hotkey chips, settings button. |
| `Notch/NotchIslandView.swift` | ~380 | `NotchSilhouetteShape`, `NotchIslandState`, island view. Collapsed: eyes behind the notch; while listening/thinking/speaking/acting the island grows a 96 pt wing each side (indicator left, word right) since the physical notch hides the middle. |
| `Notch/NotchSettingsView.swift` | ~430 | Settings page with vertical tabs (Hotkey, Voice, Memory, Buddy, Services, About): hotkey chord, transcription, captions, Octo colour swatches, buddy visibility, clipboard fallback, rehearsal, service status, calibrate. |
| `Sounder/Overlay/AgentTaskCardPanelManager.swift` | ~300 | Top-right glass card for Agent runs: the task in quotes, the planned steps (pending / active / done / failed), status line and summary. Sized from its content, hidden on the next hotkey. |
| `Sounder/OctoAppearance.swift` | ~65 | `OctoAccent` presets + `OctoAppearance.shared` (persisted `octoAccentColor`). `DS.Colors.overlayCursorBlue` reads it; every view that paints with it observes the singleton so a new pick repaints at once. |
| `Notch/SkyLightOperator.swift` | ~75 | Private SkyLight space at max level for the notch window (dlsym, optional). |
| `Notch/NotchContextView.swift` | ~270 | Context page: pinned items list, add field, Paste / Image… buttons, drag-and-drop. |
| `Notch/NotchModeVignetteView.swift` | ~190 | Animated per-mode "Octo in use" scene drawn in a Canvas. |
| `Sounder/Rewind/ScreenHistoryRecorder.swift` | ~280 | Rolling in-memory frame + OCR buffer, change detection, keyword/embedding search. |
| `Sounder/Rewind/RewindIntent.swift` | ~60 | "…five minutes ago" / "what did that say" detection and time parsing. |
| `Sounder/Rewind/RewindPanelManager.swift` | ~300 | Rewind card (glass): frame with highlighted lines, scrub bar, Esc/close; `GlassCardBackground`. |
| `Sounder/Router/QuickIntents.swift` | ~300 | Dictate / ink-math / extract intents, CSV·JSON·markdown builders, word-box grid. |
| `Sounder/Router/WhiteboardPipeline.swift` | ~80 | Conceptual question → node/edge diagram JSON. |
| `Sounder/Overlay/WhiteboardPanelManager.swift` | ~240 | Layered layout + sketched rendering of the diagram in a free margin. |
| `Sounder/Grounding/AccessibilityElementReader.swift` | ~220 | AX tree walk → labelled elements, press/focus/setValue, focused-window summary. |
| `Sounder/Camera/CameraContextPanelManager.swift` | ~240 | Webcam session, live preview card, frame grab, OCR overlay. |
| `Sounder/Router/ReadingIntents.swift` | ~170 | Read-aloud script builder + commands, make-readable and rewrite intents. |
| `Sounder/Router/ReadabilityPipeline.swift` | ~110 | Structure and rewrite JSON calls. |
| `Sounder/Router/TranslatePipeline.swift` | ~130 | Translate intent + language filter, Claude line translation, background colour sampler. |
| `api/proxy.ts`, `vercel.json`, `.vercelignore` (repo root) | ~20 | Root Vercel entry so GitHub-triggered deploys (from the repo root) serve the same proxy as `worker/`. |
| `Sounder/Context/UserContextStore.swift` | ~270 | Persisted notes/links/images + `promptBundle()` for the pipelines. |
| `CompanionPanelView.swift` | ~560 | Panel UI: permissions, Start, mode picker (Auto/General/Data), service status, last-run latency/confidence readout, options (clipboard fallback, offline voice, show cursor, calibrate). |
| `OverlayWindow.swift` | ~780 | Full-screen transparent overlay hosting the blue cursor and `DrawingLayerView`. Cursor animation, bezier pointing, multi-monitor. |
| `Sounder/SounderConfiguration.swift` | ~40 | Info.plist-backed config: Worker URL, analysis URL, chat model, speech provider, LLM narration flag. |
| `Sounder/SounderMode.swift` | ~47 | `automatic` / `general` / `clinical` / `agent` with display name, explanation and example question. |
| `Sounder/Backend/SounderModels.swift` | ~300 | `CaptureGeometry`, `ScreenElement`, `ExtractedTable`, `ChartRegion`/`AxisCalibration`, analysis response Codables (snake_case mirror of `services/analysis/schemas.py`), `SounderInteractionReport`. |
| `Sounder/Backend/FireworksChatClient.swift` | ~190 | OpenAI-compatible chat via Worker `/chat`: images as data URLs, JSON-schema `response_format`, `reasoning_effort: low`, prior turns. |
| `Sounder/Backend/AnalysisServiceClient.swift` | ~100 | `/health`, `/analyze`. |
| `Sounder/Capture/NativeScreenCaptureUtility.swift` | ~140 | Native-resolution capture of the display under the cursor; region thumbnails for the change watcher; downscaled JPEG for the VLM. |
| `Sounder/Grounding/ScreenElementDetector.swift` | ~330 | `ScreenTextRecognizer` (Vision OCR → lines/words in capture px, warm-up), `GrayscaleBitmap`, `InkSegmenter`, `ScreenElementDetector.makeElements`. |
| `Sounder/Grounding/SetOfMarkRenderer.swift` | ~100 | Numbered red tags drawn on a downscaled screenshot for the vision model. |
| `Sounder/Extraction/TableExtractor.swift` | ~330 | OCR words → `ExtractedTable` (rows, columns, header, gutter row labels, types, confidence, cell boxes). `CellValueParser`, `TableColumnTyping`. |
| `Sounder/Extraction/ChartRegionDetector.swift` | ~150 | Numeric tick labels → plot bbox + linear axis calibrations. `SOUNDER_DEBUG_CHART=1` traces. |
| `Sounder/Extraction/ClipboardTableExtractor.swift` | ~230 | ⌘A/⌘C via CGEvent, TSV/CSV parse, merge clipboard rows with OCR geometry. |
| `Sounder/Extraction/ScreenChangeWatcher.swift` | ~120 | Region thumbnail diffing; fires once after a change settles. |
| `Sounder/Overlay/DrawingPrimitives.swift` | ~150 | `DrawingPrimitive` enum + `DrawingOpsBuilder` (`circleRows`, `barsUnderHeaders`, `curve`, `highlightCells`, `highlightElements`, `calibrationOutlines`). |
| `Sounder/Overlay/DrawingLayerView.swift` | ~200 | `DrawingLayerModel` (show/clear/auto-clear) + SwiftUI renderer, capture px → overlay points. |
| `Sounder/Clinical/ClinicalLexicon.swift` | ~130 | Drug name → RXCUI table (bundle JSON + built-in fallback), condition aliases → ICD-10, lab keys. |
| `Sounder/Clinical/ClinicalEntityExtractor.swift` | ~260 | OCR rows → `ClinicalScreenReading` (medications with dose/frequency boxes, conditions, labs, age, sex). |
| `Sounder/Clinical/ClinicalServiceClient.swift` | ~100 | `/clinical/check`, `/clinical/evidence`. |
| `Sounder/Router/ClinicalModePipeline.swift` | ~230 | Intent keywords, concept payload + privacy assertion, findings → severity-coloured links/underlines/badges (no references drawer), Claude narration, evidence badges. |
| `Sounder/Router/ResearchAgent.swift` | ~160 | Claude web-search: task plans for unfamiliar apps, `mediaRequest(in:)` keyword intent + `findMedia` (paper/image/video/link card, screen text as context). |
| `Sounder/Overlay/MediaCardPanelManager.swift` | ~215 | Clickable paper/image/video card panel the buddy holds up. |
| `Sounder/Router/GeneralModePipeline.swift` | ~110 | Set-of-Mark vision answer `{speak, point_element_id, point_label, highlight_element_ids}`. |
| `Sounder/Router/DataModePipeline.swift` | ~260 | Planner (LLM JSON + keyword fallback), analysis call, drawing primitives, templated speech + verified LLM rephrase. |
| `Sounder/Voice/FireworksAudioTranscriptionProvider.swift` | ~210 | Upload-based `BuddyTranscriptionProvider` for Fireworks Whisper via Worker `/transcribe`. |
| `Sounder/Voice/SpeechOutputClient.swift` | ~100 | `SpeechOutputClient` protocol, `SystemSpeechOutputClient` (AVSpeechSynthesizer), ElevenLabs conformance. |
| `Sounder/Voice/MultipartFormDataBuilder.swift` | ~45 | Multipart encoder for audio uploads. |
| `BuddyDictationManager.swift` | ~890 | Push-to-talk voice pipeline (AVAudioEngine, permissions, transcript finalization). Provider is injectable/replaceable (`replaceTranscriptionProvider`). |
| `BuddyTranscriptionProvider.swift` | ~110 | Provider protocol + factory (`fireworks` default, `apple`, `assemblyai`, `openai`). |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Legacy streaming provider (token URL from `SounderConfiguration`). |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Legacy upload provider. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Offline fallback provider. |
| `BuddyAudioConversionSupport.swift` | ~108 | PCM16 conversion + WAV builder. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~180 | Listen-only CGEvent tap for the push-to-talk chord; chord recording mode. |
| `Sounder/Voice/PushToTalkChord.swift` | ~80 | Recordable chord model: modifiers + optional key, key-cap labels, validity. |
| `ElevenLabsTTSClient.swift` | ~81 | Optional TTS via Worker `/tts`. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Legacy multi-monitor downscaled capture (unused by the Octo pipeline). |
| `CompanionResponseOverlay.swift` | ~217 | Legacy response bubble (unused). |
| `DesignSystem.swift` | ~880 | `DS.Colors`, `DS.CornerRadius`, button styles. |
| `ClickyAnalytics.swift` | ~140 | PostHog wrapper, opt-in via `PostHogAPIKey`. |
| `WindowPositionManager.swift` | ~262 | Permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Info.plist reader. |
| `worker/src/index.ts` | ~320 | Proxy handler (routes above); runs on Vercel via `worker/api/proxy.ts`. |
| `services/analysis/*.py` | ~600 | FastAPI analysis service (`app.py`, `schemas.py`, `table_frame.py`, `anomaly.py`, `drivers.py`, `curve_fit.py`, `narration.py`). Tests in `services/tests`. |
| `services/clinical/*.py` + `data/*.json` | ~450 | Clinical rules (`rules.py`), evidence (`evidence.py`), schemas, lexicon builder, seed data (75 interaction pairs, dosing/renal rules, evidence cache, sponsored slot). Tests in `services/tests/test_clinical.py`. |
| `services/modal_app.py` | ~30 | Modal deployment of the analysis + clinical service. |
| `demo/chart.html` | ~110 | Synthetic patient chart with editable med list for the Rx demo. |
| `services/synth/generate_synthetic_tables.py` | ~170 | Playwright synthetic spreadsheet renderer → COCO boxes (extractor training data). |
| `services/extractor/train.py`, `serve.py` | ~250 | RF-DETR fine-tune and `/extract` service scaffolds (untested, need GPU/weights). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Proxy (deployed on Vercel; Cloudflare Worker code)

The proxy source is a Cloudflare-style `fetch(request, env)` handler. It is **deployed on Vercel** as an Edge Function: `worker/api/proxy.ts` wraps it with `process.env` as the env bindings, and `worker/vercel.json` rewrites every path to `/api/proxy?path=…` so the handler sees the original path. Production URL: `https://octo-proxy.vercel.app` (project `octo-proxy`, team amanibobos-projects). The project is also connected to the GitHub repo: every push to `main` deploys from the repo root, which is why `api/proxy.ts` + `vercel.json` exist at the root (they wrap `worker/api/proxy.ts`; `config = { runtime: "edge" }` must be declared literally there). Each deploy causes ~30 s of intermittent 404s while the alias moves. Info.plist `SounderWorkerBaseURL` points there, so the app no longer needs a local Worker.

```bash
cd worker
npm install

# Deploy (already linked; `npx vercel login` first on a new machine)
npx vercel deploy --prod --yes
# Secrets/vars live in the Vercel project (ANTHROPIC_API_KEY, FIREWORKS_API_KEY,
# ELEVENLABS_API_KEY, CLAUDE_MODEL, FIREWORKS_*_MODEL, ELEVENLABS_VOICE_ID, ANALYSIS_BACKEND_URL):
printf '%s' "$VALUE" | npx vercel env add NAME production --force

# Local dev alternative (keys in worker/.dev.vars, gitignored), then set SounderWorkerBaseURL to http://127.0.0.1:8787
npx wrangler dev --port 8787
```

## Analysis service (Python)

```bash
cd services
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn analysis.app:app --port 8000
.venv/bin/python -m pytest -q tests          # 5 tests: health, anomaly, drivers, fit, 422
```

## Typechecking without Xcode

`xcodebuild` is off-limits (TCC), but the sources can be typechecked with `swiftc -typecheck` using stub modules for PostHog and Sparkle and the project's flags (`-swift-version 5 -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility ...`). Copy the sources to a temp folder first: this repo lives under `~/Documents`, and iCloud touches file mtimes mid-compile ("input file was modified during the build").

## Grounding eval

`eval/grounding/run.sh` compiles the real pipeline sources (OCR → Set-of-Mark → `GeneralModePipeline` through the proxy) into a CLI and runs saved cases: `cases/<name>/screenshot.png` (native capture) + `cases/<name>/cases.json` (`question`, `expect` quote, `where`: point / highlight / any). A case passes when the pointed or highlighted element's text contains the quote. `./run.sh --dump` lists numbered OCR lines to write questions from; `--zoom` turns the native-resolution second pass on; `--only <case>` runs one screenshot. Results land in `eval/grounding/results/` (gitignored). Baseline on 27 cases across an IDE, a patient chart and System Settings: 23/27 with the old 100-element cap (every miss was an element past the cap), 27/27 expected after raising it; the zoom pass changed no answers and cost ~2 s per question, so it is off by default (`GeneralModePipeline.isZoomPassEnabled`). Measure before changing prompts, tags or caps.

## Extraction harness

A standalone harness (render a synthetic Sheets screenshot with AppKit → `ScreenTextRecognizer` → `TableExtractor` → `ChartRegionDetector` → clipboard merge) compiles `Sounder/Backend/SounderModels.swift`, `Sounder/Grounding/ScreenElementDetector.swift`, `Sounder/Extraction/*.swift` and `Sounder/Capture/NativeScreenCaptureUtility.swift` with a `main.swift`. Last measured: 26×8 table, 8/8 headers, ~90% cell accuracy, chart axes within 2 px.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions
- Do not let the LLM emit pixel coordinates or invent numbers: grounding is by element ID, spoken statistics come from the analysis service
- Do not put OCR text, patient identifiers or free text into `/clinical/*` payloads; `ClinicalModePipeline.privacyReport` asserts on it
- Do not commit `worker/.dev.vars` or any API key

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

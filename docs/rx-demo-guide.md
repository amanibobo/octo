# Octo Rx: test charts and what to ask

Five synthetic charts live in `demo/`. Open one in a browser (Chrome or Safari, ⌘0 for 100% zoom so the text is crisp), keep the whole chart on screen, and hold `ctrl + option` while you speak. Octo reads the screen when you let go.

Every patient is synthetic. Findings below are what the rules engine returns for each chart; Octo narrates them in its own words, so the wording varies but the numbers and drug names will not.

## The charts

### `chart.html` — Robert Ellison, 71 M, eGFR 38
The original demo. Warfarin plus a new fluconazole, metformin at 1000 mg twice a day with CKD 3b.

Expected findings:
- **Red** warfarin + fluconazole (major, INR rise)
- **Red** metformin 2000 mg/day above the renal maximum of 1000 at eGFR 38
- **Yellow** fluconazole + atorvastatin (moderate, statin exposure)
- **Yellow** fluconazole dose should be halved at eGFR under 50

### `chart-margaret.html` — Margaret Okafor, 82 F, eGFR 32
The "too much for an 82-year-old with bad kidneys" chart. Nothing interacts dramatically; the problem is doses.

Expected findings:
- **Red** gabapentin 1800 mg/day above the renal maximum of 1400
- **Red** rivaroxaban 20 mg above the renal maximum of 15 at eGFR 32
- **Red** metoprolol + diltiazem (major, bradycardia and heart block)
- **Yellow** citalopram 40 mg above the 20 mg maximum over age 60
- **Yellow** zolpidem 10 mg above the 5 mg maximum over age 65
- **Yellow** tramadol 400 mg/day above the 300 mg maximum over age 75

The plan note mentions drowsiness and near-falls, which is the story: the findings explain the falls.

### `chart-daniel.html` — Daniel Reyes, 58 M, eGFR 84
The cardiology interaction chart. Kidneys are fine, so everything flagged is drug-on-drug or dose.

Expected findings:
- **Red** simvastatin + clarithromycin (major, rhabdomyolysis)
- **Red** simvastatin + amiodarone (major, cap simvastatin at 20)
- **Red** digoxin + amiodarone (major, digoxin level doubles; the labs show a digoxin level of 1.4, already high)
- **Red** isosorbide mononitrate + sildenafil (major, profound hypotension)
- **Red** simvastatin 80 mg above the label maximum of 40
- **Yellow** simvastatin + amlodipine (moderate)
- **Yellow** apixaban + aspirin (moderate, bleeding)

Good chart for the circle gesture: circle just the statin row and ask about it, then circle the nitrate and sildenafil rows.

### `chart-priya.html` — Priya Natarajan, 34 F, eGFR 98
Young, healthy kidneys, three major interactions hiding in a short list.

Expected findings:
- **Red** lithium + hydrochlorothiazide (major, lithium toxicity; HCTZ was started today)
- **Red** lithium + ibuprofen (major, lithium toxicity)
- **Red** sertraline + tramadol (major, serotonin syndrome and seizures)

### `chart-elena.html` — Elena Park, 45 F, eGFR 103
The control. Four sensible drugs, all labs at goal. Octo should say it checked four medications and found nothing to flag. Use this to show it does not cry wolf.

## Which mode to use

- **Auto** (default): a chart on screen plus a clinical-sounding question routes to Rx on its own. Words that trigger it: med, drug, interaction, dose, safe, problem, kidney, renal, check, list, regimen. "What's new / latest / evidence / trial / guideline" routes to the evidence lookup instead.
- **Rx** (pick it in the notch card): forces Rx no matter how the question is phrased. Use this on stage so a casually worded question can never fall through to General mode.
- **General**: for questions about the chart that are not medication checks, such as "what does NT-proBNP mean here?" Octo answers from the screen and points.

## Questions to ask

Medication check (any chart):
- "Anything I should worry about with these meds?"
- "Is this med list safe for her?"
- "Check this regimen against her kidneys."
- "Any interactions here?"
- "Is the gabapentin dose okay for this patient?" (Margaret)
- "Should he be on eighty of simvastatin?" (Daniel)
- "She just got started on hydrochlorothiazide, is that a problem?" (Priya)
- "Do these meds look fine?" (Elena, expect the all-clear)

Scoped with the circle gesture (hold the hotkey, draw a loop around the rows with the cursor, keep talking, let go):
- Circle simvastatin and clarithromycin on Daniel: "What about these two together?"
- Circle just the rivaroxaban row on Margaret: "Is this dose right for her kidneys?"
- Circle lithium alone on Priya: "What's new on this?" (evidence scoped to that drug)

Evidence (routes to PubMed plus the seeded cache):
- "What's new for atrial fibrillation?" (Robert, Margaret, Daniel)
- "Any recent trials on HFpEF?" (Robert; this one also shows the disclosed sponsored slot)
- "Latest guidance on type 2 diabetes?" (Robert, Elena)
- "Anything new on chronic kidney disease?" (Robert, Margaret)

Edit-and-re-run (the med cells are editable):
- Ask a check question, then click a cell, add a drug to the empty last row, and click away. Octo watches that region for about twelve seconds after an answer and re-runs the same question when the pixels settle. Good additions: type `Ibuprofen` / `400 mg` / `PO TID` on Robert (new warfarin interaction) or `Clarithromycin` on Elena (still nothing, since nothing she takes interacts with it).

Media card from the chart:
- "Show me a paper on warfarin and amiodarone."
- "Pull up a video on how amiodarone affects digoxin."

## Things that will not work, so you don't hit them on stage

- Brand names. The charts use generics on purpose; the lexicon is RxNorm generics.
- Drugs the rules do not know. The interaction table covers about 75 pairs and the dosing table about 50 drugs; a drug outside both is read but silently passes. Sumatriptan on Priya's chart is one of these.
- Two charts on screen at once. Octo reads the display under the cursor as a whole.
- Speaking before the card is fully on screen. Let the page settle, then hold the hotkey.

# Sounder services (Python)

| Folder | What | Status |
|---|---|---|
| `analysis/` | FastAPI service: `POST /analyze` with `anomaly`, `drivers`, `fit` tasks. IsolationForest + robust z-score reasons, HistGradientBoosting + permutation importance with held-out AUC/R², AIC-selected curve fit with 95% band. | **Tested** (`pytest tests`) |
| `modal_app.py` | Deploys `analysis/` to Modal with one warm container. | Written, not deployed (needs your Modal account) |
| `synth/` | Playwright renderer for randomized spreadsheet screenshots + COCO cell boxes (extractor training data). | Written, needs `playwright install chromium` |
| `extractor/train.py` | RF-DETR fine-tune scaffold on the synthetic set (GPU). | Scaffold, untested |
| `extractor/serve.py` | `/extract` endpoint (RF-DETR + PaddleOCR) returning the same table JSON the Swift app produces on device. | Scaffold, untested |

## Run the analysis service locally

```bash
cd services
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn analysis.app:app --port 8000
.venv/bin/python -m pytest -q tests
```

Try it:

```bash
.venv/bin/python tests/make_sample_table.py 400 > /tmp/telco.csv   # Telco-shaped synthetic data
curl -s localhost:8000/analyze -H 'content-type: application/json' -d @- <<'JSON'
{"task":"drivers","target_col":"Churn","table":{"headers":["tenure","Contract","MonthlyCharges","Churn"],
 "rows":[["1","Month-to-month","70.2","Yes"],["40","Two year","20.1","No"],["3","Month-to-month","90.5","Yes"],["60","One year","55","No"],
 ["2","Month-to-month","80","Yes"],["50","Two year","25","No"],["5","Month-to-month","95","Yes"],["70","Two year","30","No"],
 ["4","Month-to-month","85","Yes"],["45","One year","40","No"],["6","Month-to-month","99","Yes"],["66","Two year","35","No"],
 ["7","Month-to-month","75","No"],["30","One year","45","No"],["8","Month-to-month","88","Yes"],["55","Two year","28","No"],
 ["9","Month-to-month","91","Yes"],["61","Two year","33","No"],["10","Month-to-month","72","Yes"],["48","One year","50","No"]]}}
JSON
```

Optional: `SOUNDER_USE_TABPFN=1` with `pip install tabpfn tabpfn-extensions` swaps in TabPFN v2 for the held-out metric and outlier scoring (weights download on first use).

## Deploy to Modal

```bash
pip install modal && modal setup
cd services && modal deploy modal_app.py
```

Put the printed URL into `leanring-buddy/Info.plist` → `SounderAnalysisBaseURL` (or set `ANALYSIS_BACKEND_URL` on the Worker and point the app at `<worker>/analysis`).

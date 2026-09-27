"""FastAPI entry point for the Sounder analysis service.

Run locally:  cd services && .venv/bin/uvicorn analysis.app:app --port 8000
Deploy:       cd services && modal deploy modal_app.py
"""

from __future__ import annotations

import time

from fastapi import FastAPI, HTTPException

from .anomaly import score_anomalies
from .curve_fit import fit_curve
from .drivers import analyze_drivers
from .narration import summarize_anomalies, summarize_drivers, summarize_fit
from .schemas import AnalyzeRequest, AnalyzeResponse
from .table_frame import build_typed_frame, resolve_column_name

from clinical.evidence import find_evidence
from clinical.rules import check_medications
from clinical.schemas import ClinicalCheckRequest, ClinicalCheckResponse, EvidenceRequest, EvidenceResponse

app = FastAPI(title="Sounder analysis + clinical service", version="0.2.0")


@app.get("/health")
def health() -> dict:
    return {"ok": True, "service": "sounder-analysis", "tasks": ["anomaly", "drivers", "fit", "clinical/check", "clinical/evidence"]}


@app.post("/clinical/check", response_model=ClinicalCheckResponse)
def clinical_check(request: ClinicalCheckRequest) -> ClinicalCheckResponse:
    """Interaction, dosing, renal and age checks. Input is concept IDs and numbers only."""
    return check_medications(request)


@app.post("/clinical/evidence", response_model=EvidenceResponse)
def clinical_evidence(request: EvidenceRequest) -> EvidenceResponse:
    return find_evidence(request.condition, request.drug)


@app.post("/analyze", response_model=AnalyzeResponse)
def analyze(request: AnalyzeRequest) -> AnalyzeResponse:
    started = time.perf_counter()
    if not request.table.headers or not request.table.rows:
        raise HTTPException(status_code=400, detail="table must have headers and at least one row")

    frame, column_types = build_typed_frame(request.table)
    warnings: list[str] = []

    try:
        if request.task == "anomaly":
            group_col = resolve_column_name(frame, request.group_col)
            result, task_warnings = score_anomalies(frame, column_types, request.k, group_col)
            return AnalyzeResponse(
                task="anomaly",
                summary_text=summarize_anomalies(result),
                elapsed_seconds=round(time.perf_counter() - started, 3),
                warnings=warnings + task_warnings,
                anomaly=result,
            )

        if request.task == "drivers":
            target_col = resolve_column_name(frame, request.target_col)
            if target_col is None:
                raise HTTPException(status_code=422, detail=f"target column '{request.target_col}' not found in headers")
            result, task_warnings = analyze_drivers(frame, column_types, target_col)
            return AnalyzeResponse(
                task="drivers",
                summary_text=summarize_drivers(result),
                elapsed_seconds=round(time.perf_counter() - started, 3),
                warnings=warnings + task_warnings,
                drivers=result,
            )

        if request.task == "fit":
            x_col, y_col = _pick_fit_columns(frame, column_types, request.x_col, request.y_col)
            result, task_warnings = fit_curve(frame, x_col, y_col)
            return AnalyzeResponse(
                task="fit",
                summary_text=summarize_fit(result),
                elapsed_seconds=round(time.perf_counter() - started, 3),
                warnings=warnings + task_warnings,
                fit=result,
            )
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error

    raise HTTPException(status_code=400, detail=f"unknown task {request.task}")


def _pick_fit_columns(frame, column_types, requested_x, requested_y) -> tuple[str, str]:
    numeric_columns = [column for column, column_type in column_types.items() if column_type == "numeric"]
    x_col = resolve_column_name(frame, requested_x)
    y_col = resolve_column_name(frame, requested_y)
    if x_col is None or column_types.get(x_col) != "numeric":
        remaining = [column for column in numeric_columns if column != y_col]
        if not remaining:
            raise ValueError("no numeric x column available for fitting")
        x_col = remaining[0]
    if y_col is None or column_types.get(y_col) != "numeric":
        remaining = [column for column in numeric_columns if column != x_col]
        if not remaining:
            raise ValueError("no numeric y column available for fitting")
        y_col = remaining[-1]
    return x_col, y_col

"""Pydantic models shared by the FastAPI routes and the Swift client (SounderModels.swift)."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

AnalysisTask = Literal["anomaly", "drivers", "fit"]
ColumnType = Literal["numeric", "categorical", "date", "text"]


class TablePayload(BaseModel):
    """A table as extracted from the screen: header names plus rows of raw cell strings."""

    headers: list[str]
    rows: list[list[str | None]]
    column_types: list[ColumnType] | None = None


class AnalyzeRequest(BaseModel):
    task: AnalysisTask
    table: TablePayload
    target_col: str | None = None
    group_col: str | None = None
    k: int = Field(default=6, ge=1, le=50)
    x_col: str | None = None
    y_col: str | None = None


class AnomalyReason(BaseModel):
    column: str
    value: str
    comparison_text: str
    z_score: float


class AnomalyRow(BaseModel):
    row_index: int
    score: float
    reasons: list[AnomalyReason]
    spoken_reason: str


class AnomalyResult(BaseModel):
    rows: list[AnomalyRow]
    method: str
    n_rows_scored: int


class DriverImportance(BaseModel):
    column: str
    importance: float


class DriversResult(BaseModel):
    target_col: str
    problem_type: Literal["binary", "multiclass", "regression"]
    importances: list[DriverImportance]
    metric_name: str
    metric_value: float
    train_seconds: float
    n_rows_train: int
    n_rows_holdout: int
    model_name: str
    dropped_columns: list[str]


class FitResult(BaseModel):
    x_col: str
    y_col: str
    model_name: str
    equation_text: str
    r_squared: float
    points: list[list[float]]
    band: list[list[float]]
    x_range: list[float]
    y_range: list[float]
    n_points: int


class AnalyzeResponse(BaseModel):
    task: AnalysisTask
    summary_text: str
    elapsed_seconds: float
    warnings: list[str] = []
    anomaly: AnomalyResult | None = None
    drivers: DriversResult | None = None
    fit: FitResult | None = None

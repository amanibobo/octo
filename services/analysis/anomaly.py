"""Anomaly scoring with per-row spoken reasons.

Primary scorer: IsolationForest over numeric columns plus frequency-encoded
categoricals. If TabPFN is installed and enabled, its outlier scorer is used
instead (see `_try_tabpfn_scores`). Reasons are always computed the same way:
robust z-scores against the column median (or the group median when a group
column is given), so the spoken explanation never depends on the model.
"""

from __future__ import annotations

import os

import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest

from .schemas import AnomalyReason, AnomalyResult, AnomalyRow

_MINIMUM_ABSOLUTE_Z_FOR_REASON = 2.0
_RARE_CATEGORY_SHARE = 0.05


def _robust_z_scores(values: pd.Series) -> pd.Series:
    median = values.median()
    mad = (values - median).abs().median()
    scale = 1.4826 * mad
    if not np.isfinite(scale) or scale == 0:
        scale = values.std(ddof=0)
    if not np.isfinite(scale) or scale == 0:
        return pd.Series(np.zeros(len(values)), index=values.index)
    return (values - median) / scale


def _format_value(value: float) -> str:
    if abs(value) >= 1000:
        return f"{value:,.0f}"
    if abs(value) >= 100:
        return f"{value:.0f}"
    if abs(value) >= 10:
        return f"{value:.1f}"
    return f"{value:.2f}".rstrip("0").rstrip(".")


def _comparison_text(column: str, value: float, reference_median: float, z_score: float) -> str:
    if reference_median and np.isfinite(reference_median) and reference_median > 0 and value >= 0:
        ratio = value / reference_median
        if ratio >= 1.5:
            return f"{column} is {ratio:.1f} times the median"
        if ratio <= 0.67:
            return f"{column} is only {ratio * 100:.0f} percent of the median"
    direction = "above" if z_score > 0 else "below"
    return f"{column} is {abs(z_score):.1f} deviations {direction} typical"


def _build_feature_matrix(frame: pd.DataFrame, column_types: dict[str, str]) -> tuple[np.ndarray, list[str]]:
    feature_columns: list[np.ndarray] = []
    used_names: list[str] = []

    for column, column_type in column_types.items():
        series = frame[column]
        if column_type == "numeric":
            numeric = series.astype(float)
            if numeric.notna().sum() < 3 or numeric.nunique(dropna=True) < 2:
                continue
            filled = numeric.fillna(numeric.median())
            feature_columns.append(filled.to_numpy())
            used_names.append(column)
        elif column_type == "categorical":
            # Frequency encoding: rare categories get small values, which the
            # isolation forest treats as unusual. Cheap and dependency free.
            counts = series.value_counts(dropna=True)
            share = series.map(lambda v: counts.get(v, 0) / max(1, len(series))).astype(float)
            feature_columns.append(share.to_numpy())
            used_names.append(column)

    if not feature_columns:
        return np.empty((len(frame), 0)), []
    return np.column_stack(feature_columns), used_names


def _try_tabpfn_scores(feature_matrix: np.ndarray) -> np.ndarray | None:
    if os.environ.get("SOUNDER_USE_TABPFN") != "1":
        return None
    try:
        from tabpfn_extensions.unsupervised import TabPFNUnsupervisedModel  # type: ignore
        from tabpfn import TabPFNClassifier, TabPFNRegressor  # type: ignore
    except Exception:
        return None
    try:
        model = TabPFNUnsupervisedModel(TabPFNClassifier(), TabPFNRegressor())
        model.fit(feature_matrix)
        return -np.asarray(model.outliers(feature_matrix), dtype=float)
    except Exception:
        return None


def score_anomalies(
    frame: pd.DataFrame,
    column_types: dict[str, str],
    top_k: int,
    group_col: str | None,
) -> tuple[AnomalyResult, list[str]]:
    warnings: list[str] = []
    feature_matrix, used_names = _build_feature_matrix(frame, column_types)
    if feature_matrix.shape[1] == 0 or len(frame) < 5:
        raise ValueError("Need at least 5 rows and one numeric or categorical column to score anomalies.")

    scores = _try_tabpfn_scores(feature_matrix)
    method = "tabpfn-unsupervised"
    if scores is None:
        method = "isolation-forest"
        forest = IsolationForest(n_estimators=256, contamination="auto", random_state=0)
        forest.fit(feature_matrix)
        # score_samples is higher for normal points; flip so higher = more anomalous.
        scores = -forest.score_samples(feature_matrix)

    ranked_indices = np.argsort(-scores)[: min(top_k, len(frame))]

    numeric_columns = [c for c, t in column_types.items() if t == "numeric" and c in used_names]
    categorical_columns = [c for c, t in column_types.items() if t == "categorical" and c in used_names]

    # Pre-compute z-scores per column, optionally within groups.
    z_by_column: dict[str, pd.Series] = {}
    median_by_column: dict[str, pd.Series] = {}
    if group_col and group_col in frame.columns:
        grouped = frame.groupby(frame[group_col].astype(str), dropna=False)
        for column in numeric_columns:
            if column == group_col:
                continue
            z_by_column[column] = grouped[column].transform(_robust_z_scores)
            median_by_column[column] = grouped[column].transform("median")
    else:
        if group_col:
            warnings.append(f"group column '{group_col}' not found; compared against whole-table medians")
        for column in numeric_columns:
            z_by_column[column] = _robust_z_scores(frame[column].astype(float))
            median_by_column[column] = pd.Series(np.full(len(frame), frame[column].median()), index=frame.index)

    category_share: dict[str, pd.Series] = {}
    for column in categorical_columns:
        counts = frame[column].value_counts(dropna=True)
        category_share[column] = frame[column].map(lambda v: counts.get(v, 0) / max(1, len(frame)))

    rows: list[AnomalyRow] = []
    for row_position in ranked_indices:
        row_index = int(frame.index[row_position])
        candidate_reasons: list[tuple[float, AnomalyReason]] = []

        for column in numeric_columns:
            value = frame.at[row_index, column]
            z_score = z_by_column[column].iloc[row_position]
            if value is None or not np.isfinite(value) or not np.isfinite(z_score):
                continue
            if abs(z_score) < _MINIMUM_ABSOLUTE_Z_FOR_REASON:
                continue
            reference_median = float(median_by_column[column].iloc[row_position])
            candidate_reasons.append((
                abs(float(z_score)),
                AnomalyReason(
                    column=column,
                    value=_format_value(float(value)),
                    comparison_text=_comparison_text(column, float(value), reference_median, float(z_score)),
                    z_score=round(float(z_score), 2),
                ),
            ))

        for column in categorical_columns:
            value = frame.at[row_index, column]
            share = category_share[column].iloc[row_position]
            if value is None or share >= _RARE_CATEGORY_SHARE:
                continue
            candidate_reasons.append((
                1.0 / max(share, 1e-6) / 100.0,
                AnomalyReason(
                    column=column,
                    value=str(value),
                    comparison_text=f"{column} has the rare value {value}, seen in {share * 100:.1f} percent of rows",
                    z_score=0.0,
                ),
            ))

        candidate_reasons.sort(key=lambda pair: -pair[0])
        reasons = [reason for _, reason in candidate_reasons[:3]]
        if reasons:
            spoken_reason = "; ".join(reason.comparison_text for reason in reasons)
        else:
            spoken_reason = "an unusual combination of values across several columns"

        rows.append(AnomalyRow(
            row_index=row_index,
            score=round(float(scores[row_position]), 4),
            reasons=reasons,
            spoken_reason=spoken_reason,
        ))

    return AnomalyResult(rows=rows, method=method, n_rows_scored=len(frame)), warnings

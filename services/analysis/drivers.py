"""Driver analysis: train a model on the table, report held-out quality and per-column importance.

Model: scikit-learn HistGradientBoosting (native categorical support, fast on
laptops, no OpenMP install headaches). Importance: permutation importance on the
held-out split, so it reflects real predictive contribution rather than split
counts. If TabPFN is installed and SOUNDER_USE_TABPFN=1, TabPFN provides the
held-out metric and the boosting model still provides importances.
"""

from __future__ import annotations

import os
import time

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor
from sklearn.inspection import permutation_importance
from sklearn.metrics import accuracy_score, r2_score, roc_auc_score
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import OrdinalEncoder

from .schemas import DriverImportance, DriversResult

_MAX_CATEGORICAL_CARDINALITY = 200
_ID_LIKE_UNIQUE_SHARE = 0.9


def _decide_problem_type(target: pd.Series, target_type: str) -> str:
    non_null = target.dropna()
    unique_count = non_null.nunique()
    if target_type == "numeric" and unique_count > 10:
        return "regression"
    if unique_count == 2:
        return "binary"
    return "multiclass"


def analyze_drivers(
    frame: pd.DataFrame,
    column_types: dict[str, str],
    target_col: str,
) -> tuple[DriversResult, list[str]]:
    warnings: list[str] = []
    if target_col not in frame.columns:
        raise ValueError(f"target column '{target_col}' not found")

    target_raw = frame[target_col]
    problem_type = _decide_problem_type(target_raw, column_types[target_col])

    usable_mask = target_raw.notna()
    working = frame.loc[usable_mask].copy()
    if len(working) < 20:
        raise ValueError("Need at least 20 rows with a target value to train a model.")

    dropped_columns: list[str] = []
    numeric_features: list[str] = []
    categorical_features: list[str] = []
    for column, column_type in column_types.items():
        if column == target_col:
            continue
        series = working[column]
        if column_type == "numeric":
            if series.nunique(dropna=True) < 2:
                dropped_columns.append(column)
                continue
            numeric_features.append(column)
        elif column_type in {"categorical", "text", "date"}:
            unique_share = series.nunique(dropna=True) / max(1, len(series))
            if unique_share >= _ID_LIKE_UNIQUE_SHARE or series.nunique(dropna=True) > _MAX_CATEGORICAL_CARDINALITY:
                dropped_columns.append(column)  # identifiers carry no signal
                continue
            if series.nunique(dropna=True) < 2:
                dropped_columns.append(column)
                continue
            categorical_features.append(column)

    feature_names = numeric_features + categorical_features
    if not feature_names:
        raise ValueError("No usable feature columns besides the target.")

    encoder = OrdinalEncoder(handle_unknown="use_encoded_value", unknown_value=-1, encoded_missing_value=-1)
    features = pd.DataFrame(index=working.index)
    for column in numeric_features:
        features[column] = working[column].astype(float)
    if categorical_features:
        encoded = encoder.fit_transform(working[categorical_features].astype(object).fillna("<missing>"))
        for position, column in enumerate(categorical_features):
            features[column] = encoded[:, position]

    categorical_mask = [column in categorical_features for column in feature_names]
    feature_matrix = features[feature_names].to_numpy(dtype=float)

    if problem_type == "regression":
        target = working[target_col].astype(float).to_numpy()
        model = HistGradientBoostingRegressor(max_iter=300, learning_rate=0.06, early_stopping=True, random_state=0,
                                              categorical_features=categorical_mask)
        stratify = None
        scoring = "r2"
    else:
        target_labels, target = np.unique(working[target_col].astype(str).to_numpy(), return_inverse=True)
        model = HistGradientBoostingClassifier(max_iter=300, learning_rate=0.06, early_stopping=True, random_state=0,
                                               categorical_features=categorical_mask)
        stratify = target
        scoring = "roc_auc" if problem_type == "binary" else "accuracy"

    x_train, x_holdout, y_train, y_holdout = train_test_split(
        feature_matrix, target, test_size=0.25, random_state=0, stratify=stratify
    )

    train_started = time.perf_counter()
    model.fit(x_train, y_train)
    train_seconds = time.perf_counter() - train_started

    model_name = "HistGradientBoosting"
    if problem_type == "regression":
        metric_name, metric_value = "R²", float(r2_score(y_holdout, model.predict(x_holdout)))
    elif problem_type == "binary":
        metric_name, metric_value = "AUC", float(roc_auc_score(y_holdout, model.predict_proba(x_holdout)[:, 1]))
    else:
        metric_name, metric_value = "accuracy", float(accuracy_score(y_holdout, model.predict(x_holdout)))

    tabpfn_metric = _try_tabpfn_metric(problem_type, x_train, y_train, x_holdout, y_holdout)
    if tabpfn_metric is not None:
        metric_value, model_name = tabpfn_metric
        warnings.append("held-out metric from TabPFN v2; importances from gradient boosting")

    permutation = permutation_importance(model, x_holdout, y_holdout, scoring=scoring, n_repeats=6, random_state=0)
    raw_importances = np.clip(permutation.importances_mean, 0, None)
    total = raw_importances.sum()
    normalized = raw_importances / total if total > 0 else np.full(len(raw_importances), 1.0 / len(raw_importances))
    if total == 0:
        warnings.append("model found no predictive signal; importances are uniform")

    importances = sorted(
        (DriverImportance(column=name, importance=round(float(value), 4)) for name, value in zip(feature_names, normalized)),
        key=lambda item: -item.importance,
    )

    result = DriversResult(
        target_col=target_col,
        problem_type=problem_type,  # type: ignore[arg-type]
        importances=importances,
        metric_name=metric_name,
        metric_value=round(metric_value, 3),
        train_seconds=round(train_seconds, 3),
        n_rows_train=int(len(x_train)),
        n_rows_holdout=int(len(x_holdout)),
        model_name=model_name,
        dropped_columns=dropped_columns,
    )
    return result, warnings


def _try_tabpfn_metric(problem_type, x_train, y_train, x_holdout, y_holdout) -> tuple[float, str] | None:
    if os.environ.get("SOUNDER_USE_TABPFN") != "1" or len(x_train) > 10_000:
        return None
    try:
        from tabpfn import TabPFNClassifier, TabPFNRegressor  # type: ignore
    except Exception:
        return None
    try:
        x_train_filled = np.nan_to_num(x_train, nan=0.0)
        x_holdout_filled = np.nan_to_num(x_holdout, nan=0.0)
        if problem_type == "regression":
            regressor = TabPFNRegressor()
            regressor.fit(x_train_filled, y_train)
            return float(r2_score(y_holdout, regressor.predict(x_holdout_filled))), "TabPFN v2"
        classifier = TabPFNClassifier()
        classifier.fit(x_train_filled, y_train)
        if problem_type == "binary":
            return float(roc_auc_score(y_holdout, classifier.predict_proba(x_holdout_filled)[:, 1])), "TabPFN v2"
        return float(accuracy_score(y_holdout, classifier.predict(x_holdout_filled))), "TabPFN v2"
    except Exception:
        return None

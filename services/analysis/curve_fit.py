"""Fit a small family of curves to (x, y) columns and pick the best by AIC.

Returns curve points and an approximate 95% band in *data space*; the Swift
renderer maps them onto the user's chart using the axis calibration it read
from the tick labels.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
from scipy.optimize import curve_fit

from .schemas import FitResult

_CURVE_SAMPLE_COUNT = 100


@dataclass
class _CandidateFit:
    name: str
    equation_text: str
    predict: callable
    parameter_count: int
    residual_sum_of_squares: float

    def aic(self, sample_count: int) -> float:
        rss = max(self.residual_sum_of_squares, 1e-12)
        return sample_count * np.log(rss / sample_count) + 2 * self.parameter_count


def _format_coefficient(value: float) -> str:
    return f"{value:.3g}"


def _fit_polynomial(x: np.ndarray, y: np.ndarray, degree: int) -> _CandidateFit:
    coefficients = np.polyfit(x, y, degree)
    predict = lambda grid: np.polyval(coefficients, grid)
    rss = float(np.sum((y - predict(x)) ** 2))
    if degree == 1:
        equation = f"y = {_format_coefficient(coefficients[0])}·x + {_format_coefficient(coefficients[1])}"
        name = "linear"
    else:
        equation = (f"y = {_format_coefficient(coefficients[0])}·x² + "
                    f"{_format_coefficient(coefficients[1])}·x + {_format_coefficient(coefficients[2])}")
        name = "quadratic"
    return _CandidateFit(name, equation, predict, degree + 1, rss)


def _fit_exponential(x: np.ndarray, y: np.ndarray) -> _CandidateFit | None:
    if np.any(y <= 0):
        return None
    slope, intercept = np.polyfit(x, np.log(y), 1)
    predict = lambda grid: np.exp(intercept) * np.exp(slope * grid)
    rss = float(np.sum((y - predict(x)) ** 2))
    return _CandidateFit("exponential", f"y = {_format_coefficient(np.exp(intercept))}·e^({_format_coefficient(slope)}·x)",
                         predict, 2, rss)


def _fit_logarithmic(x: np.ndarray, y: np.ndarray) -> _CandidateFit | None:
    if np.any(x <= 0):
        return None
    slope, intercept = np.polyfit(np.log(x), y, 1)
    predict = lambda grid: intercept + slope * np.log(np.clip(grid, 1e-12, None))
    rss = float(np.sum((y - predict(x)) ** 2))
    return _CandidateFit("logarithmic", f"y = {_format_coefficient(slope)}·ln(x) + {_format_coefficient(intercept)}",
                         predict, 2, rss)


def _fit_logistic(x: np.ndarray, y: np.ndarray) -> _CandidateFit | None:
    if len(x) < 6:
        return None
    y_span = float(y.max() - y.min())
    if y_span <= 0:
        return None

    def logistic(grid, upper, growth, midpoint, lower):
        return lower + upper / (1.0 + np.exp(-growth * (grid - midpoint)))

    initial = [y_span, 4.0 / max(float(x.max() - x.min()), 1e-6), float(np.median(x)), float(y.min())]
    try:
        params, _ = curve_fit(logistic, x, y, p0=initial, maxfev=4000)
    except Exception:
        return None
    predict = lambda grid: logistic(grid, *params)
    rss = float(np.sum((y - predict(x)) ** 2))
    if not np.isfinite(rss):
        return None
    return _CandidateFit("logistic", f"y = {_format_coefficient(params[3])} + {_format_coefficient(params[0])} / "
                         f"(1 + e^(-{_format_coefficient(params[1])}·(x - {_format_coefficient(params[2])})))",
                         predict, 4, rss)


def fit_curve(frame: pd.DataFrame, x_col: str, y_col: str) -> tuple[FitResult, list[str]]:
    warnings: list[str] = []
    pair = frame[[x_col, y_col]].astype(float).dropna()
    if len(pair) < 4:
        raise ValueError("Need at least 4 numeric (x, y) pairs to fit a curve.")

    pair = pair.sort_values(x_col)
    x = pair[x_col].to_numpy()
    y = pair[y_col].to_numpy()
    if np.ptp(x) == 0:
        raise ValueError(f"'{x_col}' has no spread; cannot fit a curve against it.")

    candidates: list[_CandidateFit] = [_fit_polynomial(x, y, 1)]
    if len(x) >= 5:
        candidates.append(_fit_polynomial(x, y, 2))
    for maybe in (_fit_exponential(x, y), _fit_logarithmic(x, y), _fit_logistic(x, y)):
        if maybe is not None:
            candidates.append(maybe)

    best = min(candidates, key=lambda candidate: candidate.aic(len(x)))

    total_sum_of_squares = float(np.sum((y - y.mean()) ** 2))
    r_squared = 1.0 - best.residual_sum_of_squares / total_sum_of_squares if total_sum_of_squares > 0 else 0.0

    grid = np.linspace(float(x.min()), float(x.max()), _CURVE_SAMPLE_COUNT)
    predictions = np.asarray(best.predict(grid), dtype=float)

    # Approximate 95% prediction band: ±1.96 × residual standard error.
    # Ignores parameter uncertainty, which is fine for an on-screen overlay.
    degrees_of_freedom = max(len(x) - best.parameter_count, 1)
    residual_standard_error = float(np.sqrt(best.residual_sum_of_squares / degrees_of_freedom))
    half_width = 1.96 * residual_standard_error
    if half_width == 0:
        warnings.append("perfect fit; band collapsed to the curve")

    points = [[float(gx), float(gy)] for gx, gy in zip(grid, predictions)]
    band = [[float(gx), float(gy - half_width), float(gy + half_width)] for gx, gy in zip(grid, predictions)]

    result = FitResult(
        x_col=x_col,
        y_col=y_col,
        model_name=best.name,
        equation_text=best.equation_text,
        r_squared=round(float(r_squared), 4),
        points=points,
        band=band,
        x_range=[float(x.min()), float(x.max())],
        y_range=[float(min(y.min(), predictions.min() - half_width)), float(max(y.max(), predictions.max() + half_width))],
        n_points=int(len(x)),
    )
    return result, warnings

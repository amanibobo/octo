"""Deterministic summary sentences built only from computed numbers.

The voice layer may rephrase these, but every number it speaks comes from here,
so the LLM can never invent a statistic.
"""

from __future__ import annotations

from .schemas import AnomalyResult, DriversResult, FitResult


def _ordinal_words(count: int) -> str:
    return {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight"}.get(count, str(count))


def summarize_anomalies(result: AnomalyResult) -> str:
    if not result.rows:
        return "nothing stands out in this table."
    sentences = [f"{_ordinal_words(len(result.rows))} rows look unusual out of {result.n_rows_scored}."]
    for position, row in enumerate(result.rows[:3], start=1):
        sentences.append(f"number {position}: {row.spoken_reason}.")
    if len(result.rows) > 3:
        sentences.append("the rest are circled on screen.")
    return " ".join(sentences)


def summarize_drivers(result: DriversResult) -> str:
    top = result.importances[:3]
    if not top:
        return f"i could not find a driver for {result.target_col}."
    leaders = [item.column for item in top if item.importance >= 0.1]
    if not leaders:
        leaders = [top[0].column]
    explained_share = sum(item.importance for item in top) * 100
    if len(leaders) == 1:
        lead_text = f"{leaders[0]} explains most of it"
    else:
        lead_text = f"{', '.join(leaders[:-1])} and {leaders[-1]} explain most of it"
    weakest = result.importances[-1].column if len(result.importances) > len(leaders) else None
    weakest_text = f" {weakest} barely matters." if weakest and weakest not in leaders else ""
    metric_text = f"held-out {result.metric_name} {result.metric_value:.2f}"
    return (f"for {result.target_col}, {lead_text}, about {explained_share:.0f} percent of the signal.{weakest_text} "
            f"trained in {result.train_seconds:.1f} seconds on {result.n_rows_train} rows, {metric_text}.")


def summarize_fit(result: FitResult) -> str:
    return (f"a {result.model_name} curve fits {result.y_col} against {result.x_col} best, "
            f"r squared {result.r_squared:.2f} over {result.n_points} points. the shaded band is the approximate 95 percent range.")

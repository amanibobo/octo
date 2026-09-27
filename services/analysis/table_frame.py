"""Turn the raw string table from the screen into a typed pandas DataFrame."""

from __future__ import annotations

import re

import numpy as np
import pandas as pd

from .schemas import TablePayload

_NUMERIC_CLEANUP_PATTERN = re.compile(r"[,$€£%\s]")
_DATE_PATTERN = re.compile(r"^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}$")


def coerce_numeric_series(raw_values: pd.Series) -> pd.Series:
    """Parse strings like '$1,234.50', '12%', '(45)' into floats; unparseable → NaN."""

    def parse_one(raw_value):
        if raw_value is None:
            return np.nan
        text = str(raw_value).strip()
        if not text or text.lower() in {"nan", "none", "null", "-", "—", "n/a", "na"}:
            return np.nan
        is_negative_accounting = text.startswith("(") and text.endswith(")")
        cleaned = _NUMERIC_CLEANUP_PATTERN.sub("", text.strip("()"))
        try:
            parsed = float(cleaned)
        except ValueError:
            return np.nan
        return -parsed if is_negative_accounting else parsed

    return raw_values.map(parse_one).astype(float)


def infer_column_type(raw_values: pd.Series) -> str:
    non_empty = raw_values.dropna().map(lambda value: str(value).strip())
    non_empty = non_empty[non_empty != ""]
    if non_empty.empty:
        return "text"

    numeric_share = coerce_numeric_series(non_empty).notna().mean()
    if numeric_share >= 0.8:
        return "numeric"

    date_share = non_empty.map(lambda value: bool(_DATE_PATTERN.match(str(value)))).mean()
    if date_share >= 0.8:
        return "date"

    unique_count = non_empty.nunique()
    if unique_count <= max(12, int(0.05 * len(non_empty))):
        return "categorical"
    return "text"


def build_typed_frame(table: TablePayload) -> tuple[pd.DataFrame, dict[str, str]]:
    """Returns (DataFrame with numeric columns coerced to float, {column: type})."""

    column_count = len(table.headers)
    normalized_rows = []
    for row in table.rows:
        padded = list(row[:column_count]) + [None] * max(0, column_count - len(row))
        normalized_rows.append(padded)

    # De-duplicate header names so pandas indexing stays unambiguous.
    seen: dict[str, int] = {}
    unique_headers: list[str] = []
    for header in table.headers:
        base = (header or "").strip() or "column"
        if base in seen:
            seen[base] += 1
            unique_headers.append(f"{base}_{seen[base]}")
        else:
            seen[base] = 0
            unique_headers.append(base)

    frame = pd.DataFrame(normalized_rows, columns=unique_headers, dtype=object)

    column_types: dict[str, str] = {}
    for index, column in enumerate(frame.columns):
        provided_type = None
        if table.column_types and index < len(table.column_types):
            provided_type = table.column_types[index]
        inferred_type = infer_column_type(frame[column])
        # Trust the client's numeric/categorical hint only if the data agrees.
        column_type = provided_type if provided_type in {"date", "text"} else inferred_type
        column_types[column] = column_type
        if column_type == "numeric":
            frame[column] = coerce_numeric_series(frame[column])
        else:
            frame[column] = frame[column].map(
                lambda value: None if value is None or str(value).strip() == "" else str(value).strip()
            )

    return frame, column_types


def resolve_column_name(frame: pd.DataFrame, requested_name: str | None) -> str | None:
    """Case/space-insensitive match of a spoken or planned column name against real headers."""

    if not requested_name:
        return None

    def normalize(text: str) -> str:
        return re.sub(r"[^a-z0-9]", "", text.lower())

    wanted = normalize(requested_name)
    if not wanted:
        return None

    for column in frame.columns:
        if normalize(str(column)) == wanted:
            return str(column)
    for column in frame.columns:
        normalized_column = normalize(str(column))
        if wanted in normalized_column or normalized_column in wanted:
            return str(column)
    return None

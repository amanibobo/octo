"""/extract service: fine-tuned RF-DETR cell detector + PaddleOCR → ExtractedTable JSON.

Mirrors the Swift `ExtractedTable` contract (Sounder/Backend/SounderModels.swift) so
the app can switch from on-device OCR to this endpoint behind the confidence gate:

    POST /extract  multipart: image=<png|jpeg>   →
    {"headers": [...], "rows": [[...]], "column_types": [...],
     "header_cell_boxes": [[x,y,w,h]|null], "row_cell_boxes": [[[x,y,w,h]|null]],
     "extraction_confidence": 0.93, "source": "remote-rfdetr"}

Boxes are in the pixel space of the uploaded image. Requires the weights produced by
train.py (RFDETR_WEIGHTS env var) and `pip install rfdetr paddleocr`. Untested in
this repository so far — no GPU/weights were available when it was written.
"""

from __future__ import annotations

import io
import os
import time

import numpy as np
from fastapi import FastAPI, File, HTTPException, UploadFile
from PIL import Image

app = FastAPI(title="Sounder extractor service", version="0.1.0")

_detector = None
_ocr = None


def _load_models():
    global _detector, _ocr
    if _detector is None:
        from rfdetr import RFDETRBase  # type: ignore

        weights = os.environ.get("RFDETR_WEIGHTS", "extractor/runs/cells/checkpoint_best_total.pth")
        _detector = RFDETRBase(pretrain_weights=weights)
    if _ocr is None:
        from paddleocr import PaddleOCR  # type: ignore

        _ocr = PaddleOCR(use_angle_cls=False, lang="en", show_log=False)
    return _detector, _ocr


@app.get("/health")
def health() -> dict:
    return {"ok": True, "service": "sounder-extractor"}


@app.post("/extract")
async def extract(image: UploadFile = File(...)) -> dict:
    started = time.perf_counter()
    detector, ocr = _load_models()
    pil_image = Image.open(io.BytesIO(await image.read())).convert("RGB")

    detections = detector.predict(pil_image, threshold=0.4)
    boxes = np.asarray(detections.xyxy)
    class_ids = np.asarray(detections.class_id)
    if len(boxes) == 0:
        raise HTTPException(status_code=422, detail="no cells detected")

    # Recognise text per cell crop (batched by PaddleOCR internally).
    texts: list[str] = []
    confidences: list[float] = []
    image_array = np.asarray(pil_image)
    for x0, y0, x1, y1 in boxes.astype(int):
        crop = image_array[max(0, y0 - 2):y1 + 2, max(0, x0 - 2):x1 + 2]
        result = ocr.ocr(crop, cls=False)
        if result and result[0]:
            texts.append(" ".join(line[1][0] for line in result[0]))
            confidences.append(float(np.mean([line[1][1] for line in result[0]])))
        else:
            texts.append("")
            confidences.append(0.0)

    # Grid assembly: rows by y-centre, columns by x-centre (same idea as the Swift extractor).
    centers_y = (boxes[:, 1] + boxes[:, 3]) / 2
    centers_x = (boxes[:, 0] + boxes[:, 2]) / 2
    heights = boxes[:, 3] - boxes[:, 1]
    row_tolerance = float(np.median(heights)) * 0.5
    row_ids = _cluster_1d(centers_y, row_tolerance)
    column_ids = _cluster_1d(centers_x, float(np.median(boxes[:, 2] - boxes[:, 0])) * 0.5)

    row_count = row_ids.max() + 1
    column_count = column_ids.max() + 1
    grid_text = [["" for _ in range(column_count)] for _ in range(row_count)]
    grid_box = [[None for _ in range(column_count)] for _ in range(row_count)]
    header_row_index = None
    for index, (row, column) in enumerate(zip(row_ids, column_ids)):
        grid_text[row][column] = texts[index]
        x0, y0, x1, y1 = boxes[index].tolist()
        grid_box[row][column] = [x0, y0, x1 - x0, y1 - y0]
        if class_ids[index] == 2:  # header_cell
            header_row_index = row if header_row_index is None else min(header_row_index, row)

    if header_row_index is None:
        header_row_index = 0
    headers = [text or f"Column {i + 1}" for i, text in enumerate(grid_text[header_row_index])]
    body_rows = [row for i, row in enumerate(grid_text) if i != header_row_index]
    body_boxes = [row for i, row in enumerate(grid_box) if i != header_row_index]

    from analysis.table_frame import infer_column_type  # reuse typing rules
    import pandas as pd

    column_types = [infer_column_type(pd.Series([row[c] for row in body_rows])) for c in range(column_count)]
    filled = sum(1 for row in body_rows for cell in row if cell)
    confidence = 0.55 * filled / max(1, len(body_rows) * column_count) + 0.45 * float(np.mean(confidences))

    return {
        "headers": headers,
        "rows": body_rows,
        "column_types": column_types,
        "header_cell_boxes": grid_box[header_row_index],
        "row_cell_boxes": body_boxes,
        "extraction_confidence": round(confidence, 3),
        "source": "remote-rfdetr",
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }


def _cluster_1d(values: np.ndarray, tolerance: float) -> np.ndarray:
    order = np.argsort(values)
    cluster_ids = np.zeros(len(values), dtype=int)
    current_id = 0
    for position, index in enumerate(order):
        if position > 0 and values[index] - values[order[position - 1]] > tolerance:
            current_id += 1
        cluster_ids[index] = current_id
    return cluster_ids

"""Synthetic training data for the screenshot→table extractor (RF-DETR fine-tune).

Renders randomized spreadsheet-like HTML grids with Playwright and records the
ground-truth box of every cell from getBoundingClientRect(). Randomization
covers font family/size, zoom, gridlines, alternating shading, frozen header,
selection highlight, dark mode and Sheets/Excel-style chrome, matching PRD §6.3.

    pip install playwright faker && playwright install chromium
    python synth/generate_synthetic_tables.py --count 200 --out synth/output

Output: <out>/images/NNNNN.png and <out>/annotations.json (COCO format with
categories cell / header_cell / chart_region / selected_cell).
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

FONTS = ["Arial", "Calibri", "Roboto", "Inter", "Helvetica", "Segoe UI", "Verdana"]
COLUMN_KINDS = ["id", "name", "category", "integer", "money", "percent", "date", "yesno"]
CATEGORIES = {"cell": 1, "header_cell": 2, "chart_region": 3, "selected_cell": 4}


def random_cell(kind: str, rng: random.Random, row_index: int) -> str:
    if kind == "id":
        return f"{rng.randint(1000, 9999)}-{''.join(rng.choices('ABCDEFGHJKLMNPQRSTUVWXYZ', k=5))}"
    if kind == "name":
        return rng.choice(["Ava Chen", "Liam Patel", "Noah Kim", "Mia Lopez", "Zoe Adams", "Eli Park", "Ivy Nguyen", "Max Rossi"])
    if kind == "category":
        return rng.choice(["Month-to-month", "One year", "Two year", "Fiber optic", "DSL", "No", "Premium", "Basic"])
    if kind == "integer":
        return str(rng.randint(0, 5000))
    if kind == "money":
        return f"{rng.uniform(5, 4000):,.2f}" if rng.random() < 0.7 else f"${rng.uniform(5, 4000):,.2f}"
    if kind == "percent":
        return f"{rng.uniform(0, 100):.1f}%"
    if kind == "date":
        return f"{rng.randint(2019, 2026)}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}"
    return rng.choice(["Yes", "No"])


def build_html(rng: random.Random) -> tuple[str, dict]:
    column_count = rng.randint(3, 10)
    row_count = rng.randint(8, 40)
    kinds = [rng.choice(COLUMN_KINDS) for _ in range(column_count)]
    headers = [rng.choice(["customerID", "tenure", "Contract", "MonthlyCharges", "TotalCharges", "Churn", "Region", "Segment",
                           "Revenue", "Units", "Discount", "Signup Date", "Plan", "Status", "Score", "Owner"]) for _ in range(column_count)]
    font = rng.choice(FONTS)
    font_size = rng.randint(9, 14)
    zoom = rng.choice([0.8, 0.9, 1.0, 1.1, 1.25, 1.5])
    dark = rng.random() < 0.15
    gridlines = rng.random() < 0.8
    alternate = rng.random() < 0.4
    chrome = rng.choice(["sheets", "excel", "none"])
    selected = (rng.randint(0, row_count - 1), rng.randint(0, column_count - 1)) if rng.random() < 0.5 else None

    background = "#1e1e1e" if dark else "#ffffff"
    foreground = "#e8e8e8" if dark else "#111111"
    grid_color = "#3a3a3a" if dark else "#dadce0"
    header_background = "#2a2a2a" if dark else "#f8f9fa"

    rows_html = []
    for row_index in range(row_count):
        cells = []
        for column_index, kind in enumerate(kinds):
            value = random_cell(kind, rng, row_index)
            align = "right" if kind in {"integer", "money", "percent"} else "left"
            classes = "cell"
            if selected == (row_index, column_index):
                classes += " selected"
            cells.append(f'<td class="{classes}" style="text-align:{align}">{value}</td>')
        shade = ' class="alt"' if alternate and row_index % 2 else ""
        rows_html.append(f"<tr{shade}><td class='gutter'>{row_index + 2}</td>{''.join(cells)}</tr>")

    letters = "".join(f"<td class='letter'>{chr(65 + i)}</td>" for i in range(column_count))
    header_cells = "".join(f'<td class="header">{h}</td>' for h in headers)

    chrome_html = ""
    if chrome == "sheets":
        chrome_html = "<div class='chrome'>File Edit View Insert Format Data Tools Extensions Help</div><div class='formula'>fx</div>"
    elif chrome == "excel":
        chrome_html = "<div class='chrome'>Home Insert Draw Page Layout Formulas Data Review View</div>"

    html = f"""<!doctype html><html><head><meta charset='utf-8'><style>
    body {{ margin:0; background:{background}; color:{foreground}; font-family:'{font}', sans-serif; font-size:{font_size}px; zoom:{zoom}; }}
    .chrome {{ padding:8px 12px; color:{foreground}; opacity:0.85; }}
    .formula {{ padding:4px 12px; border-bottom:1px solid {grid_color}; }}
    table {{ border-collapse:collapse; margin:6px 0 0 0; }}
    td {{ padding:3px 6px; white-space:nowrap; {"border:1px solid " + grid_color + ";" if gridlines else ""} height:{font_size + 6}px; }}
    td.gutter, td.letter {{ background:{header_background}; color:#777; text-align:center; min-width:28px; }}
    td.header {{ font-weight:600; background:{header_background}; }}
    tr.alt td.cell {{ background:{"#242424" if dark else "#f3f6fb"}; }}
    td.selected {{ outline:2px solid #1a73e8; }}
    </style></head><body>{chrome_html}
    <table id='grid'><tr><td class='letter'></td>{letters}</tr><tr><td class='gutter'>1</td>{header_cells}</tr>{''.join(rows_html)}</table>
    </body></html>"""
    meta = {"font": font, "font_size": font_size, "zoom": zoom, "dark": dark, "gridlines": gridlines, "chrome": chrome,
            "rows": row_count, "columns": column_count, "headers": headers}
    return html, meta


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--out", type=Path, default=Path("synth/output"))
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--width", type=int, default=1600)
    parser.add_argument("--height", type=int, default=1000)
    args = parser.parse_args()

    from playwright.sync_api import sync_playwright  # imported lazily so --help works without it

    rng = random.Random(args.seed)
    images_dir = args.out / "images"
    images_dir.mkdir(parents=True, exist_ok=True)

    coco = {"images": [], "annotations": [], "categories": [{"id": cid, "name": name} for name, cid in CATEGORIES.items()]}
    annotation_id = 1

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page(viewport={"width": args.width, "height": args.height}, device_scale_factor=rng.choice([1, 2]))
        for image_index in range(args.count):
            html, meta = build_html(rng)
            page.set_content(html)
            boxes = page.evaluate("""() => Array.from(document.querySelectorAll('td')).map(td => {
                const r = td.getBoundingClientRect();
                return {cls: td.className, x: r.x, y: r.y, w: r.width, h: r.height, text: td.textContent};
            })""")
            scale = page.evaluate("window.devicePixelRatio")
            file_name = f"{image_index:05d}.png"
            page.screenshot(path=str(images_dir / file_name))
            coco["images"].append({"id": image_index, "file_name": file_name, "width": int(args.width * scale),
                                   "height": int(args.height * scale), "meta": meta})
            for box in boxes:
                classes = box["cls"].split()
                if "gutter" in classes or "letter" in classes:
                    continue
                if "header" in classes:
                    category = CATEGORIES["header_cell"]
                elif "selected" in classes:
                    category = CATEGORIES["selected_cell"]
                else:
                    category = CATEGORIES["cell"]
                bbox = [box["x"] * scale, box["y"] * scale, box["w"] * scale, box["h"] * scale]
                if bbox[0] + bbox[2] > args.width * scale or bbox[1] + bbox[3] > args.height * scale:
                    continue  # scrolled out of the viewport
                coco["annotations"].append({"id": annotation_id, "image_id": image_index, "category_id": category,
                                            "bbox": bbox, "area": bbox[2] * bbox[3], "iscrowd": 0, "text": box["text"]})
                annotation_id += 1
            if image_index % 25 == 0:
                print(f"rendered {image_index + 1}/{args.count}")
        browser.close()

    (args.out / "annotations.json").write_text(json.dumps(coco))
    print(f"wrote {len(coco['images'])} images and {len(coco['annotations'])} boxes to {args.out}")


if __name__ == "__main__":
    main()

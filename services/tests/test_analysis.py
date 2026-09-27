import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402

from analysis.app import app  # noqa: E402
from tests.make_sample_table import HEADERS, make_rows  # noqa: E402

client = TestClient(app)


def _table(row_count: int = 400) -> dict:
    return {"headers": HEADERS, "rows": make_rows(row_count)}


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["ok"] is True


def test_anomaly_finds_planted_rows():
    response = client.post("/analyze", json={"task": "anomaly", "table": _table(), "k": 6})
    assert response.status_code == 200, response.text
    payload = response.json()
    flagged = {row["row_index"] for row in payload["anomaly"]["rows"]}
    planted = {(index * 37) % 400 for index in range(4)}
    assert len(flagged & planted) >= 3, (flagged, planted)
    top = payload["anomaly"]["rows"][0]
    assert top["reasons"], "flagged rows must carry spoken reasons"
    assert "MonthlyCharges" in top["spoken_reason"]
    assert payload["summary_text"]


def test_drivers_ranks_contract_and_tenure_high():
    response = client.post("/analyze", json={"task": "drivers", "table": _table(1200), "target_col": "churn"})
    assert response.status_code == 200, response.text
    drivers = response.json()["drivers"]
    assert drivers["target_col"] == "Churn"
    assert drivers["problem_type"] == "binary"
    assert drivers["metric_name"] == "AUC"
    assert drivers["metric_value"] > 0.7
    ranking = [item["column"] for item in drivers["importances"]]
    assert set(ranking[:2]) <= {"Contract", "tenure", "TotalCharges"}, ranking
    assert "customerID" in drivers["dropped_columns"]
    assert drivers["train_seconds"] < 10


def test_fit_recovers_linear_relationship():
    headers = ["x", "y"]
    rows = [[str(x), str(3 * x + 2 + (0.1 if x % 2 else -0.1))] for x in range(1, 30)]
    response = client.post("/analyze", json={"task": "fit", "table": {"headers": headers, "rows": rows}, "x_col": "x", "y_col": "y"})
    assert response.status_code == 200, response.text
    fit = response.json()["fit"]
    assert fit["model_name"] == "linear"
    assert fit["r_squared"] > 0.99
    assert len(fit["points"]) == 100
    assert len(fit["band"]) == 100


def test_missing_target_is_a_422():
    response = client.post("/analyze", json={"task": "drivers", "table": _table(100), "target_col": "nonexistent"})
    assert response.status_code == 422

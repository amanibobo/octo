import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402

from analysis.app import app  # noqa: E402
from clinical.evidence import find_evidence  # noqa: E402
from clinical.rules import egfr_ckd_epi_2021  # noqa: E402

client = TestClient(app)

DEMO_CHART = {
    "medications": [
        {"id": "m1", "rxcui": "11289", "name": "warfarin", "dose_mg": 5, "doses_per_day": 1},
        {"id": "m2", "rxcui": "4450", "name": "fluconazole", "dose_mg": 200, "doses_per_day": 1},
        {"id": "m3", "rxcui": "6809", "name": "metformin", "dose_mg": 1000, "doses_per_day": 2},
        {"id": "m4", "rxcui": "29046", "name": "lisinopril", "dose_mg": 10, "doses_per_day": 1},
        {"id": "m5", "rxcui": "4603", "name": "furosemide", "dose_mg": 40, "doses_per_day": 1},
        {"id": "m6", "rxcui": "83367", "name": "atorvastatin", "dose_mg": 40, "doses_per_day": 1},
    ],
    "labs": {"egfr": 38, "creatinine_mg_dl": 1.9, "inr": 2.4, "potassium": 4.6},
    "patient": {"age_years": 71, "sex": "male"},
    "conditions": [{"id": "c1", "code": "I50.32", "name": "hfpef"}],
}


def test_egfr_matches_chart():
    assert abs(egfr_ckd_epi_2021(1.9, 71, "male") - 38) < 3


def test_demo_chart_findings():
    response = client.post("/clinical/check", json=DEMO_CHART)
    assert response.status_code == 200, response.text
    payload = response.json()
    by_key = {(f["type"], tuple(f["medication_ids"])): f for f in payload["findings"]}
    ddi = by_key[("DDI", ("m1", "m2"))]
    assert ddi["severity"] == "major" and "INR" in ddi["message"]
    renal = by_key[("RENAL", ("m3",))]
    assert renal["severity"] == "major" and "1000" in renal["message"]
    assert ("DDI", ("m2", "m6")) in by_key  # fluconazole + atorvastatin moderate
    assert payload["findings"][0]["severity"] == "major"
    assert payload["interactions_checked"] == 15
    assert "warfarin plus fluconazole" in payload["summary_text"]


def test_egfr_computed_when_missing():
    request = {**DEMO_CHART, "labs": {"creatinine_mg_dl": 1.9}}
    payload = client.post("/clinical/check", json=request).json()
    assert payload["egfr_source"] == "ckd-epi-2021"
    assert 34 < payload["egfr_used"] < 41


def test_clean_list_has_no_findings():
    request = {"medications": [{"id": "a", "name": "amlodipine", "dose_mg": 5, "doses_per_day": 1},
                               {"id": "b", "name": "atorvastatin", "dose_mg": 20, "doses_per_day": 1}],
               "labs": {"egfr": 90}, "patient": {"age_years": 50, "sex": "female"}}
    payload = client.post("/clinical/check", json=request).json()
    assert payload["findings"] == []
    assert "nothing to flag" in payload["summary_text"]


def test_evidence_cache_and_sponsored_slot():
    response = find_evidence("heart failure with preserved ejection fraction", allow_network=False)
    assert response.condition == "hfpef"
    assert response.source == "cache"
    assert any(item.kind == "sponsored" and item.disclosure for item in response.items)
    assert "FINEARTS" in response.spoken_summary
    api = client.post("/clinical/evidence", json={"condition": "HFpEF"})
    assert api.status_code == 200 and api.json()["items"]

"""Drug-drug interaction, label dosing, renal and age checks on normalized concepts."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from .schemas import ClinicalCheckRequest, ClinicalCheckResponse, ClinicalFinding

_DATA_DIR = Path(__file__).resolve().parent / "data"


@lru_cache(maxsize=1)
def _interaction_index() -> dict[frozenset[str], dict]:
    payload = json.loads((_DATA_DIR / "interactions.json").read_text())
    return {frozenset((pair["a"], pair["b"])): pair for pair in payload["pairs"]}


@lru_cache(maxsize=1)
def _dosing_rules() -> dict[str, dict]:
    return json.loads((_DATA_DIR / "dosing_rules.json").read_text())["drugs"]


def normalize_drug_name(name: str | None) -> str | None:
    if not name:
        return None
    return " ".join(name.lower().replace("-", " ").split())


def egfr_ckd_epi_2021(creatinine_mg_dl: float, age_years: int, sex: str) -> float:
    """Race-free CKD-EPI 2021 creatinine equation."""
    is_female = sex == "female"
    kappa = 0.7 if is_female else 0.9
    alpha = -0.241 if is_female else -0.302
    ratio = creatinine_mg_dl / kappa
    value = 142 * (min(ratio, 1.0) ** alpha) * (max(ratio, 1.0) ** -1.200) * (0.9938 ** age_years)
    if is_female:
        value *= 1.012
    return round(value, 1)


def _spoken_dose(dose_mg: float | None, doses_per_day: float | None) -> str:
    if dose_mg is None:
        return ""
    dose_text = f"{dose_mg:g} milligrams"
    if doses_per_day == 2:
        return f"{dose_text} twice daily"
    if doses_per_day == 3:
        return f"{dose_text} three times daily"
    if doses_per_day == 4:
        return f"{dose_text} four times daily"
    if doses_per_day == 1:
        return f"{dose_text} daily"
    return dose_text


def check_medications(request: ClinicalCheckRequest) -> ClinicalCheckResponse:
    findings: list[ClinicalFinding] = []
    medications = [(med, normalize_drug_name(med.name)) for med in request.medications]
    recognized = [(med, name) for med, name in medications if name]

    # eGFR: prefer a reported value, otherwise compute from creatinine + age + sex.
    egfr_used = request.labs.egfr
    egfr_source = "reported" if egfr_used is not None else None
    if egfr_used is None and request.labs.creatinine_mg_dl and request.patient.age_years and request.patient.sex:
        egfr_used = egfr_ckd_epi_2021(request.labs.creatinine_mg_dl, request.patient.age_years, request.patient.sex)
        egfr_source = "ckd-epi-2021"

    # Interactions: every pair.
    interactions = _interaction_index()
    interactions_checked = 0
    for index, (med_a, name_a) in enumerate(recognized):
        for med_b, name_b in recognized[index + 1:]:
            interactions_checked += 1
            pair = interactions.get(frozenset((name_a, name_b)))
            if not pair:
                continue
            findings.append(ClinicalFinding(
                type="DDI",
                medication_ids=[med_a.id, med_b.id],
                severity=pair["severity"],
                message=f"{name_a} plus {name_b} is a {pair['severity']} interaction: {pair['mechanism']}.",
                advice=pair.get("advice"),
                reference="interaction seed set (DDInter-style, FDA label interaction sections)",
            ))

    # Dosing, renal and age rules per drug.
    dosing_rules = _dosing_rules()
    for med, name in recognized:
        rules = dosing_rules.get(name)
        if not rules:
            continue
        total_daily = (med.dose_mg or 0) * (med.doses_per_day or 1) if med.dose_mg else None
        spoken = _spoken_dose(med.dose_mg, med.doses_per_day)

        if total_daily and rules.get("max_daily_mg") and total_daily > rules["max_daily_mg"]:
            ratio = total_daily / rules["max_daily_mg"]
            findings.append(ClinicalFinding(
                type="DOSE", medication_ids=[med.id], severity="major" if ratio >= 1.5 else "moderate",
                message=f"{name} {spoken} totals {total_daily:g} milligrams a day, above the label maximum of {rules['max_daily_mg']:g}.",
                advice="confirm the intended dose", reference="FDA prescribing information",
            ))

        if egfr_used is not None:
            applicable = [rule for rule in rules.get("renal", []) if egfr_used < rule["egfr_below"]]
            if applicable:
                rule = min(applicable, key=lambda item: item["egfr_below"])  # most restrictive threshold
                if rule["action"] == "contraindicated":
                    findings.append(ClinicalFinding(
                        type="RENAL", medication_ids=[med.id], severity="major",
                        message=f"{name} is contraindicated at an eGFR of {egfr_used:g}: {rule['note']}.",
                        advice="stop or replace", reference="FDA prescribing information (renal)",
                    ))
                elif rule["action"] == "max_daily_mg":
                    if total_daily and total_daily > rule["value"]:
                        findings.append(ClinicalFinding(
                            type="RENAL", medication_ids=[med.id], severity="major",
                            message=f"{name} {spoken} is above the renal maximum of {rule['value']:g} milligrams a day for an eGFR of {egfr_used:g}: {rule['note']}.",
                            advice="reduce the dose", reference="FDA prescribing information (renal)",
                        ))
                elif rule["action"] in {"halve", "note"}:
                    findings.append(ClinicalFinding(
                        type="RENAL", medication_ids=[med.id], severity="moderate",
                        message=f"{name} needs renal adjustment at an eGFR of {egfr_used:g}: {rule['note']}.",
                        advice="adjust the dose", reference="FDA prescribing information (renal)",
                    ))

        if request.patient.age_years and total_daily:
            for rule in rules.get("age", []):
                if request.patient.age_years > rule["age_over"] and total_daily > rule["max_daily_mg"]:
                    findings.append(ClinicalFinding(
                        type="AGE", medication_ids=[med.id], severity="moderate",
                        message=f"{name} {spoken} is above the maximum for age {request.patient.age_years}: {rule['note']}.",
                        advice="reduce the dose", reference="FDA prescribing information",
                    ))

    severity_rank = {"major": 0, "moderate": 1, "minor": 2}
    findings.sort(key=lambda finding: severity_rank[finding.severity])

    return ClinicalCheckResponse(
        findings=findings,
        egfr_used=egfr_used,
        egfr_source=egfr_source,
        interactions_checked=interactions_checked,
        medications_recognized=len(recognized),
        summary_text=_summarize(findings, len(recognized)),
    )


def _summarize(findings: list[ClinicalFinding], recognized_count: int) -> str:
    if recognized_count == 0:
        return "i could not match any medication on this screen to a drug concept."
    if not findings:
        return f"i checked {recognized_count} medications against each other and the labs and found nothing to flag."
    major = [finding for finding in findings if finding.severity == "major"]
    others = [finding for finding in findings if finding.severity != "major"]
    parts = []
    count_word = {1: "one thing", 2: "two things", 3: "three things", 4: "four things"}.get(len(findings), f"{len(findings)} things")
    parts.append(f"{count_word} to flag.")
    for finding in major[:3]:
        sentence = finding.message
        if finding.advice:
            sentence = sentence.rstrip(".") + f"; {finding.advice}."
        parts.append(sentence)
    if others:
        parts.append(f"{'one' if len(others) == 1 else str(len(others))} moderate {'note' if len(others) == 1 else 'notes'} {'is' if len(others) == 1 else 'are'} marked on screen with footnotes.")
    return " ".join(parts)

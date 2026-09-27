"""Contract for /clinical/check and /clinical/evidence. Concepts only, no chart text."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class MedicationConcept(BaseModel):
    id: str
    rxcui: str | None = None
    name: str | None = None  # generic name from the on-device lexicon (a drug name, not PHI)
    dose_mg: float | None = None
    doses_per_day: float | None = None


class LabValues(BaseModel):
    egfr: float | None = None
    creatinine_mg_dl: float | None = None
    inr: float | None = None
    potassium: float | None = None
    hba1c: float | None = None


class PatientContext(BaseModel):
    age_years: int | None = None
    sex: Literal["male", "female"] | None = None


class ConditionConcept(BaseModel):
    id: str
    code: str | None = None
    name: str


class ClinicalCheckRequest(BaseModel):
    medications: list[MedicationConcept]
    labs: LabValues = Field(default_factory=LabValues)
    patient: PatientContext = Field(default_factory=PatientContext)
    conditions: list[ConditionConcept] = Field(default_factory=list)


class ClinicalFinding(BaseModel):
    type: Literal["DDI", "DOSE", "RENAL", "AGE"]
    medication_ids: list[str]
    severity: Literal["major", "moderate", "minor"]
    message: str
    advice: str | None = None
    reference: str


class ClinicalCheckResponse(BaseModel):
    findings: list[ClinicalFinding]
    egfr_used: float | None
    egfr_source: str | None
    interactions_checked: int
    medications_recognized: int
    summary_text: str


class EvidenceRequest(BaseModel):
    condition: str
    drug: str | None = None


class EvidenceItem(BaseModel):
    kind: Literal["trial", "sponsored"]
    title: str
    source: str
    id: str
    url: str
    summary: str
    disclosure: bool = False


class EvidenceResponse(BaseModel):
    condition: str
    items: list[EvidenceItem]
    spoken_summary: str
    source: Literal["pubmed", "cache", "none"]

"""Recent evidence for a condition: live PubMed when reachable, seeded cache otherwise,
plus the disclosed sponsored slot that is the Impiricus channel demo."""

from __future__ import annotations

import json
import re
import urllib.parse
import urllib.request
from functools import lru_cache
from pathlib import Path

from .schemas import EvidenceItem, EvidenceResponse

_DATA_DIR = Path(__file__).resolve().parent / "data"
_CONDITION_ALIASES = {
    "hfpef": "hfpef", "heart failure with preserved ejection fraction": "hfpef",
    "atrial fibrillation": "atrial fibrillation", "afib": "atrial fibrillation", "af": "atrial fibrillation", "a fib": "atrial fibrillation",
    "type 2 diabetes": "type 2 diabetes", "type 2 diabetes mellitus": "type 2 diabetes", "t2d": "type 2 diabetes", "t2dm": "type 2 diabetes", "diabetes": "type 2 diabetes",
    "chronic kidney disease": "chronic kidney disease", "ckd": "chronic kidney disease", "kidney disease": "chronic kidney disease",
    "hypertension": "hypertension", "htn": "hypertension", "essential hypertension": "hypertension",
}
_PUBMED_QUERY_TERMS = {
    "hfpef": "heart failure with preserved ejection fraction",
    "atrial fibrillation": "atrial fibrillation",
    "type 2 diabetes": "type 2 diabetes",
    "chronic kidney disease": "chronic kidney disease",
    "hypertension": "hypertension",
}
_live_cache: dict[str, list[EvidenceItem]] = {}


@lru_cache(maxsize=1)
def _seed() -> dict:
    return json.loads((_DATA_DIR / "evidence_cache.json").read_text())


def canonical_condition(condition: str) -> str:
    key = " ".join(re.sub(r"[^a-z0-9 ]", " ", condition.lower()).split())
    return _CONDITION_ALIASES.get(key, key)


def _fetch_pubmed(condition_key: str, drug: str | None, timeout: float = 4.0) -> list[EvidenceItem]:
    term = _PUBMED_QUERY_TERMS.get(condition_key, condition_key)
    query = f"{term}[tiab] AND (randomized controlled trial[pt] OR meta-analysis[pt])"
    if drug:
        query += f" AND {drug}[tiab]"
    search_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?" + urllib.parse.urlencode(
        {"db": "pubmed", "term": query, "sort": "date", "retmax": 3, "retmode": "json"})
    with urllib.request.urlopen(search_url, timeout=timeout) as response:
        ids = json.load(response).get("esearchresult", {}).get("idlist", [])
    if not ids:
        return []
    summary_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?" + urllib.parse.urlencode(
        {"db": "pubmed", "id": ",".join(ids), "retmode": "json"})
    with urllib.request.urlopen(summary_url, timeout=timeout) as response:
        result = json.load(response).get("result", {})
    items = []
    for pmid in ids:
        record = result.get(pmid)
        if not record:
            continue
        year = (record.get("pubdate") or "")[:4]
        items.append(EvidenceItem(
            kind="trial", title=record.get("title", "").rstrip("."), source=f"{record.get('source', 'PubMed')} {year}".strip(),
            id=f"PMID {pmid}", url=f"https://pubmed.ncbi.nlm.nih.gov/{pmid}/",
            summary=f"{record.get('title', '').rstrip('.')} ({record.get('source', 'PubMed')}, {year})",
        ))
    return items


def find_evidence(condition: str, drug: str | None = None, allow_network: bool = True) -> EvidenceResponse:
    condition_key = canonical_condition(condition)
    items: list[EvidenceItem] = []
    source = "none"

    if allow_network:
        if condition_key in _live_cache:
            items, source = list(_live_cache[condition_key]), "pubmed"
        else:
            try:
                items = _fetch_pubmed(condition_key, drug)
                if items:
                    _live_cache[condition_key] = list(items)
                    source = "pubmed"
            except Exception:
                items = []

    if not items:
        seeded = _seed()["conditions"].get(condition_key, [])
        items = [EvidenceItem(**entry) for entry in seeded]
        source = "cache" if items else "none"

    for slot in _seed().get("sponsored_slots", []):
        if slot["condition"] == condition_key:
            items.append(EvidenceItem(kind="sponsored", title=slot["title"], source=slot["sponsor"], id="sponsored",
                                      url="", summary=slot["text"], disclosure=bool(slot.get("disclosure", True))))

    trials = [item for item in items if item.kind == "trial"]
    if not trials:
        spoken = f"i don't have recent trials cached for {condition_key}."
    else:
        lead = trials[0]
        spoken = f"the newest trial for {condition_key} is {lead.title.split(':')[0]}, {lead.source}: {lead.summary.split('(')[0].strip()}."
        if len(trials) > 1:
            spoken += f" {len(trials) - 1} more {'is' if len(trials) == 2 else 'are'} in the footnotes."
    if any(item.kind == "sponsored" for item in items):
        spoken += " there is also one sponsored medical information item, labeled as such."

    return EvidenceResponse(condition=condition_key, items=items, spoken_summary=spoken, source=source)

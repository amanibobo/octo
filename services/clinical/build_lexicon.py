"""Build the on-device drug lexicon: RxNorm display names for detection, plus
RXCUIs resolved through RxNav for a curated list of common generics.

    python clinical/build_lexicon.py --displaynames /path/displaynames.json --out clinical/data/drug_lexicon.json

Output: {"generated": "...", "names": {"warfarin": "11289", "coumadin": "202421", "abacavir": null, ...}}
Names with null RXCUI are detected on screen but sent as names to RxNav only if
the app is allowed to (they are drug names, not PHI). Detection-only names are
filtered to plain alphabetic terms to keep chemical formulas and salts out.
"""

from __future__ import annotations

import argparse
import json
import re
import time
import urllib.parse
import urllib.request
from datetime import date

COMMON_GENERICS = """
warfarin fluconazole metformin lisinopril furosemide atorvastatin simvastatin rosuvastatin pravastatin amlodipine
metoprolol carvedilol bisoprolol atenolol propranolol losartan valsartan irbesartan olmesartan hydrochlorothiazide
chlorthalidone spironolactone eplerenone digoxin amiodarone dronedarone diltiazem verapamil clopidogrel ticagrelor
prasugrel aspirin apixaban rivaroxaban dabigatran edoxaban enoxaparin heparin insulin glipizide glimepiride
glyburide pioglitazone sitagliptin linagliptin empagliflozin dapagliflozin canagliflozin semaglutide liraglutide
dulaglutide tirzepatide levothyroxine liothyronine methimazole omeprazole pantoprazole esomeprazole lansoprazole
famotidine ondansetron metoclopramide promethazine prochlorperazine sertraline fluoxetine citalopram escitalopram
paroxetine venlafaxine duloxetine bupropion mirtazapine trazodone amitriptyline nortriptyline lithium quetiapine
olanzapine risperidone aripiprazole haloperidol clozapine lorazepam alprazolam clonazepam diazepam zolpidem
gabapentin pregabalin carbamazepine phenytoin levetiracetam lamotrigine valproate topiramate oxcarbazepine
tramadol oxycodone hydrocodone morphine hydromorphone fentanyl codeine acetaminophen ibuprofen naproxen diclofenac
meloxicam celecoxib ketorolac indomethacin prednisone prednisolone methylprednisolone dexamethasone hydrocortisone
methotrexate azathioprine mycophenolate tacrolimus cyclosporine hydroxychloroquine sulfasalazine leflunomide
adalimumab etanercept infliximab allopurinol febuxostat colchicine amoxicillin ampicillin penicillin cephalexin
cefuroxime ceftriaxone cefdinir azithromycin clarithromycin erythromycin doxycycline minocycline ciprofloxacin
levofloxacin moxifloxacin metronidazole clindamycin vancomycin linezolid nitrofurantoin trimethoprim
sulfamethoxazole rifampin isoniazid itraconazole ketoconazole voriconazole terbinafine acyclovir valacyclovir
oseltamivir albuterol salmeterol formoterol tiotropium ipratropium budesonide fluticasone montelukast theophylline
prednisone cetirizine loratadine fexofenadine diphenhydramine hydroxyzine tamsulosin finasteride oxybutynin
sildenafil tadalafil alendronate risedronate denosumab calcitriol cholecalciferol ferrous sulfate folic acid
cyanocobalamin potassium chloride magnesium oxide sodium bicarbonate sevelamer epoetin alfa filgrastim tamoxifen
letrozole anastrozole isosorbide mononitrate isosorbide dinitrate nitroglycerin hydralazine clonidine doxazosin
ranolazine ivabradine sacubitril entresto finerenone vericiguat midodrine fludrocortisone melatonin baclofen
tizanidine cyclobenzaprine methocarbamol donepezil memantine rivastigmine carbidopa levodopa ropinirole
pramipexole sumatriptan topiramate propranolol buspirone naltrexone buprenorphine methadone varenicline
nicotine ursodiol lactulose rifaximin mesalamine budesonide loperamide bisacodyl senna docusate polyethylene glycol
"""

STOPLIST = {
    "potassium", "sodium", "calcium", "magnesium", "glucose", "water", "oxygen", "iron", "zinc", "alcohol",
    "nitrogen", "urea", "creatinine", "cholesterol", "albumin", "protein", "hemoglobin", "bilirubin", "lactate",
    "phosphate", "chloride", "bicarbonate", "carbon", "hydrogen", "sugar", "salt", "starch", "sucrose", "lactose",
    "glycerin", "ethanol", "methanol", "acetone", "ammonia", "nitric", "oxide", "dextrose", "saline", "collagen",
    "cellulose", "silica", "talc", "wax", "honey", "milk", "yeast", "pepper", "mint", "coffee", "tea", "ginger",
    "garlic", "onion", "rice", "wheat", "corn", "soy", "oat", "egg", "fish", "beef", "pork", "apple", "orange",
    "lemon", "grape", "cherry", "banana", "peach", "pear", "plum", "date", "fig", "lime", "cocoa", "cotton", "wool",
    "silk", "nylon", "rubber", "latex", "gold", "silver", "copper", "lead", "tin", "mercury", "arsenic", "chrome",
    "nickel", "carbonate", "acetate", "citrate", "sulfate", "gluconate", "vitamin", "folate", "biotin", "carnitine",
    "creatine", "caffeine", "menthol", "camphor", "eucalyptus", "aloe", "chamomile", "lavender", "rose", "cinnamon",
    "clove", "thyme", "basil", "sage", "oregano", "pine", "cedar", "birch", "maple", "oak", "grass", "pollen",
    "dust", "mold", "cat", "dog", "horse", "feather", "insulin regular", "male", "female", "daily", "tablet",
    "capsule", "solution", "cream", "ointment", "patch", "injection", "spray", "drops", "syrup", "powder",
}


def is_simple_name(name: str) -> bool:
    return bool(re.fullmatch(r"[a-z][a-z\- ]{3,29}", name)) and len(name.split()) <= 3 and name not in STOPLIST


def resolve_rxcui(name: str) -> str | None:
    url = "https://rxnav.nlm.nih.gov/REST/rxcui.json?" + urllib.parse.urlencode({"name": name, "search": 1})
    try:
        try:
            import httpx  # ships certifi; the stock python.org urllib has no CA bundle

            payload = httpx.get(url, timeout=15).json()
        except ImportError:
            with urllib.request.urlopen(url, timeout=15) as response:
                payload = json.load(response)
        ids = payload.get("idGroup", {}).get("rxnormId") or []
        return ids[0] if ids else None
    except Exception:
        return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--displaynames", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--skip-resolve", action="store_true")
    args = parser.parse_args()

    display_terms = json.load(open(args.displaynames))["displayTermsList"]["term"]
    names: dict[str, str | None] = {}
    for term in display_terms:
        lowered = term.strip().lower()
        if is_simple_name(lowered):
            names[lowered] = None

    curated = [token for token in COMMON_GENERICS.split() if token]
    # Two-word generics in the curated list are written as separate tokens above;
    # join known pairs back together.
    pairs = {"ferrous": "sulfate", "folic": "acid", "potassium": "chloride", "magnesium": "oxide", "sodium": "bicarbonate",
             "epoetin": "alfa", "isosorbide": None, "polyethylene": "glycol"}
    curated_names: list[str] = []
    skip_next = False
    for index, token in enumerate(curated):
        if skip_next:
            skip_next = False
            continue
        if token in pairs and index + 1 < len(curated) and (pairs[token] is None or curated[index + 1] == pairs[token]):
            curated_names.append(f"{token} {curated[index + 1]}")
            skip_next = True
        else:
            curated_names.append(token)
    curated_names = sorted(set(curated_names))

    resolved = 0
    for name in curated_names:
        names.setdefault(name, None)
        if args.skip_resolve:
            continue
        rxcui = resolve_rxcui(name)
        if rxcui:
            names[name] = rxcui
            resolved += 1
        time.sleep(0.35)  # RxNav asks for ≤3 requests/second

    for stop in STOPLIST:
        names.pop(stop, None)

    json.dump({"generated": date.today().isoformat(), "source": "RxNorm display names via RxNav; RXCUIs via RxNav rxcui.json",
               "names": names}, open(args.out, "w"))
    print(f"{len(names)} names, {resolved} RXCUIs resolved for {len(curated_names)} curated generics → {args.out}")


if __name__ == "__main__":
    main()

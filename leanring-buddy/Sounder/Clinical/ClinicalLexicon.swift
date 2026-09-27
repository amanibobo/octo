//
//  ClinicalLexicon.swift
//  leanring-buddy
//
//  On-device dictionaries for clinical entity extraction: drug names → RXCUI
//  (built from RxNorm via RxNav, shipped as drug_lexicon.json), condition
//  aliases → ICD-10 codes, and lab names. Nothing here needs the network.
//

import Foundation

nonisolated struct ClinicalCondition: Sendable {
    let canonicalName: String
    let code: String
    let aliases: [String]
}

nonisolated struct ClinicalLexicon: Sendable {
    /// Lowercase drug name → RXCUI when resolved, nil when detection-only.
    let rxcuiByDrugName: [String: String?]

    static let conditions: [ClinicalCondition] = [
        ClinicalCondition(canonicalName: "atrial fibrillation", code: "I48", aliases: ["atrial fibrillation", "afib", "a-fib", "AF"]),
        ClinicalCondition(canonicalName: "hfpef", code: "I50.32", aliases: ["hfpef", "heart failure with preserved ejection fraction"]),
        ClinicalCondition(canonicalName: "hfref", code: "I50.22", aliases: ["hfref", "heart failure with reduced ejection fraction"]),
        ClinicalCondition(canonicalName: "heart failure", code: "I50.9", aliases: ["heart failure", "congestive heart failure", "chf"]),
        ClinicalCondition(canonicalName: "type 2 diabetes", code: "E11", aliases: ["type 2 diabetes mellitus", "type 2 diabetes", "diabetes mellitus type 2", "t2dm", "t2d"]),
        ClinicalCondition(canonicalName: "type 1 diabetes", code: "E10", aliases: ["type 1 diabetes mellitus", "type 1 diabetes", "t1dm"]),
        ClinicalCondition(canonicalName: "chronic kidney disease", code: "N18", aliases: ["chronic kidney disease", "ckd"]),
        ClinicalCondition(canonicalName: "hypertension", code: "I10", aliases: ["essential hypertension", "hypertension", "htn"]),
        ClinicalCondition(canonicalName: "hyperlipidemia", code: "E78.5", aliases: ["hyperlipidemia", "dyslipidemia", "hypercholesterolemia"]),
        ClinicalCondition(canonicalName: "coronary artery disease", code: "I25.10", aliases: ["coronary artery disease", "cad", "ischemic heart disease"]),
        ClinicalCondition(canonicalName: "copd", code: "J44.9", aliases: ["copd", "chronic obstructive pulmonary disease"]),
        ClinicalCondition(canonicalName: "asthma", code: "J45", aliases: ["asthma"]),
        ClinicalCondition(canonicalName: "depression", code: "F32", aliases: ["major depressive disorder", "depression"]),
        ClinicalCondition(canonicalName: "anxiety", code: "F41", aliases: ["generalized anxiety disorder", "anxiety"]),
        ClinicalCondition(canonicalName: "hypothyroidism", code: "E03.9", aliases: ["hypothyroidism"]),
        ClinicalCondition(canonicalName: "gout", code: "M10", aliases: ["gout"]),
        ClinicalCondition(canonicalName: "osteoporosis", code: "M81", aliases: ["osteoporosis"]),
        ClinicalCondition(canonicalName: "gerd", code: "K21", aliases: ["gerd", "gastroesophageal reflux"]),
        ClinicalCondition(canonicalName: "oral candidiasis", code: "B37.0", aliases: ["oral candidiasis", "thrush", "candidiasis"]),
        ClinicalCondition(canonicalName: "pneumonia", code: "J18", aliases: ["pneumonia"]),
        ClinicalCondition(canonicalName: "urinary tract infection", code: "N39.0", aliases: ["urinary tract infection", "uti"]),
        ClinicalCondition(canonicalName: "stroke", code: "I63", aliases: ["ischemic stroke", "stroke", "cva"]),
        ClinicalCondition(canonicalName: "deep vein thrombosis", code: "I82.4", aliases: ["deep vein thrombosis", "dvt"]),
        ClinicalCondition(canonicalName: "pulmonary embolism", code: "I26", aliases: ["pulmonary embolism"]),
        ClinicalCondition(canonicalName: "obesity", code: "E66.9", aliases: ["obesity"]),
        ClinicalCondition(canonicalName: "sleep apnea", code: "G47.33", aliases: ["obstructive sleep apnea", "sleep apnea", "osa"]),
        ClinicalCondition(canonicalName: "epilepsy", code: "G40", aliases: ["epilepsy", "seizure disorder"]),
        ClinicalCondition(canonicalName: "parkinson disease", code: "G20", aliases: ["parkinson disease", "parkinson's disease", "parkinsons"]),
        ClinicalCondition(canonicalName: "dementia", code: "F03", aliases: ["dementia", "alzheimer disease", "alzheimer's disease"]),
        ClinicalCondition(canonicalName: "rheumatoid arthritis", code: "M06.9", aliases: ["rheumatoid arthritis"]),
        ClinicalCondition(canonicalName: "osteoarthritis", code: "M19.90", aliases: ["osteoarthritis"]),
        ClinicalCondition(canonicalName: "migraine", code: "G43", aliases: ["migraine"]),
        ClinicalCondition(canonicalName: "anemia", code: "D64.9", aliases: ["anemia", "iron deficiency anemia"]),
        ClinicalCondition(canonicalName: "hyperkalemia", code: "E87.5", aliases: ["hyperkalemia"]),
    ]

    /// Lab name tokens (lowercase) → canonical key sent to the service.
    static let labKeys: [String: String] = [
        "egfr": "egfr", "gfr": "egfr", "creatinine": "creatinine_mg_dl", "cr": "creatinine_mg_dl", "scr": "creatinine_mg_dl",
        "inr": "inr", "potassium": "potassium", "k+": "potassium", "hba1c": "hba1c", "a1c": "hba1c",
    ]

    /// A small built-in list so extraction works even if the shipped JSON is missing.
    private static let fallbackDrugNames: [String: String?] = [
        "warfarin": "11289", "fluconazole": "4450", "metformin": "6809", "lisinopril": "29046", "furosemide": "4603",
        "atorvastatin": "83367", "simvastatin": "36567", "amlodipine": "17767", "metoprolol": "6918", "losartan": "52175",
        "aspirin": "1191", "ibuprofen": "5640", "naproxen": "7258", "acetaminophen": "161", "omeprazole": "7646",
        "clopidogrel": "32968", "apixaban": "1364430", "rivaroxaban": "1114195", "digoxin": "3407", "amiodarone": "703",
        "spironolactone": "9997", "hydrochlorothiazide": "5487", "sertraline": "36437", "citalopram": "2556",
        "gabapentin": "25480", "tramadol": "10689", "oxycodone": "7804", "prednisone": "8640", "levothyroxine": "10582",
        "insulin": nil, "glipizide": "4821", "empagliflozin": "1545653", "dapagliflozin": "1488564", "ciprofloxacin": "2551",
        "azithromycin": "18631", "amoxicillin": "723", "doxycycline": "3640", "ondansetron": "26225", "lorazepam": "6470",
        "alprazolam": "596", "zolpidem": "39993", "potassium chloride": "8591", "allopurinol": "519", "tacrolimus": "42316",
    ]

    static func load() -> ClinicalLexicon {
        if let url = Bundle.main.url(forResource: "drug_lexicon", withExtension: "json"),
           let lexicon = load(fromFileAt: url) {
            return lexicon
        }
        print("💊 Clinical lexicon: drug_lexicon.json not in bundle, using the built-in fallback list")
        return ClinicalLexicon(rxcuiByDrugName: fallbackDrugNames)
    }

    static func load(fromFileAt url: URL) -> ClinicalLexicon? {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = payload["names"] as? [String: Any] else {
            return nil
        }
        var table: [String: String?] = [:]
        for (name, value) in names {
            table[name] = value as? String
        }
        // Make sure the curated fallback names are always present with their RXCUIs.
        for (name, rxcui) in fallbackDrugNames where table[name] == nil || table[name]! == nil {
            table[name] = rxcui
        }
        print("💊 Clinical lexicon: \(table.count) drug names loaded")
        return ClinicalLexicon(rxcuiByDrugName: table)
    }

    func isDrugName(_ candidate: String) -> Bool {
        rxcuiByDrugName[candidate] != nil
    }

    func rxcui(forDrugName name: String) -> String? {
        rxcuiByDrugName[name] ?? nil
    }
}

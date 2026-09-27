"""Generate a Telco-churn-shaped synthetic table for tests and manual demos.

Mirrors the Kaggle Telco Customer Churn columns so the same voice questions work
("what drives churn?", "what's weird here?"). Contract and tenure are made to
drive churn; MonthlyCharges is mostly noise, matching the demo script in the PRD.
"""

from __future__ import annotations

import csv
import random
import sys

HEADERS = ["customerID", "gender", "tenure", "Contract", "InternetService", "MonthlyCharges", "TotalCharges", "Churn"]


def make_rows(row_count: int, seed: int = 7, anomaly_count: int = 4) -> list[list[str]]:
    rng = random.Random(seed)
    rows = []
    for index in range(row_count):
        contract = rng.choices(["Month-to-month", "One year", "Two year"], weights=[0.55, 0.21, 0.24])[0]
        tenure = int(max(1, min(72, rng.gauss(12 if contract == "Month-to-month" else 40, 14))))
        internet = rng.choice(["DSL", "Fiber optic", "No"])
        monthly = round(rng.uniform(19, 118), 2)
        total = round(monthly * tenure * rng.uniform(0.9, 1.05), 2)
        churn_probability = 0.05 + 0.45 * (contract == "Month-to-month") + 0.25 * (tenure < 6) - 0.002 * tenure
        churn = "Yes" if rng.random() < max(0.02, min(0.95, churn_probability)) else "No"
        rows.append([f"{1000 + index}-AB", rng.choice(["Male", "Female"]), str(tenure), contract, internet,
                     f"{monthly:.2f}", f"{total:.2f}", churn])

    # Plant obvious anomalies: tiny tenure with charges far above the plan median.
    for anomaly_index in range(anomaly_count):
        row = rows[anomaly_index * 37 % len(rows)]
        row[2] = "2"
        row[5] = f"{rng.uniform(280, 360):.2f}"
        row[6] = f"{float(row[5]) * 2:.2f}"
    return rows


if __name__ == "__main__":
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    writer = csv.writer(sys.stdout)
    writer.writerow(HEADERS)
    writer.writerows(make_rows(count))

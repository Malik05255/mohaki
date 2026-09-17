#!/usr/bin/env python3
"""Fail the production pipeline when measured Tier-A pruning is still material.

This gate runs only after size-analysis artifacts have been uploaded, so a failed
build still leaves enough evidence to make the next pruning pass deterministic.
It never recommends deleting protected compatibility/quality components.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("analysis_json", type=Path)
    parser.add_argument("--max-tier-a-total-mib", type=float, default=12.0)
    parser.add_argument("--max-tier-a-file-mib", type=float, default=4.0)
    args = parser.parse_args()

    data = json.loads(args.analysis_json.read_text(encoding="utf-8"))
    measured = data.get("measuredPruning", {})
    tier_a = float(measured.get("tierATotalMiB", 0.0))
    largest = float(measured.get("largestTierAFileMiB", 0.0))
    candidates = data.get("safeReviewCandidates", [])

    print(f"Measured Tier A total: {tier_a:.2f} MiB (budget <= {args.max_tier_a_total_mib:.2f} MiB)")
    print(f"Largest Tier A file: {largest:.2f} MiB (budget <= {args.max_tier_a_file_mib:.2f} MiB)")

    failed = tier_a > args.max_tier_a_total_mib or largest > args.max_tier_a_file_mib
    if failed:
        print("FAIL: JawalOS still contains material measured Tier-A pruning opportunities.")
        print("Review dist/android/pruning-plan.md before packaging a release candidate.")
        for item in candidates[:10]:
            print(f"  {float(item.get('sizeMiB', 0.0)):7.2f} MiB  {item.get('path', '')}")
        return 6

    print("PASS: measured Tier-A pruning opportunity is below the production budget.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

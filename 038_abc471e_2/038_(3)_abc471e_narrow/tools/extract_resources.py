#!/usr/bin/env python3
"""Extract the required Forge/Yosys resource counts from a stat report."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path


PRIMITIVES = (
    "CARRY4",
    "FDCE",
    "FDPE",
    "INV",
    "LUT2",
    "LUT3",
    "LUT4",
    "LUT5",
    "LUT6",
    "MUXF7",
    "MUXF8",
)


def scalar(text: str, label: str) -> int:
    match = re.search(rf"^\s*(\d+)\s+{re.escape(label)}\s*$", text, re.MULTILINE)
    if not match:
        raise ValueError(f"missing statistic: {label}")
    return int(match.group(1))


def primitive(text: str, name: str) -> int:
    match = re.search(rf"^\s*(\d+)\s+{re.escape(name)}\s*$", text, re.MULTILINE)
    return int(match.group(1)) if match else 0


def classify(lut_bound: int, ff_bound: int) -> str:
    largest = max(lut_bound, ff_bound)
    if lut_bound <= 140 and ff_bound <= 140:
        return "PNR候補"
    if largest <= 154:  # within 10% of the device capacity
        return "境界域"
    return "PNR価値低"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--mod", required=True, type=int)
    parser.add_argument("--n-max", required=True, type=int)
    parser.add_argument("--json-out", required=True, type=Path)
    parser.add_argument("--text-out", required=True, type=Path)
    args = parser.parse_args()

    text = args.report.read_text(encoding="utf-8", errors="replace")
    counts = {name: primitive(text, name) for name in PRIMITIVES}
    ff_total = counts["FDCE"] + counts["FDPE"]
    lut_total = sum(counts[f"LUT{size}"] for size in range(2, 7))
    lut_mux_total = lut_total + counts["MUXF7"] + counts["MUXF8"]
    lut_bound = math.ceil(lut_total / 4)
    ff_bound = math.ceil(ff_total / 8)
    result = {
        "width": args.width,
        "mod": args.mod,
        "n_max": args.n_max,
        "wires": scalar(text, "wires"),
        "wire_bits": scalar(text, "wire bits"),
        "cells": scalar(text, "cells"),
        **counts,
        "ff_total": ff_total,
        "lut_total": lut_total,
        "lut_mux_total": lut_mux_total,
        "lut_only_rough_lower_bound": lut_bound,
        "raw_ff_lower_bound": ff_bound,
        "screening": classify(lut_bound, ff_bound),
    }
    args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    args.text_out.write_text(
        "\n".join(f"{key}={value}" for key, value in result.items()) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(result))


if __name__ == "__main__":
    main()

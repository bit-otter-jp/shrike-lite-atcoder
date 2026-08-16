#!/usr/bin/env python3
"""Generate and verify representative maximum-size fast-vvp cases."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from out_of_order_cases import N, Q, RANDOM_SEED, generate_case, verify


def main() -> None:
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output-dir", type=Path)
    action.add_argument(
        "--verify", nargs=2, type=Path, metavar=("ACTUAL", "EXPECTED")
    )
    args = parser.parse_args()

    if args.verify is not None:
        verify(args.verify[0], args.verify[1])
        return

    assert args.output_dir is not None
    args.output_dir.mkdir(parents=True, exist_ok=True)
    cases = [
        generate_case(args.output_dir, "random"),
        generate_case(args.output_dir, "cancellation_rich"),
    ]
    for case in cases:
        case["final_inverted"] = int(case["type2_count"]) % 2

    manifest = {
        "n": N,
        "q": Q,
        "random_seed": RANDOM_SEED,
        "cases": cases,
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2), encoding="utf-8", newline="\n"
    )
    print(manifest_path)


if __name__ == "__main__":
    main()

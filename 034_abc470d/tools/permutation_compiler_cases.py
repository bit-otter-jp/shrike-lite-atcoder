#!/usr/bin/env python3
"""Generate and verify maximum-size A-F permutation-compiler cases."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from out_of_order_cases import (
    FIXED_K,
    N,
    Q,
    RANDOM_SEED,
    FixedBatchCounter,
    generate_case,
    verify,
    write_permutation,
)


def generate_strong_dependency(output_dir: Path) -> dict[str, object]:
    name = "strong_dependency"
    input_path = output_dir / f"{name}.in"
    expected_path = output_dir / f"{name}.expected"
    permutation = list(range(1, N + 1))
    fixed = FixedBatchCounter(FIXED_K)

    with input_path.open("w", encoding="ascii", newline="\n") as output:
        output.write(f"{N} {Q}\n")
        output.write(" ".join(map(str, range(1, N + 1))))
        output.write("\n")
        for index in range(Q):
            if index % 2 == 0:
                x, y = 1, 2
            else:
                x, y = 2, 3
            output.write(f"1 {x} {y}\n")
            permutation[x - 1], permutation[y - 1] = (
                permutation[y - 1],
                permutation[x - 1],
            )
            fixed.add_type1(x, y)

    write_permutation(expected_path, permutation)
    return {
        "name": name,
        "input": str(input_path),
        "expected": str(expected_path),
        "n": N,
        "q": Q,
        "type1_count": Q,
        "type2_count": 0,
        "final_inverted": 0,
        "baseline_logical_clocks": Q + 2,
        "fixed_k256_logical_clocks": fixed.finish() + 2,
    }


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
    names = [
        "high_parallel",
        "random",
        "high_conflict",
        "interleaved_dependency",
        "cancellation_rich",
    ]
    cases = [generate_case(args.output_dir, name) for name in names]
    for case in cases:
        case["final_inverted"] = int(case["type2_count"]) % 2
    cases.append(generate_strong_dependency(args.output_dir))

    manifest = {
        "n": N,
        "q": Q,
        "fixed_k": FIXED_K,
        "issue_width": 256,
        "lookahead": 1024,
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


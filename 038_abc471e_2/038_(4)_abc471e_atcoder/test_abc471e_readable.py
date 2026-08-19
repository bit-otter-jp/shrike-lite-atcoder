#!/usr/bin/env python3
"""Compile and independently test the readable ABC471E Verilog solution."""

from __future__ import annotations

import argparse
import itertools
import math
import random
import subprocess
import sys
from pathlib import Path


MOD = 998_244_353
ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "abc471e_readable.v"
EXECUTABLE = ROOT / "abc471e_readable.out"
CODE_TEST_INPUT = ROOT / "abc471e_code_test.in"
CODE_TEST_ANSWER = 379_620_342


OFFICIAL_CASES = [
    ("sample 1", 3, 2, [1, 10, 100], 22_422),
    ("sample 2", 5, 2, [10, 10, 20, 20, 20], 10_600),
    ("sample 3", 2, 1, [998_244_353, 998_244_353], 0),
]


EDGE_CASES = [
    ("N=1, K=1, zero", 1, 1, [0]),
    ("N=1, K=1, one", 1, 1, [1]),
    ("N=1, K=1, maximum", 1, 1, [1_000_000_000]),
    ("K=1", 5, 1, [0, 1, 2, 998_244_353, 1_000_000_000]),
    ("K=N", 6, 6, [0, 1, 1, 1, 1, 1_000_000_000]),
    ("all zero", 8, 4, [0] * 8),
    ("all one", 8, 4, [1] * 8),
    ("all maximum", 8, 4, [1_000_000_000] * 8),
    ("equal values", 7, 3, [123_456_789] * 7),
]


def compile_verilog() -> None:
    subprocess.run(
        [
            "iverilog",
            "-g2012",
            "-Wall",
            "-s",
            "main",
            "-o",
            str(EXECUTABLE),
            str(SOURCE),
        ],
        cwd=ROOT,
        check=True,
    )


def brute_force(values: list[int], k: int) -> int:
    """Independent oracle: enumerate selections and square each selected sum."""
    return sum(sum(selected) ** 2 for selected in itertools.combinations(values, k)) % MOD


def fast_oracle(values: list[int], k: int) -> int:
    """Large-input oracle using Python integers and contribution counts."""
    n = len(values)
    square_total = sum(value * value for value in values)
    pair_total = 0
    prefix = 0
    for value in values:
        pair_total += prefix * value
        prefix += value

    single_count = math.comb(n - 1, k - 1)
    pair_count = math.comb(n - 2, k - 2) if k >= 2 else 0
    return (single_count * square_total + 2 * pair_count * pair_total) % MOD


def format_input(n: int, k: int, values: list[int]) -> str:
    return f"{n} {k}\n{' '.join(map(str, values))}\n"


def run_input(input_text: str) -> int:
    completed = subprocess.run(
        ["vvp", str(EXECUTABLE)],
        cwd=ROOT,
        input=input_text,
        text=True,
        capture_output=True,
        check=True,
    )
    if completed.stderr:
        raise AssertionError(f"unexpected stderr: {completed.stderr!r}")
    output = completed.stdout.strip()
    if not output or not output.isdigit():
        raise AssertionError(f"invalid Verilog output: {completed.stdout!r}")
    return int(output)


def check_case(name: str, n: int, k: int, values: list[int], expected: int) -> None:
    actual = run_input(format_input(n, k, values))
    if actual != expected:
        raise AssertionError(
            f"{name} failed: N={n}, K={k}, A={values}, "
            f"expected={expected}, actual={actual}"
        )


def run_tests(random_cases: int, seed: int) -> None:
    for name, n, k, values, expected in OFFICIAL_CASES:
        check_case(name, n, k, values, expected)
    print(f"official samples: {len(OFFICIAL_CASES)} passed")

    for name, n, k, values in EDGE_CASES:
        check_case(name, n, k, values, brute_force(values, k))
    print(f"boundary cases: {len(EDGE_CASES)} passed")

    rng = random.Random(seed)
    special_values = [0, 1, MOD - 1, MOD, MOD + 1, 1_000_000_000]
    for case_index in range(random_cases):
        n = rng.randint(1, 8)
        k = rng.randint(1, n)
        values = [
            rng.choice(special_values)
            if rng.random() < 0.35
            else rng.randint(0, 1_000_000_000)
            for _ in range(n)
        ]
        check_case(
            f"random case {case_index}",
            n,
            k,
            values,
            brute_force(values, k),
        )
    print(f"random exhaustive-oracle cases: {random_cases} passed (seed={seed})")

    code_test_text = CODE_TEST_INPUT.read_text(encoding="ascii")
    actual = run_input(code_test_text)
    if actual != CODE_TEST_ANSWER:
        raise AssertionError(
            f"code-test input failed: expected={CODE_TEST_ANSWER}, actual={actual}"
        )
    print(f"code-test input: passed (answer={actual})")


def make_max_values(n: int) -> list[int]:
    return [((index * 1_000_003 + 123_456_789) % 1_000_000_000) + 1 for index in range(n)]


def write_max_case(path: Path, n: int = 200_000, k: int = 100_000) -> None:
    values = make_max_values(n)
    path.write_text(format_input(n, k, values), encoding="ascii", newline="\n")
    print(f"wrote {path.resolve()} (N={n}, K={k}, expected={fast_oracle(values, k)})")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--random-cases", type=int, default=300)
    parser.add_argument("--seed", type=int, default=47_100_005)
    parser.add_argument("--skip-compile", action="store_true")
    parser.add_argument("--write-max-case", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.skip_compile:
        compile_verilog()
    run_tests(args.random_cases, args.seed)
    if args.write_max_case is not None:
        write_max_case(args.write_max_case)
    print("all tests passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)

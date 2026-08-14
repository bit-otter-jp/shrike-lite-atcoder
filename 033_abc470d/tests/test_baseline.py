#!/usr/bin/env python3
"""Compile and validate the ABC470D ideal-FPGA baseline."""

from __future__ import annotations

import argparse
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "abc470d_baseline.sv"
BUILD_DIR = ROOT / "build"
VVP_IMAGE = BUILD_DIR / "abc470d_baseline.vvp"


SAMPLES = [
    (
        """5 5
2 1 3 5 4
1 2 4
2
1 2 3
1 3 4
2
""",
        "4 5 2 1 3",
    ),
    (
        """7 4
3 7 5 6 4 2 1
2
2
2
2
""",
        "3 7 5 6 4 2 1",
    ),
    (
        """10 8
7 3 2 4 8 5 10 9 1 6
2
1 4 10
1 6 9
2
1 9 10
1 3 10
2
1 4 6
""",
        "3 10 2 8 6 7 1 5 9 4",
    ),
]


def compile_design() -> None:
    iverilog = shutil.which("iverilog")
    if iverilog is None:
        raise RuntimeError("iverilog was not found in PATH")
    BUILD_DIR.mkdir(exist_ok=True)
    command = [
        iverilog,
        "-g2012",
        "-Wall",
        "-DONLINE_JUDGE",
        "-DATCODER",
        "-s",
        "abc470d_baseline",
        "-o",
        str(VVP_IMAGE),
        str(SOURCE),
    ]
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.returncode != 0:
        raise RuntimeError(
            f"iverilog failed\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )


def run_design(input_text: str, expected_clocks: int) -> list[int]:
    vvp = shutil.which("vvp")
    if vvp is None:
        raise RuntimeError("vvp was not found in PATH")
    completed = subprocess.run(
        [vvp, "-n", str(VVP_IMAGE)],
        input=input_text,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"vvp failed with {completed.returncode}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    if "$finish called" in completed.stdout:
        raise AssertionError("Icarus diagnostic polluted stdout")

    match = re.search(r"LOGICAL_CLOCKS=(\d+) EXPECTED=(\d+)", completed.stderr)
    if match is None:
        raise AssertionError(f"clock diagnostic is missing: {completed.stderr!r}")
    actual_clock, internal_expected = map(int, match.groups())
    if actual_clock != expected_clocks or internal_expected != expected_clocks:
        raise AssertionError(
            f"clock mismatch: actual={actual_clock}, "
            f"internal_expected={internal_expected}, expected={expected_clocks}"
        )

    try:
        return [int(token) for token in completed.stdout.split()]
    except ValueError as error:
        raise AssertionError(f"non-integer stdout: {completed.stdout!r}") from error


def reference(initial: list[int], queries: list[tuple[int, ...]]) -> list[int]:
    permutation = initial[:]
    for query in queries:
        if query[0] == 1:
            _, x, y = query
            permutation[x - 1], permutation[y - 1] = (
                permutation[y - 1],
                permutation[x - 1],
            )
        else:
            inverse = [0] * len(permutation)
            for position, value in enumerate(permutation, start=1):
                inverse[value - 1] = position
            permutation = inverse
    return permutation


def make_input(initial: list[int], queries: list[tuple[int, ...]]) -> str:
    lines = [f"{len(initial)} {len(queries)}", " ".join(map(str, initial))]
    lines.extend(" ".join(map(str, query)) for query in queries)
    return "\n".join(lines) + "\n"


def check_case(
    name: str, initial: list[int], queries: list[tuple[int, ...]]
) -> None:
    expected = reference(initial, queries)
    actual = run_design(make_input(initial, queries), len(queries) + 2)
    if actual != expected:
        raise AssertionError(
            f"{name} failed\ninitial={initial}\nqueries={queries}\n"
            f"expected={expected}\nactual={actual}"
        )


def run_samples() -> None:
    for index, (input_text, expected_text) in enumerate(SAMPLES, start=1):
        q = int(input_text.splitlines()[0].split()[1])
        actual = run_design(input_text, q + 2)
        expected = [int(token) for token in expected_text.split()]
        if actual != expected:
            raise AssertionError(
                f"official sample {index} failed: expected={expected}, actual={actual}"
            )


def run_boundaries() -> None:
    cases = [
        ("minimum swap", [1, 2], [(1, 1, 2)]),
        ("minimum inverse", [2, 1], [(2,)]),
        ("odd inversions", [2, 3, 1], [(2,), (2,), (2,)]),
        ("even inversions", [2, 3, 1], [(2,), (2,), (2,), (2,)]),
        ("endpoint swaps", [5, 4, 3, 2, 1], [(1, 1, 5)] * 9),
        (
            "swap around inverse",
            [4, 1, 5, 2, 3],
            [(1, 1, 5), (2,), (1, 2, 4), (2,), (1, 1, 5)],
        ),
        (
            "all swaps",
            [3, 1, 6, 2, 5, 4],
            [(1, 1, 6), (1, 2, 5), (1, 3, 4), (1, 1, 2)],
        ),
        ("all inverses", [4, 2, 1, 3], [(2,)] * 11),
    ]
    for name, initial, queries in cases:
        check_case(name, initial, queries)


def run_random(seed: int, count: int) -> None:
    rng = random.Random(seed)
    for case_index in range(count):
        n = rng.randint(2, 30)
        q = rng.randint(1, 80)
        initial = list(range(1, n + 1))
        rng.shuffle(initial)
        queries: list[tuple[int, ...]] = []
        for _ in range(q):
            if rng.random() < 0.65:
                x, y = sorted(rng.sample(range(1, n + 1), 2))
                queries.append((1, x, y))
            else:
                queries.append((2,))
        check_case(f"random case {case_index}", initial, queries)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--random-cases", type=int, default=300)
    parser.add_argument("--seed", type=int, default=470)
    args = parser.parse_args()

    compile_design()
    run_samples()
    run_boundaries()
    run_random(args.seed, args.random_cases)
    print(
        f"PASS: 3 official samples, 8 boundary cases, "
        f"{args.random_cases} random cases (seed={args.seed})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

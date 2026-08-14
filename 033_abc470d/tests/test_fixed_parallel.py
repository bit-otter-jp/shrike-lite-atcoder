#!/usr/bin/env python3
"""Validate all fixed-width parallel variants against sequential semantics."""

from __future__ import annotations

import argparse
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "abc470d_fixed_parallel.sv"
BUILD_DIR = ROOT / "build"
DEFAULT_KS = [4, 8, 16, 32, 64, 128, 256, 512]


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


def image_path(k: int) -> Path:
    return BUILD_DIR / f"abc470d_fixed_parallel_k{k}.vvp"


def compile_design(k: int) -> None:
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
        "abc470d_fixed_parallel",
        "-P",
        f"abc470d_fixed_parallel.K={k}",
        "-o",
        str(image_path(k)),
        str(SOURCE),
    ]
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.returncode != 0:
        raise RuntimeError(
            f"iverilog failed for K={k}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )


def run_design(input_text: str, k: int, expected_clocks: int) -> list[int]:
    vvp = shutil.which("vvp")
    if vvp is None:
        raise RuntimeError("vvp was not found in PATH")
    completed = subprocess.run(
        [vvp, "-n", str(image_path(k))],
        input=input_text,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"vvp failed for K={k} with {completed.returncode}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    if "$finish called" in completed.stdout:
        raise AssertionError("Icarus diagnostic polluted stdout")

    match = re.search(
        r"LOGICAL_CLOCKS=(\d+) QUERY_CLOCKS=(\d+) K=(\d+)",
        completed.stderr,
    )
    if match is None:
        raise AssertionError(f"clock diagnostic is missing: {completed.stderr!r}")
    logical_clocks, query_clocks, reported_k = map(int, match.groups())
    if reported_k != k:
        raise AssertionError(f"compiled K={k}, design reported K={reported_k}")
    if logical_clocks != expected_clocks or query_clocks != expected_clocks - 2:
        raise AssertionError(
            f"K={k} clock mismatch: logical={logical_clocks}, "
            f"query={query_clocks}, expected={expected_clocks}"
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


def expected_logical_clocks(queries: list[tuple[int, ...]], k: int) -> int:
    index = 0
    query_clocks = 0
    while index < len(queries):
        if queries[index][0] == 2:
            index += 1
            query_clocks += 1
            continue

        used: set[int] = set()
        group_size = 0
        while group_size < k and index + group_size < len(queries):
            query = queries[index + group_size]
            if query[0] == 2:
                break
            _, x, y = query
            if x in used or y in used:
                break
            used.add(x)
            used.add(y)
            group_size += 1

        if group_size == 0:
            raise AssertionError("a Type 1 group made no progress")
        index += group_size
        query_clocks += 1

    return query_clocks + 2


def make_input(initial: list[int], queries: list[tuple[int, ...]]) -> str:
    lines = [f"{len(initial)} {len(queries)}", " ".join(map(str, initial))]
    lines.extend(" ".join(map(str, query)) for query in queries)
    return "\n".join(lines) + "\n"


def parse_input(input_text: str) -> tuple[list[int], list[tuple[int, ...]]]:
    lines = input_text.strip().splitlines()
    n, q = map(int, lines[0].split())
    initial = list(map(int, lines[1].split()))
    queries = [tuple(map(int, line.split())) for line in lines[2:]]
    if len(initial) != n or len(queries) != q:
        raise AssertionError("invalid embedded sample")
    return initial, queries


def check_case(
    name: str,
    initial: list[int],
    queries: list[tuple[int, ...]],
    k: int,
) -> None:
    expected = reference(initial, queries)
    clocks = expected_logical_clocks(queries, k)
    actual = run_design(make_input(initial, queries), k, clocks)
    if actual != expected:
        raise AssertionError(
            f"{name}, K={k} failed\ninitial={initial}\nqueries={queries}\n"
            f"expected={expected}\nactual={actual}"
        )


def special_cases() -> list[tuple[str, list[int], list[tuple[int, ...]]]]:
    return [
        ("minimum swap", [1, 2], [(1, 1, 2)]),
        ("minimum inverse", [2, 1], [(2,)]),
        ("odd inversions", [2, 3, 1], [(2,), (2,), (2,)]),
        ("even inversions", [2, 3, 1], [(2,), (2,), (2,), (2,)]),
        ("endpoint swaps", [5, 4, 3, 2, 1], [(1, 1, 5)] * 9),
        (
            "specified mid-group conflict",
            list(range(1, 9)),
            [(1, 1, 2), (1, 3, 4), (1, 5, 6), (1, 2, 7)],
        ),
        (
            "no skipping after conflict",
            list(range(1, 8)),
            [(1, 1, 2), (1, 2, 3), (1, 4, 5), (1, 6, 7)],
        ),
        (
            "width boundary",
            list(range(1, 25)),
            [(1, i, i + 1) for i in range(1, 24, 2)],
        ),
        (
            "frequent type 2",
            [4, 1, 6, 2, 5, 3],
            [(1, 1, 2), (2,), (1, 3, 4), (2,), (1, 5, 6), (2,)],
        ),
        (
            "type 1 around type 2",
            [4, 1, 5, 2, 3],
            [(1, 1, 5), (1, 2, 4), (2,), (1, 2, 4), (1, 1, 5)],
        ),
        (
            "multiple groups around type 2",
            list(range(8, 0, -1)),
            [
                (1, 1, 2),
                (1, 3, 4),
                (1, 5, 6),
                (2,),
                (1, 2, 3),
                (1, 4, 5),
                (1, 6, 7),
            ],
        ),
        (
            "all independent then conflict",
            list(range(1, 17)),
            [(1, i, i + 1) for i in range(1, 16, 2)] + [(1, 1, 16)],
        ),
    ]


def random_cases(seed: int, count: int) -> list[tuple[list[int], list[tuple[int, ...]]]]:
    rng = random.Random(seed)
    cases = []
    for _ in range(count):
        n = rng.randint(2, 40)
        q = rng.randint(1, 100)
        initial = list(range(1, n + 1))
        rng.shuffle(initial)
        queries: list[tuple[int, ...]] = []
        for _ in range(q):
            if rng.random() < 0.75:
                x, y = sorted(rng.sample(range(1, n + 1), 2))
                queries.append((1, x, y))
            else:
                queries.append((2,))
        cases.append((initial, queries))
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ks", type=int, nargs="+", default=DEFAULT_KS)
    parser.add_argument("--random-cases", type=int, default=300)
    parser.add_argument("--seed", type=int, default=470)
    args = parser.parse_args()

    generated_random_cases = random_cases(args.seed, args.random_cases)
    specials = special_cases()

    for k in args.ks:
        compile_design(k)

        for sample_index, (input_text, expected_text) in enumerate(SAMPLES, start=1):
            initial, queries = parse_input(input_text)
            expected = [int(token) for token in expected_text.split()]
            actual = run_design(
                input_text,
                k,
                expected_logical_clocks(queries, k),
            )
            if actual != expected:
                raise AssertionError(
                    f"official sample {sample_index}, K={k} failed: "
                    f"expected={expected}, actual={actual}"
                )

        for name, initial, queries in specials:
            check_case(name, initial, queries, k)

        for case_index, (initial, queries) in enumerate(generated_random_cases):
            check_case(f"random case {case_index}", initial, queries, k)

        print(
            f"PASS K={k}: 3 samples, {len(specials)} special/boundary, "
            f"{args.random_cases} random"
        )

    print(f"PASS all K values: {args.ks} (seed={args.seed})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check abc470d_fast_vvp.sv against direct Python semantics."""

from __future__ import annotations

import argparse
import random
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "abc470d_fast_vvp.sv"
BUILD_DIR = ROOT / "build" / "fast_vvp"
IMAGE = BUILD_DIR / "test_fast_vvp.vvp"

Query = tuple[int, ...]

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
        [4, 5, 2, 1, 3],
    ),
    (
        """7 4
3 7 5 6 4 2 1
2
2
2
2
""",
        [3, 7, 5, 6, 4, 2, 1],
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
        [3, 10, 2, 8, 6, 7, 1, 5, 9, 4],
    ),
]


def compile_systemverilog() -> None:
    iverilog = shutil.which("iverilog")
    if iverilog is None:
        raise RuntimeError("iverilog was not found in PATH")
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [
            iverilog,
            "-g2012",
            "-Wall",
            "-DONLINE_JUDGE",
            "-DATCODER",
            "-s",
            "abc470d_fast_vvp",
            "-o",
            str(IMAGE),
            str(SOURCE),
        ],
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "iverilog failed\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    if completed.stderr:
        raise RuntimeError(f"iverilog emitted warnings:\n{completed.stderr}")


def parse_input(input_text: str) -> tuple[list[int], list[Query]]:
    lines = input_text.splitlines()
    n, q = map(int, lines[0].split())
    initial = list(map(int, lines[1].split()))
    queries = [tuple(map(int, line.split())) for line in lines[2:]]
    assert len(initial) == n
    assert len(queries) == q
    return initial, queries


def direct_reference(initial: list[int], queries: list[Query]) -> list[int]:
    current = initial[:]
    for query in queries:
        if query[0] == 1:
            _, x, y = query
            current[x - 1], current[y - 1] = (
                current[y - 1],
                current[x - 1],
            )
        else:
            inverse = [0] * len(current)
            for position, value in enumerate(current, start=1):
                inverse[value - 1] = position
            current = inverse
    return current


def serialize(initial: list[int], queries: list[Query]) -> str:
    lines = [
        f"{len(initial)} {len(queries)}",
        " ".join(map(str, initial)),
    ]
    lines.extend(" ".join(map(str, query)) for query in queries)
    return "\n".join(lines) + "\n"


def run_systemverilog(input_text: str) -> list[int]:
    completed = subprocess.run(
        ["vvp", "-n", str(IMAGE)],
        input=input_text,
        text=True,
        capture_output=True,
        timeout=15,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"vvp failed with {completed.returncode}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    if completed.stderr:
        raise AssertionError(f"unexpected stderr:\n{completed.stderr}")
    return [int(token) for token in completed.stdout.split()]


def check_case(name: str, initial: list[int], queries: list[Query]) -> None:
    expected = direct_reference(initial, queries)
    actual = run_systemverilog(serialize(initial, queries))
    if actual != expected:
        raise AssertionError(
            f"{name} failed\nexpected={expected}\nactual={actual}"
        )


def special_cases() -> list[tuple[str, list[int], list[Query]]]:
    return [
        ("minimum swap", [1, 2], [(1, 1, 2)]),
        ("one inverse", [2, 3, 1], [(2,)]),
        ("even toggles", [3, 1, 4, 2], [(2,), (2,), (2,), (2,)]),
        ("odd toggles", [3, 1, 4, 2], [(2,), (2,), (2,)]),
        (
            "first inverse-side swap",
            [4, 1, 5, 2, 3],
            [(2,), (1, 1, 5)],
        ),
        (
            "normal swaps before lazy inverse",
            [6, 1, 5, 2, 4, 3],
            [(1, 1, 6), (1, 2, 5), (2,), (1, 1, 4)],
        ),
        (
            "both orientations after inverse exists",
            [5, 2, 7, 1, 6, 3, 4],
            [(2,), (1, 2, 7), (2,), (1, 1, 6), (2,), (1, 3, 4)],
        ),
        (
            "same swap twice",
            list(range(1, 12)),
            [(1, 3, 9), (1, 3, 9)],
        ),
        (
            "input and output exact batch",
            list(range(64, 0, -1)),
            [(1, 1, 64)],
        ),
        (
            "inverse output batch remainder",
            list(range(65, 0, -1)),
            [(1, 1, 65), (2,)],
        ),
    ]


def random_cases(
    seed: int, count: int
) -> list[tuple[list[int], list[Query]]]:
    rng = random.Random(seed)
    cases = []
    for _ in range(count):
        n = rng.randint(2, 90)
        q = rng.randint(1, 120)
        initial = list(range(1, n + 1))
        rng.shuffle(initial)
        queries: list[Query] = []
        for _ in range(q):
            if rng.randrange(4) == 0:
                queries.append((2,))
            else:
                x = rng.randrange(1, n + 1)
                y = rng.randrange(1, n)
                if y >= x:
                    y += 1
                queries.append((1, x, y))
        cases.append((initial, queries))
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--random-cases", type=int, default=300)
    parser.add_argument("--seed", type=int, default=470)
    args = parser.parse_args()

    compile_systemverilog()

    for index, (input_text, official_answer) in enumerate(SAMPLES, start=1):
        initial, queries = parse_input(input_text)
        expected = direct_reference(initial, queries)
        if expected != official_answer:
            raise AssertionError(f"embedded official sample {index} is invalid")
        check_case(f"official sample {index}", initial, queries)

    specials = special_cases()
    for name, initial, queries in specials:
        check_case(name, initial, queries)

    for index, (initial, queries) in enumerate(
        random_cases(args.seed, args.random_cases)
    ):
        check_case(f"random case {index}", initial, queries)

    print(
        f"PASS: 3 official samples, {len(specials)} special, "
        f"{args.random_cases} random (seed={args.seed})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

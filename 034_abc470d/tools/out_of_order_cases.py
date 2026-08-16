#!/usr/bin/env python3
"""Generate and verify maximum-size A-E inputs for OoO measurements."""

from __future__ import annotations

import argparse
import json
import random
from itertools import zip_longest
from pathlib import Path


N = 500_000
Q = 500_000
FIXED_K = 256
RANDOM_SEED = 470


class FixedBatchCounter:
    def __init__(self, k: int) -> None:
        self.k = k
        self.groups = 0
        self.used: set[int] = set()

    def add_type1(self, x: int, y: int) -> None:
        if len(self.used) == 2 * self.k or x in self.used or y in self.used:
            self.groups += 1
            self.used.clear()
        self.used.add(x)
        self.used.add(y)

    def add_type2(self) -> None:
        if self.used:
            self.groups += 1
            self.used.clear()
        self.groups += 1

    def finish(self) -> int:
        if self.used:
            self.groups += 1
            self.used.clear()
        return self.groups


def write_permutation(path: Path, permutation: list[int]) -> None:
    with path.open("w", encoding="ascii", newline="\n") as output:
        output.write(" ".join(map(str, permutation)))
        output.write("\n")


def generate_case(output_dir: Path, name: str) -> dict[str, object]:
    input_path = output_dir / f"{name}.in"
    expected_path = output_dir / f"{name}.expected"
    p = list(range(1, N + 1))
    pinv = list(range(1, N + 1))
    inverted = False
    fixed = FixedBatchCounter(FIXED_K)
    type1_count = 0
    type2_count = 0

    with input_path.open("w", encoding="ascii", newline="\n") as output:
        output.write(f"{N} {Q}\n")
        output.write(" ".join(map(str, range(1, N + 1))))
        output.write("\n")

        def type1(x: int, y: int) -> None:
            nonlocal type1_count
            if x > y:
                x, y = y, x
            output.write(f"1 {x} {y}\n")
            if not inverted:
                a, b = p[x - 1], p[y - 1]
                p[x - 1], p[y - 1] = b, a
                pinv[a - 1], pinv[b - 1] = y, x
            else:
                a, b = pinv[x - 1], pinv[y - 1]
                pinv[x - 1], pinv[y - 1] = b, a
                p[a - 1], p[b - 1] = y, x
            fixed.add_type1(x, y)
            type1_count += 1

        def type2() -> None:
            nonlocal inverted, type2_count
            output.write("2\n")
            inverted = not inverted
            fixed.add_type2()
            type2_count += 1

        if name == "high_parallel":
            pair_count = N // 2
            for index in range(Q):
                x = 2 * (index % pair_count) + 1
                type1(x, x + 1)
        elif name == "random":
            rng = random.Random(RANDOM_SEED)
            for _ in range(Q):
                x = rng.randrange(1, N + 1)
                y = rng.randrange(1, N)
                if y >= x:
                    y += 1
                type1(x, y)
        elif name == "high_conflict":
            for _ in range(Q):
                type1(1, N)
        elif name == "interleaved_dependency":
            chain_count = N // 3
            for index in range(Q):
                chain = (index // 2) % chain_count
                a = 3 * chain + 1
                b = a + 1
                c = a + 2
                if index % 2 == 0:
                    type1(a, b)
                else:
                    type1(b, c)
        elif name == "cancellation_rich":
            # Each 10-query block reduces to identity:
            # 2,A,B,A,B,2,C,D,C,D -> 2,2 -> empty.
            pattern = [
                (2,),
                (1, 1, 2),
                (1, 3, 4),
                (1, 1, 2),
                (1, 3, 4),
                (2,),
                (1, 5, 6),
                (1, 7, 8),
                (1, 5, 6),
                (1, 7, 8),
            ]
            for index in range(Q):
                query = pattern[index % len(pattern)]
                if query[0] == 1:
                    type1(query[1], query[2])
                else:
                    type2()
        else:
            raise ValueError(f"unknown case: {name}")

    write_permutation(expected_path, pinv if inverted else p)
    return {
        "name": name,
        "input": str(input_path),
        "expected": str(expected_path),
        "n": N,
        "q": Q,
        "type1_count": type1_count,
        "type2_count": type2_count,
        "baseline_logical_clocks": Q + 2,
        "fixed_k256_logical_clocks": fixed.finish() + 2,
    }


def tokens(path: Path):
    with path.open("r", encoding="ascii") as data:
        for line in data:
            yield from line.split()


def verify(actual_path: Path, expected_path: Path) -> None:
    missing = object()
    for index, (actual, expected) in enumerate(
        zip_longest(tokens(actual_path), tokens(expected_path), fillvalue=missing),
        start=1,
    ):
        if actual != expected:
            raise SystemExit(
                f"output mismatch at token {index}: "
                f"actual={actual!r}, expected={expected!r}"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output-dir", type=Path)
    action.add_argument("--verify", nargs=2, type=Path, metavar=("ACTUAL", "EXPECTED"))
    args = parser.parse_args()

    if args.verify is not None:
        verify(args.verify[0], args.verify[1])
        return

    assert args.output_dir is not None
    args.output_dir.mkdir(parents=True, exist_ok=True)
    cases = [
        generate_case(args.output_dir, "high_parallel"),
        generate_case(args.output_dir, "random"),
        generate_case(args.output_dir, "high_conflict"),
        generate_case(args.output_dir, "interleaved_dependency"),
        generate_case(args.output_dir, "cancellation_rich"),
    ]
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

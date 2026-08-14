#!/usr/bin/env python3
"""Generate maximum-size inputs and expected outputs for K measurements."""

from __future__ import annotations

import argparse
import json
import random
from itertools import zip_longest
from pathlib import Path


N = 500_000
Q = 500_000
SEED = 470
KS = [1, 4, 8, 16, 32, 64, 128, 256, 512, 1024]


class BatchCounter:
    def __init__(self, k: int) -> None:
        self.k = k
        self.groups = 0
        self.used: set[int] = set()
        self.size = 0

    def add_type1(self, x: int, y: int) -> None:
        if self.size == self.k or x in self.used or y in self.used:
            self.groups += 1
            self.used.clear()
            self.size = 0
        self.used.add(x)
        self.used.add(y)
        self.size += 1

    def finish(self) -> int:
        if self.size:
            self.groups += 1
            self.used.clear()
            self.size = 0
        return self.groups


def write_identity(output) -> None:
    output.write(" ".join(map(str, range(1, N + 1))))
    output.write("\n")


def generate_case(output_dir: Path, name: str) -> dict[str, object]:
    input_path = output_dir / f"{name}.in"
    expected_path = output_dir / f"{name}.expected"
    counters = {k: BatchCounter(k) for k in KS if k != 1}
    permutation = list(range(1, N + 1)) if name == "random" else None

    with input_path.open("w", encoding="ascii", newline="\n") as output:
        output.write(f"{N} {Q}\n")
        write_identity(output)

        if name == "high_parallel":
            pair_count = N // 2
            for index in range(Q):
                x = 2 * (index % pair_count) + 1
                y = x + 1
                output.write(f"1 {x} {y}\n")
                for counter in counters.values():
                    counter.add_type1(x, y)
        elif name == "random":
            rng = random.Random(SEED)
            assert permutation is not None
            for _ in range(Q):
                x = rng.randrange(1, N + 1)
                y = rng.randrange(1, N)
                if y >= x:
                    y += 1
                if x > y:
                    x, y = y, x
                output.write(f"1 {x} {y}\n")
                permutation[x - 1], permutation[y - 1] = (
                    permutation[y - 1],
                    permutation[x - 1],
                )
                for counter in counters.values():
                    counter.add_type1(x, y)
        elif name == "high_conflict":
            query_line = f"1 1 {N}\n"
            for _ in range(Q):
                output.write(query_line)
                for counter in counters.values():
                    counter.add_type1(1, N)
        else:
            raise ValueError(f"unknown case: {name}")

    with expected_path.open("w", encoding="ascii", newline="\n") as expected:
        if permutation is None:
            write_identity(expected)
        else:
            expected.write(" ".join(map(str, permutation)))
            expected.write("\n")

    logical_clocks = {"1": Q + 2}
    for k, counter in counters.items():
        logical_clocks[str(k)] = counter.finish() + 2

    return {
        "name": name,
        "input": str(input_path),
        "expected": str(expected_path),
        "logical_clocks": logical_clocks,
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
    ]
    manifest = {
        "n": N,
        "q": Q,
        "random_seed": SEED,
        "k_values": KS,
        "cases": cases,
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2), encoding="utf-8", newline="\n"
    )
    print(manifest_path)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify OoO Verilog using an independent list-based semantic model."""

from __future__ import annotations

import argparse
import random
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "abc470d_out_of_order.sv"
BUILD_DIR = ROOT / "build"
ISSUE_WIDTH = 256
LOOKAHEAD = 1024

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


@dataclass
class Stats:
    query_clocks: int = 0
    issue_cycles: int = 0
    type1_executed: int = 0
    type1_canceled: int = 0
    type2_executed: int = 0
    type2_eliminated: int = 0

    @property
    def logical_clocks(self) -> int:
        return self.query_clocks + 2


def image_path(cancel: int) -> Path:
    return BUILD_DIR / f"abc470d_ooo_cancel{cancel}.vvp"


def compile_design(cancel: int) -> None:
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
        "abc470d_out_of_order",
        "-P",
        f"abc470d_out_of_order.ISSUE_WIDTH={ISSUE_WIDTH}",
        "-P",
        f"abc470d_out_of_order.LOOKAHEAD={LOOKAHEAD}",
        "-P",
        f"abc470d_out_of_order.ENABLE_CANCEL={cancel}",
        "-o",
        str(image_path(cancel)),
        str(SOURCE),
    ]
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.returncode != 0:
        raise RuntimeError(
            f"iverilog failed for cancellation={cancel}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )


def sequential_reference(initial: list[int], queries: list[Query]) -> list[int]:
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


def independent_normalize(
    pending: list[Query], stats: Stats, lookahead: int
) -> None:
    """Directly apply the specified rewrite rules until a fixed point.

    This intentionally uses list deletion and explicit semantic checks rather
    than the Verilog previous-touch/link representation.
    """
    while True:
        limit = min(lookahead, len(pending))
        changed = False

        # Delete one safe identical-swap pair, then restart on the new live list.
        for right in range(limit):
            current = pending[right]
            if current[0] != 1:
                continue
            _, x, y = current
            for left in range(right - 1, -1, -1):
                candidate = pending[left]
                if candidate[0] == 2:
                    break
                if candidate != current:
                    continue
                if all(
                    middle[0] == 1
                    and x not in middle[1:]
                    and y not in middle[1:]
                    for middle in pending[left + 1 : right]
                ):
                    del pending[right]
                    del pending[left]
                    stats.type1_canceled += 2
                    changed = True
                    break
            if changed:
                break
        if changed:
            continue

        # Delete one adjacent Type-2 pair and restart, allowing cross-kind
        # cascading such as A,2,2,A and 2,A,A,2.
        for index in range(limit - 1):
            if pending[index][0] == 2 and pending[index + 1][0] == 2:
                del pending[index : index + 2]
                stats.type2_eliminated += 2
                changed = True
                break
        if not changed:
            return


def ooo_model(
    initial: list[int],
    queries: list[Query],
    enable_cancel: bool,
    issue_width: int = ISSUE_WIDTH,
    lookahead: int = LOOKAHEAD,
) -> tuple[list[int], Stats]:
    pending = queries[:]
    permutation = initial[:]
    stats = Stats()

    while pending:
        if enable_cancel:
            independent_normalize(pending, stats, lookahead)
            if not pending:
                break

        if pending[0][0] == 2:
            inverse = [0] * len(permutation)
            for position, value in enumerate(permutation, start=1):
                inverse[value - 1] = position
            permutation = inverse
            del pending[0]
            stats.query_clocks += 1
            stats.type2_executed += 1
            continue

        touched_by_earlier: set[int] = set()
        selected: list[int] = []
        for index, query in enumerate(pending[:lookahead]):
            if query[0] == 2:
                break
            _, x, y = query
            if (
                len(selected) < issue_width
                and x not in touched_by_earlier
                and y not in touched_by_earlier
            ):
                selected.append(index)
            # Waiting queries are deliberately included in dependency history.
            touched_by_earlier.add(x)
            touched_by_earlier.add(y)

        if not selected:
            raise AssertionError("semantic scheduler made no progress")
        for index in selected:
            _, x, y = pending[index]
            permutation[x - 1], permutation[y - 1] = (
                permutation[y - 1],
                permutation[x - 1],
            )
        for index in reversed(selected):
            del pending[index]
        stats.query_clocks += 1
        stats.issue_cycles += 1
        stats.type1_executed += len(selected)

    return permutation, stats


def parse_input(input_text: str) -> tuple[list[int], list[Query]]:
    lines = input_text.strip().splitlines()
    n, q = map(int, lines[0].split())
    initial = list(map(int, lines[1].split()))
    queries = [tuple(map(int, line.split())) for line in lines[2:]]
    if len(initial) != n or len(queries) != q:
        raise AssertionError("invalid test input")
    return initial, queries


def make_input(initial: list[int], queries: list[Query]) -> str:
    lines = [f"{len(initial)} {len(queries)}", " ".join(map(str, initial))]
    lines.extend(" ".join(map(str, query)) for query in queries)
    return "\n".join(lines) + "\n"


DIAGNOSTIC = re.compile(
    r"LOGICAL_CLOCKS=(\d+) QUERY_CLOCKS=(\d+) ISSUE_CYCLES=(\d+) "
    r"TYPE1_EXECUTED=(\d+) TYPE1_CANCELED=(\d+) "
    r"TYPE2_EXECUTED=(\d+) TYPE2_ELIMINATED=(\d+) "
    r"ISSUE_WIDTH=(\d+) LOOKAHEAD=(\d+) CANCEL=(\d+)"
)


def run_design(input_text: str, cancel: int) -> tuple[list[int], Stats]:
    vvp = shutil.which("vvp")
    if vvp is None:
        raise RuntimeError("vvp was not found in PATH")
    completed = subprocess.run(
        [vvp, "-n", str(image_path(cancel))],
        input=input_text,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"vvp failed for cancellation={cancel}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    match = DIAGNOSTIC.search(completed.stderr)
    if match is None:
        raise AssertionError(f"missing diagnostic: {completed.stderr!r}")
    values = list(map(int, match.groups()))
    logical_clocks, query_clocks, issue_cycles = values[:3]
    stats = Stats(
        query_clocks=query_clocks,
        issue_cycles=issue_cycles,
        type1_executed=values[3],
        type1_canceled=values[4],
        type2_executed=values[5],
        type2_eliminated=values[6],
    )
    if logical_clocks != stats.logical_clocks:
        raise AssertionError(
            f"diagnostic clock invariant failed: {logical_clocks} != "
            f"{stats.logical_clocks}"
        )
    if values[7:] != [ISSUE_WIDTH, LOOKAHEAD, cancel]:
        raise AssertionError(f"parameter diagnostic mismatch: {values[7:]}")
    return [int(token) for token in completed.stdout.split()], stats


def check_case(name: str, initial: list[int], queries: list[Query]) -> None:
    sequential = sequential_reference(initial, queries)
    results = []
    for cancel in (0, 1):
        model_answer, model_stats = ooo_model(
            initial, queries, enable_cancel=bool(cancel)
        )
        actual_answer, actual_stats = run_design(
            make_input(initial, queries), cancel
        )
        if model_answer != sequential:
            raise AssertionError(f"Python OoO semantics failed: {name}, cancel={cancel}")
        if actual_answer != sequential:
            raise AssertionError(
                f"Verilog answer failed: {name}, cancel={cancel}\n"
                f"expected={sequential}\nactual={actual_answer}"
            )
        if actual_stats != model_stats:
            raise AssertionError(
                f"stats failed: {name}, cancel={cancel}\n"
                f"expected={model_stats}\nactual={actual_stats}"
            )
        results.append(actual_answer)
    if results[0] != results[1]:
        raise AssertionError(f"OFF/ON output mismatch: {name}")


def special_cases() -> list[tuple[str, list[int], list[Query]]]:
    independent_257 = [(1, 2 * i + 1, 2 * i + 2) for i in range(257)]
    inside_fill = [(1, 2 * i + 3, 2 * i + 4) for i in range(1022)]
    outside_fill = [(1, 2 * i + 3, 2 * i + 4) for i in range(1023)]
    return [
        ("minimum swap", [1, 2], [(1, 1, 2)]),
        ("minimum inverse", [2, 1], [(2,)]),
        (
            "OoO skips waiting but not its dependent",
            list(range(1, 9)),
            [(1, 1, 2), (1, 2, 3), (1, 4, 5), (1, 3, 6), (1, 7, 8)],
        ),
        (
            "multi-level dependency chain",
            list(range(1, 13)),
            [
                (1, 1, 2),
                (1, 2, 3),
                (1, 4, 5),
                (1, 3, 6),
                (1, 7, 8),
                (1, 6, 9),
                (1, 10, 11),
            ],
        ),
        (
            "Type 2 barrier",
            list(range(1, 11)),
            [(1, 1, 2), (1, 2, 3), (1, 4, 5), (2,), (1, 6, 7), (1, 8, 9)],
        ),
        ("issue width 256 boundary", list(range(1, 515)), independent_257),
        (
            "safe identical cancellation",
            list(range(1, 7)),
            [(1, 1, 2), (1, 3, 4), (1, 1, 2)],
        ),
        (
            "unsafe touched position",
            list(range(1, 5)),
            [(1, 1, 2), (1, 2, 3), (1, 1, 2)],
        ),
        (
            "unsafe across Type 2",
            list(range(1, 5)),
            [(1, 1, 2), (2,), (1, 1, 2)],
        ),
        (
            "Type 1 cascading A B B A",
            list(range(1, 7)),
            [(1, 1, 2), (1, 3, 4), (1, 3, 4), (1, 1, 2)],
        ),
        ("Type 2 even", [2, 3, 1], [(2,), (2,)]),
        ("Type 2 odd", [2, 3, 1], [(2,), (2,), (2,)]),
        (
            "Type 1 exposes Type 2 pair",
            list(range(1, 5)),
            [(2,), (1, 1, 2), (1, 1, 2), (2,)],
        ),
        (
            "Type 2 exposes Type 1 pair",
            list(range(1, 5)),
            [(1, 1, 2), (2,), (2,), (1, 1, 2)],
        ),
        (
            "same swap inside lookahead",
            list(range(1, 2050)),
            [(1, 1, 2)] + inside_fill + [(1, 1, 2)],
        ),
        (
            "same swap initially outside lookahead",
            list(range(1, 2052)),
            [(1, 1, 2)] + outside_fill + [(1, 1, 2)],
        ),
        (
            "many execution holes",
            list(range(1, 65)),
            [
                query
                for i in range(1, 31)
                for query in ((1, 1, 2), (1, 2, 3), (1, 2 * i + 3, 2 * i + 4))
            ],
        ),
    ]


def random_cases(seed: int, count: int) -> list[tuple[list[int], list[Query]]]:
    rng = random.Random(seed)
    cases = []
    for _ in range(count):
        n = rng.randint(2, 40)
        q = rng.randint(1, 120)
        initial = list(range(1, n + 1))
        rng.shuffle(initial)
        queries: list[Query] = []
        for _ in range(q):
            if rng.random() < 0.78:
                x, y = sorted(rng.sample(range(1, n + 1), 2))
                queries.append((1, x, y))
            else:
                queries.append((2,))
        cases.append((initial, queries))
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--random-cases", type=int, default=300)
    parser.add_argument("--seed", type=int, default=470)
    args = parser.parse_args()

    compile_design(0)
    compile_design(1)

    for index, (input_text, expected) in enumerate(SAMPLES, start=1):
        initial, queries = parse_input(input_text)
        if sequential_reference(initial, queries) != expected:
            raise AssertionError(f"embedded official sample {index} is invalid")
        check_case(f"official sample {index}", initial, queries)

    specials = special_cases()
    for name, initial, queries in specials:
        check_case(name, initial, queries)

    generated = random_cases(args.seed, args.random_cases)
    for index, (initial, queries) in enumerate(generated):
        check_case(f"random case {index}", initial, queries)

    print(
        f"PASS: cancellation OFF/ON, 3 samples, {len(specials)} special, "
        f"{args.random_cases} random (seed={args.seed})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

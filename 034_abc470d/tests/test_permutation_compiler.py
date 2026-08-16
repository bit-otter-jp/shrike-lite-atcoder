#!/usr/bin/env python3
"""Validate the permutation compiler against independent Python semantics."""

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
SV_SOURCE = ROOT / "abc470d_permutation_compiler.sv"
HS_SOURCE = ROOT / "abc470d_permutation_compiler.hs"
BUILD_DIR = ROOT / "build"
SV_IMAGE = BUILD_DIR / "abc470d_permutation_compiler.vvp"
HS_BUILD_DIR = BUILD_DIR / "haskell_permutation_compiler"
HS_IMAGE = HS_BUILD_DIR / (
    "abc470d_permutation_compiler.exe"
    if sys.platform == "win32"
    else "abc470d_permutation_compiler"
)

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

DIAGNOSTIC = re.compile(
    r"LOGICAL_CLOCKS=(\d+) TYPE1_COUNT=(\d+) TYPE2_COUNT=(\d+) "
    r"FINAL_INVERTED=(\d+)"
)


@dataclass(frozen=True)
class CompilerStats:
    type1_count: int
    type2_count: int
    final_inverted: int


def compile_systemverilog() -> None:
    iverilog = shutil.which("iverilog")
    if iverilog is None:
        raise RuntimeError("iverilog was not found in PATH")
    BUILD_DIR.mkdir(exist_ok=True)
    completed = subprocess.run(
        [
            iverilog,
            "-g2012",
            "-Wall",
            "-DONLINE_JUDGE",
            "-DATCODER",
            "-s",
            "abc470d_permutation_compiler",
            "-o",
            str(SV_IMAGE),
            str(SV_SOURCE),
        ],
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "iverilog failed\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )


def compile_haskell(required: bool) -> bool:
    ghc = shutil.which("ghc")
    if ghc is None:
        if required:
            raise RuntimeError("--require-haskell was set but ghc was not found")
        return False
    HS_BUILD_DIR.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [
            ghc,
            "-O1",
            "-Wall",
            "-outputdir",
            str(HS_BUILD_DIR),
            "-o",
            str(HS_IMAGE),
            str(HS_SOURCE),
        ],
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "ghc failed\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return True


def validate_haskell_source_contract() -> None:
    source = HS_SOURCE.read_text(encoding="utf-8")
    required_names = [
        "Permutation",
        "identity",
        "inverseMapping",
        "composeByInputTransposition",
        "composeByOutputTransposition",
        "CompilerState",
        "compileQuery",
        "foldl'",
        "materialize",
    ]
    missing = [name for name in required_names if name not in source]
    if missing:
        raise AssertionError(f"Haskell reference is missing abstractions: {missing}")


def sequential_reference(initial: list[int], queries: list[Query]) -> list[int]:
    """Directly execute the ABC470D definition; no U/V representation."""
    current = initial[:]
    for query in queries:
        if query[0] == 1:
            _, x, y = query
            current[x - 1], current[y - 1] = current[y - 1], current[x - 1]
        else:
            inverse = [0] * len(current)
            for position, value in enumerate(current, start=1):
                inverse[value - 1] = position
            current = inverse
    return current


def materialize_compiler(
    p: list[int],
    u: list[int],
    v: list[int],
    vinv: list[int],
    inverted: bool,
) -> list[int]:
    n = len(p) - 1
    if not inverted:
        return [u[p[v[i]]] for i in range(1, n + 1)]
    answer = [0] * (n + 1)
    for k in range(1, n + 1):
        answer[u[p[k]]] = vinv[k]
    return answer[1:]


def compiler_model(
    initial: list[int], queries: list[Query], check_every_step: bool = True
) -> tuple[list[int], CompilerStats]:
    """Mathematical array model with exhaustive invariants on small tests."""
    n = len(initial)
    p = [0] + initial
    u = list(range(n + 1))
    uinv = list(range(n + 1))
    v = list(range(n + 1))
    vinv = list(range(n + 1))
    inverted = False
    type1_count = 0
    type2_count = 0
    sequential_prefix = initial[:]

    for query in queries:
        if query[0] == 1:
            type1_count += 1
            _, x, y = query
            sequential_prefix[x - 1], sequential_prefix[y - 1] = (
                sequential_prefix[y - 1],
                sequential_prefix[x - 1],
            )
            if not inverted:
                a, b = v[x], v[y]
                v[x], v[y] = b, a
                vinv[a], vinv[b] = y, x
            else:
                px, py = uinv[x], uinv[y]
                u[px], u[py] = y, x
                uinv[x], uinv[y] = py, px
        else:
            type2_count += 1
            inverse = [0] * n
            for position, value in enumerate(sequential_prefix, start=1):
                inverse[value - 1] = position
            sequential_prefix = inverse
            inverted = not inverted

        if check_every_step:
            expected_domain = set(range(1, n + 1))
            if set(u[1:]) != expected_domain or set(v[1:]) != expected_domain:
                raise AssertionError("compiler forward mapping stopped being a permutation")
            for index in range(1, n + 1):
                if uinv[u[index]] != index or u[uinv[index]] != index:
                    raise AssertionError("U/Uinv invariant failed")
                if vinv[v[index]] != index or v[vinv[index]] != index:
                    raise AssertionError("V/Vinv invariant failed")
            compiled_prefix = materialize_compiler(p, u, v, vinv, inverted)
            if compiled_prefix != sequential_prefix:
                raise AssertionError(
                    "compiler representation invariant failed\n"
                    f"query={query}\nexpected={sequential_prefix}\n"
                    f"compiled={compiled_prefix}"
                )

    return (
        materialize_compiler(p, u, v, vinv, inverted),
        CompilerStats(type1_count, type2_count, int(inverted)),
    )


def make_input(initial: list[int], queries: list[Query]) -> str:
    lines = [f"{len(initial)} {len(queries)}", " ".join(map(str, initial))]
    lines.extend(" ".join(map(str, query)) for query in queries)
    return "\n".join(lines) + "\n"


def parse_input(input_text: str) -> tuple[list[int], list[Query]]:
    lines = input_text.strip().splitlines()
    n, q = map(int, lines[0].split())
    initial = list(map(int, lines[1].split()))
    queries = [tuple(map(int, line.split())) for line in lines[2:]]
    if len(initial) != n or len(queries) != q:
        raise AssertionError("invalid embedded input")
    return initial, queries


def run_systemverilog(input_text: str) -> tuple[list[int], CompilerStats]:
    vvp = shutil.which("vvp")
    if vvp is None:
        raise RuntimeError("vvp was not found in PATH")
    completed = subprocess.run(
        [vvp, "-n", str(SV_IMAGE)],
        input=input_text,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"vvp failed\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    match = DIAGNOSTIC.search(completed.stderr)
    if match is None:
        raise AssertionError(f"missing compiler diagnostic: {completed.stderr!r}")
    clocks, type1_count, type2_count, final_inverted = map(int, match.groups())
    if clocks != 1:
        raise AssertionError(f"logical clock must be 1, got {clocks}")
    return (
        [int(token) for token in completed.stdout.split()],
        CompilerStats(type1_count, type2_count, final_inverted),
    )


def run_haskell(input_text: str) -> list[int]:
    completed = subprocess.run(
        [str(HS_IMAGE)],
        input=input_text,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise AssertionError(
            "Haskell reference failed\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return [int(token) for token in completed.stdout.split()]


def check_case(
    name: str,
    initial: list[int],
    queries: list[Query],
    has_haskell: bool,
) -> None:
    expected = sequential_reference(initial, queries)
    compiled, expected_stats = compiler_model(initial, queries)
    input_text = make_input(initial, queries)
    actual, actual_stats = run_systemverilog(input_text)
    if compiled != expected:
        raise AssertionError(f"Python compiler mismatch: {name}")
    if actual != expected:
        raise AssertionError(
            f"SystemVerilog mismatch: {name}\nexpected={expected}\nactual={actual}"
        )
    if actual_stats != expected_stats:
        raise AssertionError(
            f"diagnostic mismatch: {name}\n"
            f"expected={expected_stats}\nactual={actual_stats}"
        )
    if has_haskell:
        haskell = run_haskell(input_text)
        if haskell != expected:
            raise AssertionError(
                f"Haskell mismatch: {name}\nexpected={expected}\nactual={haskell}"
            )


def special_cases() -> list[tuple[str, list[int], list[Query]]]:
    identity_12 = list(range(1, 13))
    return [
        ("minimum swap", [1, 2], [(1, 1, 2)]),
        ("minimum Type 2", [2, 1], [(2,)]),
        ("Type 1 only", [4, 1, 5, 2, 3], [(1, 1, 5), (1, 2, 4)]),
        ("Type 2 only odd", [2, 3, 1], [(2,)] * 5),
        ("Type 2 only even", [2, 3, 1], [(2,)] * 6),
        (
            "swaps around inversion",
            [4, 1, 5, 2, 3],
            [(1, 1, 5), (2,), (1, 2, 4), (2,), (1, 1, 3)],
        ),
        ("same swap repeated", [3, 1, 4, 2], [(1, 1, 4)] * 11),
        (
            "strong dependency",
            [6, 2, 5, 1, 4, 3],
            [(1, 1, 2), (1, 2, 3)] * 9,
        ),
        ("three cycle", [3, 1, 2], [(1, 1, 2), (1, 2, 3)]),
        (
            "n cycle",
            list(range(8, 0, -1)),
            [(1, index, index + 1) for index in range(1, 8)],
        ),
        (
            "cancellation possible",
            [2, 1, 4, 3, 6, 5],
            [(1, 1, 2), (1, 3, 4), (1, 1, 2)],
        ),
        (
            "cancellation impossible",
            [2, 1, 4, 3],
            [(1, 1, 2), (1, 2, 3), (1, 1, 2)],
        ),
        (
            "interleaved dependency",
            identity_12,
            [
                (1, 1, 2),
                (1, 2, 3),
                (1, 4, 5),
                (1, 5, 6),
                (1, 7, 8),
                (1, 8, 9),
            ],
        ),
        (
            "cancellation rich",
            identity_12,
            [
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
            ],
        ),
        (
            "alternating inversions and dependent swaps",
            identity_12,
            [(2,), (1, 1, 2), (1, 2, 3), (2,), (1, 1, 2)] * 7,
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
            if rng.random() < 0.72:
                x, y = rng.sample(range(1, n + 1), 2)
                queries.append((1, x, y))
            else:
                queries.append((2,))
        cases.append((initial, queries))
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--random-cases", type=int, default=300)
    parser.add_argument("--seed", type=int, default=470)
    parser.add_argument("--require-haskell", action="store_true")
    args = parser.parse_args()

    compile_systemverilog()
    validate_haskell_source_contract()
    has_haskell = compile_haskell(args.require_haskell)

    for index, (input_text, sample_answer) in enumerate(SAMPLES, start=1):
        initial, queries = parse_input(input_text)
        if sequential_reference(initial, queries) != sample_answer:
            raise AssertionError(f"embedded official sample {index} is invalid")
        check_case(f"official sample {index}", initial, queries, has_haskell)

    specials = special_cases()
    for name, initial, queries in specials:
        check_case(name, initial, queries, has_haskell)

    for index, (initial, queries) in enumerate(
        random_cases(args.seed, args.random_cases)
    ):
        check_case(f"random case {index}", initial, queries, has_haskell)

    haskell_status = "executed" if has_haskell else "skipped (ghc not found)"
    print(
        f"PASS: 3 samples, {len(specials)} special, "
        f"{args.random_cases} random (seed={args.seed}); Haskell {haskell_status}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())


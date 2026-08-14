#!/usr/bin/env python3
"""Generate and verify the deterministic maximum-size performance case."""

from __future__ import annotations

import argparse
from pathlib import Path


N = 500_000
Q = 500_000


def generate(path: Path) -> None:
    # Repeating the endpoint swap an even number of times returns to identity,
    # while exercising the four-array-write type-1 path on every query clock.
    with path.open("w", encoding="ascii", newline="\n") as output:
        output.write(f"{N} {Q}\n")
        output.write(" ".join(map(str, range(1, N + 1))))
        output.write("\n")
        query_line = f"1 1 {N}\n"
        for _ in range(Q):
            output.write(query_line)


def verify(path: Path) -> None:
    token_count = 0
    with path.open("r", encoding="ascii") as output:
        for token in output.read().split():
            token_count += 1
            if int(token) != token_count:
                raise SystemExit(
                    f"maximum output mismatch at position {token_count}: {token}"
                )
    if token_count != N:
        raise SystemExit(f"maximum output length is {token_count}, expected {N}")


def main() -> None:
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--generate", type=Path, metavar="PATH")
    action.add_argument("--verify", type=Path, metavar="PATH")
    args = parser.parse_args()

    if args.generate is not None:
        generate(args.generate)
    else:
        verify(args.verify)


if __name__ == "__main__":
    main()

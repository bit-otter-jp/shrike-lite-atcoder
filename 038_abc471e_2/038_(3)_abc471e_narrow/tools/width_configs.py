#!/usr/bin/env python3
"""Generate and independently validate the WIDTH sweep configuration."""

from __future__ import annotations

import argparse
import json
import math


def is_prime(value: int) -> bool:
    if value < 2:
        return False
    if value % 2 == 0:
        return value == 2
    limit = math.isqrt(value)
    divisor = 3
    while divisor <= limit:
        if value % divisor == 0:
            return False
        divisor += 2
    return True


def largest_prime_below(limit: int) -> int:
    candidate = limit - 1
    if candidate > 2 and candidate % 2 == 0:
        candidate -= 1
    while not is_prime(candidate):
        candidate -= 2
    return candidate


def configurations(first: int = 8, last: int = 16) -> list[dict[str, int | bool]]:
    result: list[dict[str, int | bool]] = []
    for width in range(first, last + 1):
        modulus = largest_prime_below(1 << width)
        result.append(
            {
                "width": width,
                "mod": modulus,
                "n_max": modulus - 1,
                "prime_verified": is_prime(modulus),
            }
        )
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args()
    rows = configurations()
    if not all(row["prime_verified"] for row in rows):
        raise SystemExit("internal prime verification failed")
    if args.json:
        print(json.dumps(rows, indent=2))
        return
    print("WIDTH\tMOD\tN_MAX\tPRIME_VERIFIED")
    for row in rows:
        print(
            f"{row['width']}\t{row['mod']}\t{row['n_max']}\t"
            f"{str(row['prime_verified']).lower()}"
        )


if __name__ == "__main__":
    main()

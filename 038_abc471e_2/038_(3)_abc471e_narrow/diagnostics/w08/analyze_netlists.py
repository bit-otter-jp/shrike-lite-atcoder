#!/usr/bin/env python3
"""Structural comparison of flattened Forge/Yosys post-synthesis netlists."""

from __future__ import annotations

import csv
import json
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
PRIMITIVES = (
    "CARRY4",
    "FDCE",
    "FDPE",
    "INV",
    "LUT2",
    "LUT3",
    "LUT4",
    "LUT5",
    "LUT6",
    "MUXF7",
    "MUXF8",
)
FF_TYPES = {"FDCE", "FDPE"}
COMB_TYPES = {"INV", "LUT2", "LUT3", "LUT4", "LUT5", "LUT6", "MUXF7", "MUXF8", "CARRY4"}
OUTPUT_PORTS = {
    "FDCE": {"Q"},
    "FDPE": {"Q"},
    "INV": {"O"},
    "LUT2": {"O"},
    "LUT3": {"O"},
    "LUT4": {"O"},
    "LUT5": {"O"},
    "LUT6": {"O"},
    "MUXF7": {"O"},
    "MUXF8": {"O"},
    "CARRY4": {"O", "CO"},
}


CONNECTION_RE = re.compile(r"\.(?P<port>[A-Za-z0-9_]+)\s*\((?P<expr>.*?)\)(?:,|\s*$)", re.DOTALL)
TOKEN_RE = re.compile(r"\\[^\s,{}()]+|[A-Za-z_$][\w$]*(?:\[[^\]]+\])?")
SRC_RE = re.compile(r'src\s*=\s*"([^"]+)"')
MAIN_LINE_RE = re.compile(r"main\.v:(\d+)")


def source_line(source: str, needle: str) -> int | None:
    for index, line in enumerate(source.splitlines(), 1):
        if needle in line:
            return index
    return None


def source_category(src: str, multiplier_start: int | None, top_add_start: int | None, top_add_end: int | None) -> str:
    if "spi_target.v:" in src:
        return "spi_target"
    main_lines = [int(value) for value in MAIN_LINE_RE.findall(src)]
    if multiplier_start is not None and any(line >= multiplier_start for line in main_lines):
        return "shared_multiplier"
    if top_add_start is not None and top_add_end is not None and any(top_add_start <= line <= top_add_end for line in main_lines):
        return "top_add_sub"
    if main_lines:
        return "top_protocol_control"
    return "mapping_library_only"


def tokens(expr: str) -> list[str]:
    result = []
    for token in TOKEN_RE.findall(expr):
        if token in {"h0", "h1", "x"} or token[0].isdigit():
            continue
        result.append(token)
    return result


def parse_launches(source: str) -> dict[str, object]:
    lines = source.splitlines()
    launches: list[tuple[str, str]] = []
    for index, line in enumerate(lines):
        if re.search(r"mul_start\s*<=\s*1'b1", line):
            lhs = "?"
            rhs = "?"
            for previous in reversed(lines[max(0, index - 8):index]):
                lhs_match = re.search(r"mul_lhs\s*<=\s*(.+?);", previous)
                rhs_match = re.search(r"mul_rhs\s*<=\s*(.+?);", previous)
                if lhs == "?" and lhs_match:
                    lhs = lhs_match.group(1).strip()
                if rhs == "?" and rhs_match:
                    rhs = rhs_match.group(1).strip()
            launches.append((lhs, rhs))
    return {
        "launch_states": len(launches),
        "lhs_sources": sorted({lhs for lhs, _ in launches}),
        "rhs_sources": sorted({rhs for _, rhs in launches}),
        "unique_lhs_sources": len({lhs for lhs, _ in launches}),
        "unique_rhs_sources": len({rhs for _, rhs in launches}),
    }


def parse_instances(netlist: str) -> list[dict[str, object]]:
    """Parse both parameterized and unparameterized Xilinx primitives."""
    lines = netlist.splitlines()
    instances: list[dict[str, object]] = []
    index = 0
    primitive_pattern = "|".join(PRIMITIVES)
    while index < len(lines):
        head = re.match(rf"^\s*(?P<type>{primitive_pattern})\b(?P<tail>.*)$", lines[index])
        if not head:
            index += 1
            continue

        attrs: list[str] = []
        back = index - 1
        while back >= 0 and (not lines[back].strip() or lines[back].lstrip().startswith("(*")):
            if lines[back].lstrip().startswith("(*"):
                attrs.append(lines[back])
            back -= 1
        attrs.reverse()

        tail = head.group("tail").strip()
        name: str | None = None
        connection_start = index
        direct = re.match(r"(?P<name>\\[^\s]+|[A-Za-z_$][\w$]*)\s*\($", tail)
        if direct:
            name = direct.group("name")
        elif tail.startswith("#("):
            probe = index + 1
            while probe < len(lines):
                parameter_end = re.match(
                    r"^\s*\)\s+(?P<name>\\[^\s]+|[A-Za-z_$][\w$]*)\s+\($",
                    lines[probe],
                )
                if parameter_end:
                    name = parameter_end.group("name")
                    connection_start = probe
                    break
                probe += 1
        if name is None:
            index += 1
            continue

        end = connection_start + 1
        while end < len(lines) and not re.match(r"^\s*\);\s*$", lines[end]):
            end += 1
        body = "\n".join(lines[connection_start + 1:end])
        attrs_text = "\n".join(attrs)
        src_matches = SRC_RE.findall(attrs_text)
        instances.append(
            {
                "type": head.group("type"),
                "name": name,
                "src": "|".join(src_matches),
                "connections": {
                    item.group("port"): item.group("expr").strip()
                    for item in CONNECTION_RE.finditer(body)
                },
            }
        )
        index = end + 1
    return instances


def analyze(name: str, netlist_path: Path, source_path: Path) -> dict[str, object]:
    netlist = netlist_path.read_text(encoding="utf-8", errors="replace")
    source = source_path.read_text(encoding="utf-8", errors="replace")
    multiplier_start = source_line(source, "module modular_multiplier")
    top_add_start = source_line(source, "mod_arith_b_selected")
    top_add_end = source_line(source, "wire [31:0] mod_wide")
    if top_add_end is not None:
        top_add_end -= 1

    instances = parse_instances(netlist)
    for instance in instances:
        instance["category"] = source_category(
            str(instance["src"]), multiplier_start, top_add_start, top_add_end
        )

    driver: dict[str, tuple[str, str]] = {}
    instance_by_name = {str(instance["name"]): instance for instance in instances}
    for instance in instances:
        primitive = str(instance["type"])
        for port in OUTPUT_PORTS[primitive]:
            expr = dict(instance["connections"]).get(port)
            if expr:
                for token in tokens(expr):
                    driver[token] = (primitive, str(instance["name"]))

    ff_driver_types: Counter[str] = Counter()
    ff_driver_instances: set[str] = set()
    top_ff_driver_instances: set[str] = set()
    multiplier_ff_driver_types: Counter[str] = Counter()
    multiplier_ff_driver_instances: set[str] = set()
    multiplier_ff_shallow_instances: set[str] = set()
    ff_categories: Counter[str] = Counter()
    carry_categories: Counter[str] = Counter()
    for instance in instances:
        primitive = str(instance["type"])
        category = str(instance["category"])
        if primitive == "CARRY4":
            carry_categories[category] += 1
        if primitive in FF_TYPES:
            ff_categories[category] += 1
            d_expr = dict(instance["connections"]).get("D", "")
            d_tokens = tokens(d_expr)
            direct = driver.get(d_tokens[0]) if len(d_tokens) == 1 else None
            driver_type = direct[0] if direct else "other_or_direct"
            ff_driver_types[driver_type] += 1
            if direct:
                ff_driver_instances.add(direct[1])
                if category.startswith("top_") and direct[0] in {
                    "LUT2", "LUT3", "LUT4", "LUT5", "LUT6", "MUXF7", "MUXF8"
                }:
                    top_ff_driver_instances.add(direct[1])
            if category == "shared_multiplier":
                multiplier_ff_driver_types[driver_type] += 1
                if direct:
                    multiplier_ff_driver_instances.add(direct[1])
                    multiplier_ff_shallow_instances.add(direct[1])
                    direct_instance = instance_by_name.get(direct[1])
                    if direct_instance:
                        for upstream_port, upstream_expr in dict(direct_instance["connections"]).items():
                            if upstream_port in OUTPUT_PORTS[str(direct_instance["type"])]:
                                continue
                            for upstream_token in tokens(upstream_expr):
                                upstream = driver.get(upstream_token)
                                if upstream and upstream[0] in COMB_TYPES:
                                    multiplier_ff_shallow_instances.add(upstream[1])

    fanout: Counter[str] = Counter()
    for instance in instances:
        primitive = str(instance["type"])
        for port, expr in dict(instance["connections"]).items():
            if port in OUTPUT_PORTS[primitive]:
                continue
            for token in tokens(expr):
                if token not in {"clk", "rst_n"}:
                    fanout[token] += 1

    top_add_neighbor_lut_mux: set[str] = set()
    for instance in instances:
        if instance["type"] != "CARRY4" or instance["category"] != "top_add_sub":
            continue
        for port, expr in dict(instance["connections"]).items():
            if port in OUTPUT_PORTS["CARRY4"]:
                continue
            for token in tokens(expr):
                upstream = driver.get(token)
                if upstream and upstream[0] in {
                    "LUT2", "LUT3", "LUT4", "LUT5", "LUT6", "MUXF7", "MUXF8"
                }:
                    top_add_neighbor_lut_mux.add(upstream[1])

    filtered_fanout = [
        count for net, count in fanout.items()
        if net not in {"rst_n_INV_I_O", "\\u_spi_target.o_rx_data"}
    ]

    launches = parse_launches(source)
    result: dict[str, object] = {
        "diagnostic": name,
        "primitive_instances_parsed": len(instances),
        "source_boundaries": {
            "multiplier_module_line": multiplier_start,
            "top_add_start_line": top_add_start,
            "top_add_end_line": top_add_end,
        },
        "ff_by_source_category": dict(sorted(ff_categories.items())),
        "carry4_by_source_category": dict(sorted(carry_categories.items())),
        "ff_direct_driver_type": dict(sorted(ff_driver_types.items())),
        "ff_direct_unique_combinational_drivers": len(ff_driver_instances),
        "top_ff_direct_unique_lut_mux_drivers": len(top_ff_driver_instances),
        "multiplier_ff_direct_driver_type": dict(sorted(multiplier_ff_driver_types.items())),
        "multiplier_ff_direct_unique_drivers": len(multiplier_ff_driver_instances),
        "multiplier_ff_shallow_cone_depth2_unique_primitives": len(multiplier_ff_shallow_instances),
        "top_add_sub_input_neighbor_unique_lut_mux": len(top_add_neighbor_lut_mux),
        "max_nonreset_nonraw_rx_fanout": max(filtered_fanout, default=0),
        "high_fanout_nonclock_nets": [
            {"net": net, "primitive_input_uses": count}
            for net, count in fanout.most_common(12)
        ],
        **launches,
    }
    return result


def main() -> None:
    designs = [
        (
            "W08_BASELINE",
            ROOT / "experiments/w08/post_synth_results.v",
            ROOT / "ffpga/src/main.v",
        ),
        (
            "coefficient_pow_fixed",
            OUT / "coefficient_pow_fixed/post_synth_results.v",
            OUT / "coefficient_pow_fixed/main.v",
        ),
        (
            "input_only",
            OUT / "input_only/post_synth_results.v",
            OUT / "input_only/main.v",
        ),
        (
            "protocol_only",
            OUT / "protocol_only/post_synth_results.v",
            OUT / "protocol_only/main.v",
        ),
    ]
    results = [analyze(*design) for design in designs]
    (OUT / "netlist_analysis.json").write_text(
        json.dumps(results, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    fields = [
        "diagnostic",
        "launch_states",
        "unique_lhs_sources",
        "unique_rhs_sources",
        "multiplier_ff",
        "multiplier_carry4",
        "top_add_sub_carry4",
        "spi_target_ff",
        "top_protocol_control_ff",
        "ff_direct_unique_combinational_drivers",
        "top_ff_direct_unique_lut_mux_drivers",
        "multiplier_ff_direct_unique_drivers",
        "multiplier_ff_shallow_cone_depth2_unique_primitives",
        "top_add_sub_input_neighbor_unique_lut_mux",
        "max_nonreset_nonraw_rx_fanout",
    ]
    with (OUT / "netlist_analysis_summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for result in results:
            ff = result["ff_by_source_category"]
            carry = result["carry4_by_source_category"]
            writer.writerow(
                {
                    "diagnostic": result["diagnostic"],
                    "launch_states": result["launch_states"],
                    "unique_lhs_sources": result["unique_lhs_sources"],
                    "unique_rhs_sources": result["unique_rhs_sources"],
                    "multiplier_ff": ff.get("shared_multiplier", 0),
                    "multiplier_carry4": carry.get("shared_multiplier", 0),
                    "top_add_sub_carry4": carry.get("top_add_sub", 0),
                    "spi_target_ff": ff.get("spi_target", 0),
                    "top_protocol_control_ff": ff.get("top_protocol_control", 0),
                    "ff_direct_unique_combinational_drivers": result["ff_direct_unique_combinational_drivers"],
                    "top_ff_direct_unique_lut_mux_drivers": result["top_ff_direct_unique_lut_mux_drivers"],
                    "multiplier_ff_direct_unique_drivers": result["multiplier_ff_direct_unique_drivers"],
                    "multiplier_ff_shallow_cone_depth2_unique_primitives": result["multiplier_ff_shallow_cone_depth2_unique_primitives"],
                    "top_add_sub_input_neighbor_unique_lut_mux": result["top_add_sub_input_neighbor_unique_lut_mux"],
                    "max_nonreset_nonraw_rx_fanout": result["max_nonreset_nonraw_rx_fanout"],
                }
            )

    comparison = json.loads((OUT / "resource_comparison.json").read_text(encoding="utf-8-sig"))
    indexed = {row["diagnostic"]: row for row in comparison}
    diff_specs = [
        ("coefficient_pow_aggregate", "W08_BASELINE", "coefficient_pow_fixed"),
        ("final_aggregate", "coefficient_pow_fixed", "input_only"),
        ("input_arithmetic_aggregate", "input_only", "protocol_only"),
    ]
    diff_fields = [
        "wires", "wire_bits", "cells", "CARRY4", "FDCE", "FDPE", "ff_total", "INV",
        "LUT2", "LUT3", "LUT4", "LUT5", "LUT6", "lut_total", "MUXF7", "MUXF8",
        "lut_mux_total",
    ]
    diffs = []
    for label, minuend_name, subtrahend_name in diff_specs:
        minuend = indexed[minuend_name]
        subtrahend = indexed[subtrahend_name]
        row = {
            "aggregate": label,
            "definition": f"{minuend_name} - {subtrahend_name}",
        }
        row.update({field: int(minuend[field]) - int(subtrahend[field]) for field in diff_fields})
        diffs.append(row)
    (OUT / "aggregate_differences.json").write_text(
        json.dumps(diffs, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    with (OUT / "aggregate_differences.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(diffs[0]))
        writer.writeheader()
        writer.writerows(diffs)
    print(json.dumps(results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

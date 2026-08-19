#!/usr/bin/env python3
"""Summarize compact_v3 synthesis checkpoints and netlist structure."""

from __future__ import annotations

import csv
import importlib.util
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = Path(__file__).resolve().parent
DIAGNOSTIC_SCRIPT = ROOT / "diagnostics" / "w08" / "analyze_netlists.py"


def load_diagnostic_module():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("w08_netlist_diagnostic", DIAGNOSTIC_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {DIAGNOSTIC_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def top_module_end(netlist: Path) -> int:
    text = netlist.read_text(encoding="utf-8", errors="replace")
    match = re.search(r'main\.v:1\.\d+-(\d+)\.\d+', text)
    if not match:
        raise RuntimeError(f"top module source range not found in {netlist}")
    return int(match.group(1))


def analyze_with_source_ranges(diag, name: str, netlist: Path, source: Path):
    cutoff = top_module_end(netlist)
    source_text = source.read_text(encoding="utf-8")
    add_start = diag.source_line(source_text, "wire [WIDTH:0] alu_add_wide")
    add_end = diag.source_line(source_text, "wire [WIDTH-1:0] alu_result")

    def category(src, _multiplier_start, _top_add_start, _top_add_end):
        if "spi_target.v:" in src:
            return "spi_target"
        main_lines = [int(value) for value in diag.MAIN_LINE_RE.findall(src)]
        if any(line > cutoff for line in main_lines):
            return "shared_multiplier"
        if (add_start is not None and add_end is not None and
                any(add_start <= line <= add_end for line in main_lines)):
            return "top_add_sub"
        if main_lines:
            return "top_protocol_control"
        return "mapping_library_only"

    original = diag.source_category
    diag.source_category = category
    try:
        return diag.analyze(name, netlist, source)
    finally:
        diag.source_category = original


def compact_operand_sources(source: Path) -> tuple[list[str], list[str]]:
    text = source.read_text(encoding="utf-8")
    start = text.index("case (mul_context)")
    end = text.index("endcase", start)
    block = text[start:end]
    lhs = sorted(set(re.findall(r"mul_lhs\s*=\s*([^;]+);", block)))
    rhs = sorted(set(re.findall(r"mul_rhs\s*=\s*([^;]+);", block)))
    return lhs, rhs


def structural_row(result: dict[str, object]) -> dict[str, object]:
    ff = result["ff_by_source_category"]
    carry = result["carry4_by_source_category"]
    return {
        "design": result["diagnostic"],
        "launch_sites": result["launch_states"],
        "unique_lhs_sources": result["unique_lhs_sources"],
        "unique_rhs_sources": result["unique_rhs_sources"],
        "multiplier_ff": ff.get("shared_multiplier", 0),
        "multiplier_carry4": carry.get("shared_multiplier", 0),
        "top_protocol_control_ff": ff.get("top_protocol_control", 0),
        "top_ff_direct_unique_lut_mux_drivers": result["top_ff_direct_unique_lut_mux_drivers"],
        "all_ff_direct_unique_combinational_drivers": result["ff_direct_unique_combinational_drivers"],
        "multiplier_ff_direct_unique_drivers": result["multiplier_ff_direct_unique_drivers"],
        "multiplier_depth2_unique_primitives": result["multiplier_ff_shallow_cone_depth2_unique_primitives"],
        "max_nonreset_nonraw_rx_fanout": result["max_nonreset_nonraw_rx_fanout"],
    }


def write_table(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    diag = load_diagnostic_module()
    baseline_netlist = ROOT / "experiments" / "w08" / "post_synth_results.v"
    compact_netlist = OUT / "w8" / "post_synth_results.v"
    baseline_source = ROOT / "ffpga" / "src" / "main.v"
    compact_source = OUT / "main.v"

    baseline = diag.analyze(
        "W08_BASELINE", baseline_netlist, baseline_source
    )
    compact = analyze_with_source_ranges(
        diag, "compact_v3_w8", compact_netlist, compact_source
    )
    lhs, rhs = compact_operand_sources(compact_source)
    compact["launch_states"] = len(re.findall(
        r"mul_start\s*<=\s*1'b1", compact_source.read_text(encoding="utf-8")
    ))
    compact["lhs_sources"] = lhs
    compact["rhs_sources"] = rhs
    compact["unique_lhs_sources"] = len(lhs)
    compact["unique_rhs_sources"] = len(rhs)

    netlist_results = [baseline, compact]
    (OUT / "netlist_analysis.json").write_text(
        json.dumps(netlist_results, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    structural_rows = [structural_row(result) for result in netlist_results]
    write_table(OUT / "netlist_analysis_summary.csv", structural_rows)

    checkpoint_rows = []
    checkpoint_dirs = sorted(
        (OUT / "checkpoints").glob("*_w8"),
        key=lambda path: (
            0 if path.name == "initial_w8" else
            int(re.search(r"cleanup(\d+)", path.name).group(1))
        ),
    )
    for directory in checkpoint_dirs:
        resources = json.loads((directory / "resource_summary.json").read_text(encoding="utf-8-sig"))
        config = json.loads((directory / "config.json").read_text(encoding="utf-8-sig"))
        structure = analyze_with_source_ranges(
            diag, directory.name, directory / "post_synth_results.v", compact_source
        )
        checkpoint_rows.append({
            "checkpoint": directory.name,
            "main_sha256": config["main_sha256"],
            "lut_total": resources["lut_total"],
            "ff_total": resources["ff_total"],
            "CARRY4": resources["CARRY4"],
            "MUXF7": resources["MUXF7"],
            "MUXF8": resources["MUXF8"],
            "launch_sites": 1,
            "top_ff_direct_unique_lut_mux_drivers": structure["top_ff_direct_unique_lut_mux_drivers"],
        })
    (OUT / "resource_checkpoints.json").write_text(
        json.dumps(checkpoint_rows, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    write_table(OUT / "resource_checkpoints.csv", checkpoint_rows)

    final_resources = []
    for design in ("w8", "w9"):
        resources = json.loads((OUT / design / "resource_summary.json").read_text(encoding="utf-8-sig"))
        config = json.loads((OUT / design / "config.json").read_text(encoding="utf-8-sig"))
        final_resources.append({**config, **resources})
    (OUT / "final_resources.json").write_text(
        json.dumps(final_resources, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    write_table(OUT / "final_resources.csv", final_resources)

    print(json.dumps({
        "structure": structural_rows,
        "checkpoints": checkpoint_rows,
        "final_resources": final_resources,
    }, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

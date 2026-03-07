#!/usr/bin/env python3
"""
Observe scaling decisions from the Flink Kubernetes Operator logs.

Extracts ScalingConfiguration entries and presents them as a readable table.

Usage:
    ./08-observe-scaling.py                    # latest scaling config
    ./08-observe-scaling.py --follow           # watch continuously
    ./08-observe-scaling.py --tail 2000        # search last 2000 log lines
    ./08-observe-scaling.py --json             # machine-readable JSON output
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime


# ── Parsing ──────────────────────────────────────────────────────────────────

TIMESTAMP_RE = re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})")

# Matches individual ScalingInformation blocks (no nested braces inside)
SCALING_INFO_RE = re.compile(
    r"([0-9a-f]{32})=ScalingInformation\{([^}]+)\}"
)


def extract_brace_block(text: str, start: int) -> str:
    """Extract content between balanced braces starting at text[start] == '{'."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start + 1 : i]
    return text[start + 1 :]


def find_period_blocks(line: str) -> list[tuple[int, str]]:
    """Find N=ScalingConfiguration{scaling={...}} blocks with proper brace matching."""
    results = []
    pattern = re.compile(r"(\d+)=ScalingConfiguration\{scaling=")
    for m in pattern.finditer(line):
        period = int(m.group(1))
        brace_start = m.end()  # points right after 'scaling='
        if brace_start < len(line) and line[brace_start] == '{':
            content = extract_brace_block(line, brace_start)
            results.append((period, content))
    return results


@dataclass
class VertexInfo:
    vertex_id: str
    avg_throughput: float | str
    parallelism: int
    memory_level: int
    vertical_scaling: bool
    horizontal_scaling: bool
    avg_cache_hit_rate: float
    avg_state_latency: float


@dataclass
class ScalingSnapshot:
    timestamp: str
    period: int
    vertices: list[VertexInfo]


def parse_bool(s: str) -> bool:
    return s.strip().lower() == "true"


def parse_number(s: str) -> float | str:
    s = s.strip()
    if s == "Infinity":
        return "∞"
    if s == "-Infinity":
        return "-∞"
    if s == "NaN":
        return "NaN"
    try:
        f = float(s)
        return int(f) if f == int(f) and abs(f) < 1e15 else f
    except ValueError:
        return s


def parse_scaling_info(blob: str) -> list[VertexInfo]:
    """Parse a set of vertex ScalingInformation entries from a scaling={...} block."""
    vertices = []
    for m in SCALING_INFO_RE.finditer(blob):
        vid = m.group(1)
        fields_str = m.group(2)
        fields = {}
        for pair in fields_str.split(","):
            pair = pair.strip()
            if "=" not in pair:
                continue
            k, v = pair.split("=", 1)
            fields[k.strip()] = v.strip()

        vertices.append(VertexInfo(
            vertex_id=vid,
            avg_throughput=parse_number(fields.get("avgThroughput", "NaN")),
            parallelism=int(fields.get("parallelism", -1)),
            memory_level=int(fields.get("memoryLevel", -1)),
            vertical_scaling=parse_bool(fields.get("verticalScaling", "false")),
            horizontal_scaling=parse_bool(fields.get("horizontalScaling", "false")),
            avg_cache_hit_rate=float(fields.get("avgCacheHitRate", 0)),
            avg_state_latency=float(fields.get("avgStateLatency", 0)),
        ))
    return vertices


def parse_log_line(line: str) -> list[ScalingSnapshot] | None:
    """Parse one ScalingConfigurations log line into a list of snapshots (one per period)."""
    if "ScalingConfiguration" not in line:
        return None

    ts_match = TIMESTAMP_RE.search(line)
    timestamp = ts_match.group(1) if ts_match else "???"

    # Try to find period-separated ScalingConfiguration blocks
    snapshots = []
    for period, content in find_period_blocks(line):
        vertices = parse_scaling_info(content)
        if vertices:
            snapshots.append(ScalingSnapshot(timestamp=timestamp, period=period, vertices=vertices))

    # If no period markers found, try parsing the whole line as period 0
    if not snapshots:
        vertices = parse_scaling_info(line)
        if vertices:
            snapshots.append(ScalingSnapshot(timestamp=timestamp, period=0, vertices=vertices))

    return snapshots if snapshots else None


# ── Display ──────────────────────────────────────────────────────────────────

HEADER = (
    f"{'Vertex':>10}  {'P':>3}  {'MemLvl':>6}  {'Throughput':>12}  "
    f"{'HScale':>6}  {'VScale':>6}  {'CacheHit':>8}  {'StateLat':>8}"
)
SEP = "-" * len(HEADER)


def fmt_throughput(v) -> str:
    if isinstance(v, str):
        return v.rjust(12)
    return f"{v:>12.1f}"


def print_snapshot(snap: ScalingSnapshot) -> None:
    print(f"\n  ┌─ {snap.timestamp}  period={snap.period}")
    print(f"  │ {HEADER}")
    print(f"  │ {SEP}")
    for v in sorted(snap.vertices, key=lambda x: x.vertex_id):
        hs = "yes" if v.horizontal_scaling else "no"
        vs = "yes" if v.vertical_scaling else "no"
        cache = f"{v.avg_cache_hit_rate:.3f}" if v.avg_cache_hit_rate > 0 else "-"
        slat = f"{v.avg_state_latency:.1f}" if v.avg_state_latency > 0 else "-"
        print(
            f"  │ {v.vertex_id[:10]:>10}  {v.parallelism:>3}  {v.memory_level:>6}  "
            f"{fmt_throughput(v.avg_throughput)}  {hs:>6}  {vs:>6}  {cache:>8}  {slat:>8}"
        )
    print(f"  └{'─' * (len(HEADER) + 1)}")


def snapshot_to_dict(snap: ScalingSnapshot) -> dict:
    return {
        "timestamp": snap.timestamp,
        "period": snap.period,
        "vertices": [
            {
                "vertexId": v.vertex_id,
                "parallelism": v.parallelism,
                "memoryLevel": v.memory_level,
                "avgThroughput": v.avg_throughput,
                "horizontalScaling": v.horizontal_scaling,
                "verticalScaling": v.vertical_scaling,
                "avgCacheHitRate": v.avg_cache_hit_rate,
                "avgStateLatency": v.avg_state_latency,
            }
            for v in snap.vertices
        ],
    }


# ── Log fetching ─────────────────────────────────────────────────────────────

def get_operator_pod() -> str:
    """Find the flink-kubernetes-operator pod name."""
    out = subprocess.check_output(
        ["kubectl", "get", "pods", "--no-headers=true", "-o", "custom-columns=NAME:.metadata.name"],
        text=True,
    )
    for line in out.strip().splitlines():
        if "flink-kubernetes-operator" in line:
            return line.strip()
    raise SystemExit("No flink-kubernetes-operator pod found.")


def fetch_scaling_lines(pod: str, tail: int) -> list[str]:
    """Fetch operator logs and return lines containing ScalingConfiguration."""
    out = subprocess.check_output(
        ["kubectl", "logs", pod, "--tail", str(tail)],
        text=True,
    )
    return [l for l in out.splitlines() if "ScalingConfiguration" in l]


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tail", type=int, default=5000, help="Number of log lines to search (default: 5000)")
    parser.add_argument("--follow", "-f", action="store_true", help="Continuously poll for new entries")
    parser.add_argument("--interval", type=int, default=30, help="Poll interval in seconds for --follow (default: 30)")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    pod = get_operator_pod()
    print(f"Operator pod: {pod}")

    seen_timestamps: set[str] = set()

    while True:
        lines = fetch_scaling_lines(pod, args.tail)

        all_snapshots: list[ScalingSnapshot] = []
        for line in lines:
            parsed = parse_log_line(line)
            if parsed:
                all_snapshots.extend(parsed)

        # Deduplicate by (timestamp, period)
        new_snapshots = []
        for snap in all_snapshots:
            key = f"{snap.timestamp}|{snap.period}"
            if key not in seen_timestamps:
                seen_timestamps.add(key)
                new_snapshots.append(snap)

        if args.json:
            print(json.dumps([snapshot_to_dict(s) for s in new_snapshots], indent=2))
        else:
            if not new_snapshots and not args.follow:
                print("No ScalingConfiguration entries found in operator logs.")
            for snap in new_snapshots:
                print_snapshot(snap)

        if not args.follow:
            break

        time.sleep(args.interval)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""
Observe persisted rich Justin scaling snapshots from the autoscaler ConfigMap.

Usage:
    ./08-observe-scaling.py                    # latest persisted rich snapshots
    ./08-observe-scaling.py --follow           # watch continuously
    ./08-observe-scaling.py --since 8h         # only snapshots from the last 8 hours
    ./08-observe-scaling.py --deployment flink # select FlinkDeployment
    ./08-observe-scaling.py --configmap autoscaler-flink
    ./08-observe-scaling.py --json             # machine-readable JSON output
"""

from __future__ import annotations

import argparse
import base64
import gzip
import io
import json
import re
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import yaml


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


HEADER = (
    f"{'Vertex':>10}  {'P':>3}  {'MemLvl':>6}  {'Throughput':>12}  "
    f"{'HScale':>6}  {'VScale':>6}  {'CacheHit':>8}  {'StateLat':>8}"
)
SEP = "-" * len(HEADER)


def fmt_throughput(value) -> str:
    if isinstance(value, str):
        return value.rjust(12)
    return f"{value:>12.1f}"


def print_snapshot(snapshot: ScalingSnapshot) -> None:
    print(f"\n  ┌─ {snapshot.timestamp}  period={snapshot.period}")
    print(f"  │ {HEADER}")
    print(f"  │ {SEP}")
    for vertex in sorted(snapshot.vertices, key=lambda item: item.vertex_id):
        horizontal = "yes" if vertex.horizontal_scaling else "no"
        vertical = "yes" if vertex.vertical_scaling else "no"
        cache_hit = f"{vertex.avg_cache_hit_rate:.3f}" if vertex.avg_cache_hit_rate > 0 else "-"
        state_latency = f"{vertex.avg_state_latency:.1f}" if vertex.avg_state_latency > 0 else "-"
        print(
            f"  │ {vertex.vertex_id[:10]:>10}  {vertex.parallelism:>3}  "
            f"{vertex.memory_level:>6}  {fmt_throughput(vertex.avg_throughput)}  "
            f"{horizontal:>6}  {vertical:>6}  {cache_hit:>8}  {state_latency:>8}"
        )
    print(f"  └{'─' * (len(HEADER) + 1)}")


def snapshot_to_dict(snapshot: ScalingSnapshot) -> dict:
    return {
        "timestamp": snapshot.timestamp,
        "period": snapshot.period,
        "vertices": [
            {
                "vertexId": vertex.vertex_id,
                "parallelism": vertex.parallelism,
                "memoryLevel": vertex.memory_level,
                "avgThroughput": vertex.avg_throughput,
                "horizontalScaling": vertex.horizontal_scaling,
                "verticalScaling": vertex.vertical_scaling,
                "avgCacheHitRate": vertex.avg_cache_hit_rate,
                "avgStateLatency": vertex.avg_state_latency,
            }
            for vertex in snapshot.vertices
        ],
    }


def run_kubectl(args: list[str]) -> str:
    try:
        return subprocess.check_output(["kubectl", *args], text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        details = exc.output.strip()
        if details:
            raise SystemExit(f"Failed to run kubectl {' '.join(args)}:\n{details}") from exc
        raise SystemExit(f"Failed to run kubectl {' '.join(args)}") from exc


def get_default_deployment_name(explicit: str | None = None) -> str:
    if explicit:
        return explicit

    try:
        output = run_kubectl(["get", "flinkdeployment", "-o", "json"])
        items = json.loads(output).get("items", [])
        names = [item.get("metadata", {}).get("name") for item in items]
        names = [name for name in names if name]
        if "flink" in names:
            return "flink"
        if len(names) == 1:
            return names[0]
    except SystemExit:
        pass

    return "flink"


def parse_duration_expr(expr: str) -> timedelta:
    total = timedelta()
    matches = list(re.finditer(r"(\d+)([smhd])", expr.strip()))
    if not matches or "".join(match.group(0) for match in matches) != expr.strip():
        raise ValueError(f"Unsupported duration expression: {expr}")

    for match in matches:
        value = int(match.group(1))
        unit = match.group(2)
        if unit == "s":
            total += timedelta(seconds=value)
        elif unit == "m":
            total += timedelta(minutes=value)
        elif unit == "h":
            total += timedelta(hours=value)
        elif unit == "d":
            total += timedelta(days=value)

    return total


def parse_iso_datetime(value: str) -> datetime | None:
    value = value.strip()
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def format_timestamp(dt: datetime) -> str:
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%d %H:%M:%S,%f")[:-3]


def normalize_timestamp(value) -> str:
    if isinstance(value, datetime):
        return format_timestamp(value)

    if isinstance(value, str):
        parsed = parse_iso_datetime(value)
        if parsed:
            return format_timestamp(parsed)
        return value

    return str(value)


def get_cutoff_time(since: str | None) -> datetime | None:
    if not since:
        return None
    return datetime.now(timezone.utc) - parse_duration_expr(since)


def parse_history_timestamp_key(key) -> datetime | None:
    if isinstance(key, datetime):
        if key.tzinfo is None:
            return key.replace(tzinfo=timezone.utc)
        return key.astimezone(timezone.utc)
    if isinstance(key, str):
        return parse_iso_datetime(key)
    return None


def to_float_or_str(value):
    if value is None:
        return "-"
    if isinstance(value, (int, float)):
        return parse_number(str(value))
    return parse_number(str(value))


def parse_number(value: str) -> float | str:
    value = value.strip()
    if value == "Infinity":
        return "∞"
    if value == "-Infinity":
        return "-∞"
    if value == "NaN":
        return "NaN"
    try:
        parsed = float(value)
        return int(parsed) if parsed == int(parsed) and abs(parsed) < 1e15 else parsed
    except ValueError:
        return value


def find_autoscaler_configmap(
    deployment: str, configmap_name: str | None = None
) -> tuple[str, dict] | None:
    if configmap_name:
        output = run_kubectl(["get", "configmap", configmap_name, "-o", "json"])
        return configmap_name, json.loads(output)

    output = run_kubectl(
        [
            "get",
            "configmap",
            "-l",
            f"component=autoscaler,app={deployment}",
            "-o",
            "json",
        ]
    )
    items = json.loads(output).get("items", [])
    if items:
        items.sort(key=lambda item: item.get("metadata", {}).get("creationTimestamp", ""))
        item = items[-1]
        return item.get("metadata", {}).get("name", f"autoscaler-{deployment}"), item

    guessed_name = f"autoscaler-{deployment}"
    try:
        output = run_kubectl(["get", "configmap", guessed_name, "-o", "json"])
        return guessed_name, json.loads(output)
    except SystemExit:
        return None


def decode_autoscaler_state(value: str):
    raw = gzip.decompress(base64.b64decode(value))
    return yaml.safe_load(io.StringIO(raw.decode("utf-8")))


def fetch_configmap_rich_history(
    deployment: str,
    since: str | None = None,
    configmap_name: str | None = None,
) -> tuple[str, list[ScalingSnapshot]]:
    found = find_autoscaler_configmap(deployment, configmap_name)
    if not found:
        return "", []

    cm_name, configmap = found
    data = configmap.get("data") or {}
    rich_history = data.get("scalingConfigHistory")
    if not rich_history:
        return cm_name, []

    payload = decode_autoscaler_state(rich_history) or {}
    cutoff = get_cutoff_time(since)
    snapshots: list[ScalingSnapshot] = []

    if not isinstance(payload, dict):
        return cm_name, []

    for timestamp_key, snapshot in payload.items():
        timestamp = parse_history_timestamp_key(timestamp_key)
        if cutoff and timestamp and timestamp < cutoff:
            continue
        if not isinstance(snapshot, dict):
            continue

        vertices = []
        scaling = snapshot.get("scaling") or {}
        for vertex_id, info in scaling.items():
            if not isinstance(info, dict):
                continue
            vertices.append(
                VertexInfo(
                    vertex_id=str(vertex_id),
                    avg_throughput=to_float_or_str(info.get("avgThroughput")),
                    parallelism=int(info.get("parallelism", -1)),
                    memory_level=int(info.get("memoryLevel", -1)),
                    vertical_scaling=bool(info.get("verticalScaling", False)),
                    horizontal_scaling=bool(info.get("horizontalScaling", False)),
                    avg_cache_hit_rate=float(info.get("avgCacheHitRate", 0.0) or 0.0),
                    avg_state_latency=float(info.get("avgStateLatency", 0.0) or 0.0),
                )
            )

        if vertices:
            snapshots.append(
                ScalingSnapshot(
                    timestamp=normalize_timestamp(timestamp_key),
                    period=int(snapshot.get("period", 0)),
                    vertices=vertices,
                )
            )

    snapshots.sort(key=lambda item: (item.timestamp, item.period))
    return cm_name, snapshots


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--since",
        help="Only return snapshots newer than a relative duration such as 30m, 4h, or 2d",
    )
    parser.add_argument(
        "--deployment",
        help="FlinkDeployment name used to find the autoscaler ConfigMap",
    )
    parser.add_argument("--configmap", help="Autoscaler ConfigMap name override")
    parser.add_argument(
        "--follow", "-f", action="store_true", help="Continuously poll for new snapshots"
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=30,
        help="Poll interval in seconds for --follow (default: 30)",
    )
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    deployment = get_default_deployment_name(args.deployment)
    seen_keys: set[str] = set()
    printed_header = False

    while True:
        configmap_name, snapshots = fetch_configmap_rich_history(
            deployment,
            since=args.since,
            configmap_name=args.configmap,
        )

        new_snapshots = []
        for snapshot in snapshots:
            key = f"{snapshot.timestamp}|{snapshot.period}"
            if key not in seen_keys:
                seen_keys.add(key)
                new_snapshots.append(snapshot)

        if args.json:
            payload = {
                "deployment": deployment,
                "configMap": configmap_name or None,
                "richSnapshots": [snapshot_to_dict(snapshot) for snapshot in new_snapshots],
            }
            print(json.dumps(payload, indent=2))
        else:
            if not printed_header:
                print(f"Deployment: {deployment}")
                if configmap_name:
                    print(f"ConfigMap: {configmap_name}")
                printed_header = True

            for snapshot in new_snapshots:
                print_snapshot(snapshot)

            if not new_snapshots and not args.follow:
                print("No rich scaling snapshots found in autoscaler ConfigMap.")

        if not args.follow:
            break

        time.sleep(args.interval)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Measure latency, throughput and errors for exact API requests defined in JSON."""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import math
import statistics
import time
from pathlib import Path
from typing import Any

import httpx


def percentile(values: list[float], percentile_value: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentile_value
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


async def execute_request(
    client: httpx.AsyncClient,
    case: dict[str, Any],
    semaphore: asyncio.Semaphore,
    sequence: int,
) -> dict[str, Any]:
    async with semaphore:
        started = time.perf_counter()
        status: int | None = None
        response_bytes = 0
        error: str | None = None
        try:
            response = await client.request(
                method=case["method"],
                url=case["url"],
                headers=case.get("headers"),
                params=case.get("params"),
                json=case.get("json_body"),
            )
            status = response.status_code
            response_bytes = len(response.content)
        except Exception as exc:
            error = f"{type(exc).__name__}: {exc}"
        elapsed_ms = (time.perf_counter() - started) * 1000
        return {
            "case": case["name"],
            "sequence": sequence,
            "latency_ms": round(elapsed_ms, 2),
            "status": status,
            "response_bytes": response_bytes,
            "success": error is None and status is not None and 200 <= status < 400,
            "error": error,
        }


async def run_case(
    client: httpx.AsyncClient,
    case: dict[str, Any],
    request_count: int,
    concurrency: int,
) -> tuple[list[dict[str, Any]], float]:
    semaphore = asyncio.Semaphore(concurrency)
    started = time.perf_counter()
    rows = await asyncio.gather(
        *[
            execute_request(client, case, semaphore, sequence)
            for sequence in range(1, request_count + 1)
        ]
    )
    elapsed_seconds = time.perf_counter() - started
    for row in rows:
        row["concurrency"] = concurrency
    return rows, elapsed_seconds


def summarise(
    case_name: str,
    concurrency: int,
    rows: list[dict[str, Any]],
    elapsed_seconds: float,
) -> dict[str, Any]:
    latencies = [float(row["latency_ms"]) for row in rows]
    successes = sum(bool(row["success"]) for row in rows)
    return {
        "case": case_name,
        "concurrency": concurrency,
        "requests": len(rows),
        "successful_requests": successes,
        "error_rate_percent": round((1 - successes / len(rows)) * 100, 2),
        "throughput_requests_per_second": round(len(rows) / elapsed_seconds, 2),
        "mean_latency_ms": round(statistics.fmean(latencies), 2),
        "p50_latency_ms": round(percentile(latencies, 0.50), 2),
        "p95_latency_ms": round(percentile(latencies, 0.95), 2),
        "p99_latency_ms": round(percentile(latencies, 0.99), 2),
        "minimum_latency_ms": round(min(latencies), 2),
        "maximum_latency_ms": round(max(latencies), 2),
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requests-file", type=Path, default=Path("requests.json"))
    parser.add_argument("--requests-per-case", type=int, default=10)
    parser.add_argument("--concurrency", default="1,5,10")
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument("--output-dir", type=Path, default=Path("results/api"))
    args = parser.parse_args()

    definitions = json.loads(args.requests_file.read_text(encoding="utf-8"))
    cases = [case for case in definitions["requests"] if case.get("enabled", True)]
    concurrency_levels = [int(value.strip()) for value in args.concurrency.split(",")]
    args.output_dir.mkdir(parents=True, exist_ok=True)

    raw_rows: list[dict[str, Any]] = []
    summary_rows: list[dict[str, Any]] = []
    timeout = httpx.Timeout(args.timeout_seconds)
    limits = httpx.Limits(max_connections=max(concurrency_levels) + 5)

    async with httpx.AsyncClient(timeout=timeout, limits=limits) as client:
        for case in cases:
            await execute_request(client, case, asyncio.Semaphore(1), sequence=0)
            for concurrency in concurrency_levels:
                rows, elapsed = await run_case(
                    client, case, args.requests_per_case, concurrency
                )
                raw_rows.extend(rows)
                summary_rows.append(summarise(case["name"], concurrency, rows, elapsed))

    write_csv(args.output_dir / "api_runs.csv", raw_rows)
    write_csv(args.output_dir / "api_summary.csv", summary_rows)
    (args.output_dir / "api_results.json").write_text(
        json.dumps({"runs": raw_rows, "summary": summary_rows}, indent=2),
        encoding="utf-8",
    )
    print(f"Wrote results to {args.output_dir.resolve()}")


if __name__ == "__main__":
    asyncio.run(main())

#!/usr/bin/env python3
"""Collect repeatable browser and map-loading performance metrics for the DTP POC."""

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

from playwright.async_api import Browser, BrowserContext, Page, async_playwright


DEFAULT_URL = "https://d2343zgqxmbmvm.cloudfront.net"
INIT_SCRIPT = r"""
window.__pocPerf = {lcp: null, cls: 0, longTasks: []};
try {
  new PerformanceObserver((list) => {
    const entries = list.getEntries();
    const last = entries[entries.length - 1];
    if (last) window.__pocPerf.lcp = last.startTime;
  }).observe({type: 'largest-contentful-paint', buffered: true});
} catch (_) {}
try {
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      if (!entry.hadRecentInput) window.__pocPerf.cls += entry.value;
    }
  }).observe({type: 'layout-shift', buffered: true});
} catch (_) {}
try {
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      window.__pocPerf.longTasks.push({startTime: entry.startTime, duration: entry.duration});
    }
  }).observe({type: 'longtask', buffered: true});
} catch (_) {}
"""


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


async def wait_for_pmtiles_quiet(
    page: Page,
    state: dict[str, Any],
    quiet_ms: int,
    timeout_ms: int,
) -> float | None:
    started = time.perf_counter()
    while (time.perf_counter() - started) * 1000 < timeout_ms:
        last_activity = state.get("last_pmtiles_activity")
        if state.get("pmtiles_requests", 0) > 0 and last_activity is not None:
            if (time.perf_counter() - last_activity) * 1000 >= quiet_ms:
                return await page.evaluate("performance.now()")
        await asyncio.sleep(0.1)
    return None


async def collect_run(
    page: Page,
    run_id: int,
    cache_mode: str,
    url: str,
    timeout_ms: int,
    quiet_ms: int,
) -> dict[str, Any]:
    state: dict[str, Any] = {
        "pmtiles_requests": 0,
        "pmtiles_failures": 0,
        "last_pmtiles_activity": None,
    }

    def is_pmtiles(resource_url: str) -> bool:
        lowered = resource_url.lower()
        return ".pmtiles" in lowered or "pmtiles" in lowered

    def on_request(request: Any) -> None:
        if is_pmtiles(request.url):
            state["pmtiles_requests"] += 1
            state["last_pmtiles_activity"] = time.perf_counter()

    def on_response(response: Any) -> None:
        if is_pmtiles(response.url):
            state["last_pmtiles_activity"] = time.perf_counter()

    def on_request_failed(request: Any) -> None:
        if is_pmtiles(request.url):
            state["pmtiles_failures"] += 1
            state["last_pmtiles_activity"] = time.perf_counter()

    page.on("request", on_request)
    page.on("response", on_response)
    page.on("requestfailed", on_request_failed)

    started = time.perf_counter()
    status: int | None = None
    error: str | None = None
    canvas_ms: float | None = None
    pmtiles_settled_ms: float | None = None

    try:
        response = await page.goto(url, wait_until="load", timeout=timeout_ms)
        status = response.status if response else None
        try:
            await page.locator("canvas.maplibregl-canvas").first.wait_for(
                state="visible", timeout=timeout_ms
            )
            canvas_ms = await page.evaluate("performance.now()")
        except Exception:
            canvas_ms = None
        pmtiles_settled_ms = await wait_for_pmtiles_quiet(
            page, state, quiet_ms=quiet_ms, timeout_ms=timeout_ms
        )
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"

    elapsed_ms = (time.perf_counter() - started) * 1000
    browser_metrics = await page.evaluate(
        """
        () => {
          const nav = performance.getEntriesByType('navigation')[0];
          const paint = Object.fromEntries(
            performance.getEntriesByType('paint').map(e => [e.name, e.startTime])
          );
          const resources = performance.getEntriesByType('resource');
          const pmtiles = resources.filter(e =>
            e.name.toLowerCase().includes('.pmtiles') ||
            e.name.toLowerCase().includes('pmtiles')
          );
          const longTasks = window.__pocPerf?.longTasks || [];
          return {
            navigation: nav ? nav.toJSON() : {},
            firstPaint: paint['first-paint'] ?? null,
            firstContentfulPaint: paint['first-contentful-paint'] ?? null,
            largestContentfulPaint: window.__pocPerf?.lcp ?? null,
            cumulativeLayoutShift: window.__pocPerf?.cls ?? null,
            totalBlockingTime: longTasks.reduce(
              (total, task) => total + Math.max(0, task.duration - 50), 0
            ),
            pmtilesResourceCount: pmtiles.length,
            pmtilesTransferBytes: pmtiles.reduce((n, e) => n + (e.transferSize || 0), 0),
            pmtilesEncodedBytes: pmtiles.reduce((n, e) => n + (e.encodedBodySize || 0), 0),
            pmtilesMaxDuration: pmtiles.length ? Math.max(...pmtiles.map(e => e.duration)) : null,
            resourceCount: resources.length,
            transferBytes: resources.reduce((n, e) => n + (e.transferSize || 0), 0)
          };
        }
        """
    )
    nav = browser_metrics.get("navigation", {})
    result = {
        "run_id": run_id,
        "cache_mode": cache_mode,
        "http_status": status,
        "error": error,
        "elapsed_ms": round(elapsed_ms, 2),
        "ttfb_ms": round(nav.get("responseStart", 0) - nav.get("requestStart", 0), 2)
        if nav
        else None,
        "dom_content_loaded_ms": round(nav.get("domContentLoadedEventEnd", 0), 2)
        if nav
        else None,
        "load_event_ms": round(nav.get("loadEventEnd", 0), 2) if nav else None,
        "first_paint_ms": browser_metrics.get("firstPaint"),
        "first_contentful_paint_ms": browser_metrics.get("firstContentfulPaint"),
        "largest_contentful_paint_ms": browser_metrics.get("largestContentfulPaint"),
        "map_canvas_visible_ms": canvas_ms,
        "pmtiles_network_settled_ms": pmtiles_settled_ms,
        "total_blocking_time_ms": browser_metrics.get("totalBlockingTime"),
        "cumulative_layout_shift": browser_metrics.get("cumulativeLayoutShift"),
        "resource_count": browser_metrics.get("resourceCount"),
        "transfer_bytes": browser_metrics.get("transferBytes"),
        "pmtiles_request_count": state["pmtiles_requests"],
        "pmtiles_resource_count": browser_metrics.get("pmtilesResourceCount"),
        "pmtiles_transfer_bytes": browser_metrics.get("pmtilesTransferBytes"),
        "pmtiles_encoded_bytes": browser_metrics.get("pmtilesEncodedBytes"),
        "pmtiles_max_request_duration_ms": browser_metrics.get("pmtilesMaxDuration"),
        "pmtiles_failures": state["pmtiles_failures"],
    }
    page.remove_listener("request", on_request)
    page.remove_listener("response", on_response)
    page.remove_listener("requestfailed", on_request_failed)
    return result


async def new_context(browser: Browser, width: int, height: int) -> BrowserContext:
    context = await browser.new_context(
        viewport={"width": width, "height": height},
        service_workers="block",
    )
    await context.add_init_script(INIT_SCRIPT)
    return context


def summarise(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    metrics = [
        "ttfb_ms",
        "first_contentful_paint_ms",
        "largest_contentful_paint_ms",
        "map_canvas_visible_ms",
        "pmtiles_network_settled_ms",
        "total_blocking_time_ms",
        "pmtiles_request_count",
        "pmtiles_transfer_bytes",
    ]
    summary: list[dict[str, Any]] = []
    for cache_mode in ("cold", "warm"):
        selected = [row for row in rows if row["cache_mode"] == cache_mode]
        for metric in metrics:
            values = [float(row[metric]) for row in selected if row.get(metric) is not None]
            summary.append(
                {
                    "cache_mode": cache_mode,
                    "metric": metric,
                    "runs": len(values),
                    "mean": round(statistics.fmean(values), 2) if values else None,
                    "median_p50": round(percentile(values, 0.50), 2) if values else None,
                    "p95": round(percentile(values, 0.95), 2) if values else None,
                    "minimum": round(min(values), 2) if values else None,
                    "maximum": round(max(values), 2) if values else None,
                }
            )
    return summary


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--cold-runs", type=int, default=5)
    parser.add_argument("--warm-runs", type=int, default=5)
    parser.add_argument("--timeout-ms", type=int, default=60_000)
    parser.add_argument("--quiet-ms", type=int, default=1_500)
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--output-dir", type=Path, default=Path("results/frontend"))
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict[str, Any]] = []
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(headless=not args.headed)
        run_id = 1
        for _ in range(args.cold_runs):
            context = await new_context(browser, args.width, args.height)
            page = await context.new_page()
            rows.append(
                await collect_run(
                    page, run_id, "cold", args.url, args.timeout_ms, args.quiet_ms
                )
            )
            await context.close()
            run_id += 1

        if args.warm_runs:
            context = await new_context(browser, args.width, args.height)
            page = await context.new_page()
            await page.goto(args.url, wait_until="load", timeout=args.timeout_ms)
            for _ in range(args.warm_runs):
                rows.append(
                    await collect_run(
                        page, run_id, "warm", args.url, args.timeout_ms, args.quiet_ms
                    )
                )
                run_id += 1
            await context.close()
        await browser.close()

    summary = summarise(rows)
    write_csv(args.output_dir / "frontend_runs.csv", rows)
    write_csv(args.output_dir / "frontend_summary.csv", summary)
    (args.output_dir / "frontend_results.json").write_text(
        json.dumps({"url": args.url, "runs": rows, "summary": summary}, indent=2),
        encoding="utf-8",
    )
    print(f"Wrote results to {args.output_dir.resolve()}")


if __name__ == "__main__":
    asyncio.run(main())

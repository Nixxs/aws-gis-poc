"""Local DuckDB spatial-query benchmark.

Runs the *same* spatial query the Lambda runs (ST_Buffer -> ST_Intersects ->
ST_AsGeoJSON, build GeoJSON features in Python), but against the LOCAL parquet
file on local disk with full CPU/RAM and no S3 range reads or network hop.

Goal: isolate whether the ~4s "warm" parcels latency we see on Lambda is DuckDB
itself or the Lambda environment (limited vCPU, S3 range reads, memory limit).

We size circular buffers around a known-hit Melbourne point so each query
returns roughly 100 / 250 / 750 / 1000 features, and run each size 3x. The
first run is disk-cold; later runs benefit from the OS page cache.

Usage:
    .\.venv\Scripts\python.exe local_spatial_benchmark.py
    .\.venv\Scripts\python.exe local_spatial_benchmark.py --parquet ..\data\au_vic_dtp_parcel.parquet
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import time
from pathlib import Path

import duckdb

# Same known-hit point used for the Lambda tests (central Melbourne parcels).
CENTER_LON = 144.29780
CENTER_LAT = -37.82960

# One degree of latitude ~= 111.32 km; matches the Lambda's metre->degree math.
METERS_PER_DEGREE = 111_320.0

# Feature counts we want each buffered query to return (approximately).
TARGET_COUNTS = [100, 250, 750, 1000]
RUNS_PER_SIZE = 3

# Geometry column detection mirrors lambda/queries/_db.py.
_GEOMETRY_NAMES = {"geometry", "geom", "shape", "wkb_geometry", "the_geom"}


def _is_geometry(name: str, col_type: str) -> bool:
    return name.lower() in _GEOMETRY_NAMES or col_type.upper() == "BLOB"


def _geometry_value(name: str, col_type: str) -> str:
    """SQL yielding the layer geometry as a DuckDB GEOMETRY (for ST_Intersects)."""
    if col_type.upper().startswith("GEOMETRY"):
        return f'"{name}"'
    return f'ST_GeomFromWKB("{name}")'


def _geometry_expr(name: str, col_type: str) -> str:
    """SQL turning the geometry column into a GeoJSON string (mirror of Lambda)."""
    if col_type.upper().startswith("GEOMETRY"):
        return f'ST_AsGeoJSON("{name}")'
    return f'ST_AsGeoJSON(ST_GeomFromWKB("{name}"))'


def _jsonable(value):
    """Coerce DuckDB cell values into JSON-serialisable Python (mirror of Lambda)."""
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (bytes, bytearray)):
        return None
    return str(value)


def describe_columns(con: duckdb.DuckDBPyConnection, uri: str) -> list[dict]:
    rows = con.execute(f"DESCRIBE SELECT * FROM read_parquet('{uri}')").fetchall()
    columns = []
    for name, col_type, *_ in rows:
        columns.append(
            {
                "name": name,
                "type": col_type,
                "is_geometry": _is_geometry(name, col_type),
            }
        )
    return columns


def find_radii_for_targets(
    con: duckdb.DuckDBPyConnection,
    uri: str,
    geom_value_sql: str,
    targets: list[int],
) -> dict[int, float]:
    """Derive a buffer radius (in degrees) that yields ~N features per target.

    One distance-ranked scan: distance (degrees) from the centre point to each
    feature's centroid. The Nth smallest distance is a radius that returns ~N
    intersecting-by-centroid features; a hair of padding covers polygons whose
    edges reach the point. Good enough to hit the requested magnitudes.
    """
    max_target = max(targets)
    sql = (
        f"SELECT ST_Distance("
        f"  ST_Point({CENTER_LON}, {CENTER_LAT}), "
        f"  ST_Centroid({geom_value_sql})"
        f") AS d "
        f"FROM read_parquet('{uri}') "
        f"ORDER BY d "
        f"LIMIT {max_target}"
    )
    dists = [r[0] for r in con.execute(sql).fetchall() if r[0] is not None]
    radii: dict[int, float] = {}
    for n in targets:
        if len(dists) >= n:
            radii[n] = dists[n - 1] * 1.05  # small pad
        elif dists:
            radii[n] = dists[-1] * 1.05
        else:
            radii[n] = 0.0
    return radii


def run_query(
    con: duckdb.DuckDBPyConnection,
    uri: str,
    attribute_names: list[str],
    geom_value_sql: str,
    geom_expr_sql: str,
    radius_deg: float,
    limit: int,
    bbox_prefilter: bool = False,
) -> tuple[int, int, float]:
    """Run the full mirrored spatial query, build GeoJSON, return (count, bytes, ms).

    When ``bbox_prefilter`` is set (sorted/bbox-tagged parquet), a cheap min/max
    filter on the bbox columns is added *before* ST_Intersects so DuckDB can skip
    row groups via parquet statistics instead of full-scanning.
    """
    select_list = ", ".join(f'"{f}"' for f in attribute_names)
    if select_list:
        select_list += ", "

    point_sql = f"ST_Point({CENTER_LON}, {CENTER_LAT})"
    query_geom_sql = f"ST_Buffer({point_sql}, ?)"

    if bbox_prefilter:
        # bbox of the buffered point = [lon-r, lat-r, lon+r, lat+r].
        x0 = CENTER_LON - radius_deg
        x1 = CENTER_LON + radius_deg
        y0 = CENTER_LAT - radius_deg
        y1 = CENTER_LAT + radius_deg
        prefilter = (
            f'"bbox_xmax" >= {x0} AND "bbox_xmin" <= {x1} '
            f'AND "bbox_ymax" >= {y0} AND "bbox_ymin" <= {y1} AND '
        )
    else:
        prefilter = ""

    sql = (
        f"WITH q AS (SELECT {query_geom_sql} AS g) "
        f"SELECT {select_list}{geom_expr_sql} AS __geojson "
        f"FROM read_parquet('{uri}'), q "
        f"WHERE {prefilter}ST_Intersects({geom_value_sql}, q.g) "
        f"LIMIT {limit}"
    )

    start = time.perf_counter()
    cursor = con.execute(sql, [radius_deg])
    col_names = [d[0] for d in cursor.description]
    features = []
    for record in cursor.fetchall():
        row = dict(zip(col_names, record))
        geom_raw = row.pop("__geojson", None)
        geometry_out = json.loads(geom_raw) if geom_raw else None
        properties = {k: _jsonable(v) for k, v in row.items()}
        features.append(
            {"type": "Feature", "geometry": geometry_out, "properties": properties}
        )
    payload = {"type": "FeatureCollection", "features": features}
    body = json.dumps(payload)
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    return len(features), len(body.encode("utf-8")), elapsed_ms


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    default_parquet = Path(__file__).resolve().parent.parent / "data" / "au_vic_dtp_parcel.parquet"
    parser.add_argument("--parquet", default=str(default_parquet), help="Path to local parquet file")
    parser.add_argument("--output-dir", default=str(Path(__file__).resolve().parent / "results" / "local-spatial"))
    parser.add_argument("--threads", type=int, default=0, help="DuckDB threads (0 = default/all cores)")
    parser.add_argument("--bbox-prefilter", action="store_true", help="Add a bbox row-group pre-filter (for the sorted/bbox-tagged parquet)")
    parser.add_argument("--tag", default="local", help="Prefix for output filenames (e.g. 'sorted')")
    args = parser.parse_args()

    uri = str(Path(args.parquet).resolve()).replace("\\", "/")
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Parquet: {uri}")
    print(f"Exists:  {os.path.exists(args.parquet)}  Size: {os.path.getsize(args.parquet) / (1024*1024):.0f} MB")

    con = duckdb.connect(":memory:")
    con.execute("INSTALL spatial")
    con.execute("LOAD spatial")
    if args.threads > 0:
        con.execute(f"SET threads={args.threads}")
    threads = con.execute("SELECT current_setting('threads')").fetchone()[0]
    print(f"DuckDB {duckdb.__version__}  threads={threads}")

    columns = describe_columns(con, uri)
    geom_cols = [c for c in columns if c["is_geometry"]]
    if not geom_cols:
        raise SystemExit("No geometry column detected in parquet.")
    geom_col = geom_cols[0]
    # bbox_* are helper columns for pruning, not real attributes - keep them out
    # of the selected fields so the output matches the Lambda's properties.
    attribute_names = [
        c["name"]
        for c in columns
        if not c["is_geometry"] and not c["name"].lower().startswith("bbox_")
    ]
    geom_value_sql = _geometry_value(geom_col["name"], geom_col["type"])
    geom_expr_sql = _geometry_expr(geom_col["name"], geom_col["type"])

    bbox_cols = {"bbox_xmin", "bbox_ymin", "bbox_xmax", "bbox_ymax"}
    has_bbox = bbox_cols.issubset({c["name"].lower() for c in columns})
    use_prefilter = args.bbox_prefilter and has_bbox
    if args.bbox_prefilter and not has_bbox:
        print("WARNING: --bbox-prefilter requested but bbox_* columns are missing; running without it.")
    print(f"Geometry column: {geom_col['name']} ({geom_col['type']})  attributes: {len(attribute_names)}")
    print(f"bbox pre-filter: {'ON' if use_prefilter else 'OFF'}")

    total_start = time.perf_counter()
    total_rows = con.execute(f"SELECT count(*) FROM read_parquet('{uri}')").fetchone()[0]
    count_ms = (time.perf_counter() - total_start) * 1000.0
    print(f"Total features: {total_rows:,}  (footer count in {count_ms:.0f} ms)")

    print("Deriving buffer radii for target feature counts...")
    radii = find_radii_for_targets(con, uri, geom_value_sql, TARGET_COUNTS)
    for n, r in radii.items():
        print(f"  target {n:>4}: radius {r:.6f} deg  (~{r * METERS_PER_DEGREE:.0f} m)")

    # Warm-up: one query so extension/plan/page-cache costs don't skew run 1.
    print("Warm-up query...")
    run_query(
        con, uri, attribute_names, geom_value_sql, geom_expr_sql,
        radii[TARGET_COUNTS[0]], TARGET_COUNTS[0], bbox_prefilter=use_prefilter,
    )

    runs: list[dict] = []
    for target in TARGET_COUNTS:
        radius = radii[target]
        print(f"\nTarget ~{target} features (limit={target}, radius={radius:.6f} deg):")
        for run_idx in range(1, RUNS_PER_SIZE + 1):
            count, nbytes, ms = run_query(
                con, uri, attribute_names, geom_value_sql, geom_expr_sql, radius, target,
                bbox_prefilter=use_prefilter,
            )
            print(f"  run {run_idx}: {count} features, {nbytes:,} bytes, {ms:.0f} ms")
            runs.append(
                {
                    "target": target,
                    "run": run_idx,
                    "returned": count,
                    "bytes": nbytes,
                    "ms": round(ms, 1),
                    "radius_deg": round(radius, 6),
                }
            )

    # Summary per target.
    summary = []
    for target in TARGET_COUNTS:
        group = [r["ms"] for r in runs if r["target"] == target]
        returned = [r["returned"] for r in runs if r["target"] == target]
        summary.append(
            {
                "target": target,
                "returned": returned[0] if returned else 0,
                "runs": len(group),
                "min_ms": round(min(group), 1),
                "mean_ms": round(sum(group) / len(group), 1),
                "max_ms": round(max(group), 1),
            }
        )

    # Write outputs.
    runs_csv = out_dir / f"{args.tag}_runs.csv"
    with runs_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["target", "run", "returned", "bytes", "ms", "radius_deg"])
        w.writeheader()
        w.writerows(runs)

    summary_csv = out_dir / f"{args.tag}_summary.csv"
    with summary_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["target", "returned", "runs", "min_ms", "mean_ms", "max_ms"])
        w.writeheader()
        w.writerows(summary)

    results_json = out_dir / f"{args.tag}_results.json"
    results_json.write_text(
        json.dumps(
            {
                "parquet": uri,
                "duckdb_version": duckdb.__version__,
                "threads": threads,
                "total_features": total_rows,
                "bbox_prefilter": use_prefilter,
                "center": [CENTER_LON, CENTER_LAT],
                "geometry_column": geom_col["name"],
                "geometry_type": geom_col["type"],
                "runs": runs,
                "summary": summary,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    print("\n=== Summary (local DuckDB, warm) ===")
    print(f"{'target':>7} {'returned':>9} {'min_ms':>8} {'mean_ms':>9} {'max_ms':>8}")
    for s in summary:
        print(f"{s['target']:>7} {s['returned']:>9} {s['min_ms']:>8} {s['mean_ms']:>9} {s['max_ms']:>8}")
    print(f"\nWrote:\n  {runs_csv}\n  {summary_csv}\n  {results_json}")


if __name__ == "__main__":
    main()

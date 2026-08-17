"""Build a spatially-sorted, bbox-tagged copy of the parcels parquet.

This is a one-off "poor man's spatial index": we don't stand up a spatial
database, we just rewrite the parquet so that DuckDB can prune most of it.

What it does:
  1. Sorts every feature along a Hilbert space-filling curve, so parcels that
     are geographically close end up physically close in the file.
  2. Adds bbox columns (bbox_xmin/ymin/xmax/ymax) per feature.
  3. Writes small row groups, so each row group covers a tight geographic area
     and carries min/max statistics on the bbox columns.

At query time a cheap bbox pre-filter on those columns lets DuckDB skip whole
row groups via parquet statistics, instead of full-scanning all 4.17M rows.

Usage:
    .\.venv\Scripts\python.exe spatial_sort_parquet.py
    .\.venv\Scripts\python.exe spatial_sort_parquet.py --row-group-size 20000
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import duckdb

_GEOMETRY_NAMES = {"geometry", "geom", "shape", "wkb_geometry", "the_geom"}


def _is_geometry(name: str, col_type: str) -> bool:
    return name.lower() in _GEOMETRY_NAMES or col_type.upper() == "BLOB"


def _geometry_value(name: str, col_type: str) -> str:
    if col_type.upper().startswith("GEOMETRY"):
        return f'"{name}"'
    return f'ST_GeomFromWKB("{name}")'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    data_dir = Path(__file__).resolve().parent.parent / "data"
    parser.add_argument("--parquet", default=str(data_dir / "au_vic_dtp_parcel.parquet"))
    parser.add_argument("--out", default=str(data_dir / "au_vic_dtp_parcel_sorted.parquet"))
    parser.add_argument("--row-group-size", type=int, default=15000)
    parser.add_argument("--threads", type=int, default=0)
    args = parser.parse_args()

    src = str(Path(args.parquet).resolve()).replace("\\", "/")
    out = str(Path(args.out).resolve()).replace("\\", "/")

    con = duckdb.connect(":memory:")
    con.execute("INSTALL spatial")
    con.execute("LOAD spatial")
    if args.threads > 0:
        con.execute(f"SET threads={args.threads}")
    con.execute("SET preserve_insertion_order=false")

    # Detect the geometry column.
    desc = con.execute(f"DESCRIBE SELECT * FROM read_parquet('{src}')").fetchall()
    geom = next((n for n, t, *_ in desc if _is_geometry(n, t)), None)
    if geom is None:
        raise SystemExit("No geometry column detected.")
    geom_type = next(t for n, t, *_ in desc if n == geom)
    gval = _geometry_value(geom, geom_type)

    print(f"Source:  {src}")
    print(f"Output:  {out}")
    print(f"Geometry column: {geom} ({geom_type})  row_group_size={args.row_group_size}")

    start = time.perf_counter()
    con.execute(
        f"""
        COPY (
            SELECT
                *,
                ST_XMin({gval}) AS bbox_xmin,
                ST_YMin({gval}) AS bbox_ymin,
                ST_XMax({gval}) AS bbox_xmax,
                ST_YMax({gval}) AS bbox_ymax
            FROM read_parquet('{src}')
            ORDER BY ST_Hilbert(
                {gval},
                (SELECT ST_Extent_Agg({gval}) FROM read_parquet('{src}'))
            )
        ) TO '{out}' (FORMAT PARQUET, ROW_GROUP_SIZE {args.row_group_size})
        """
    )
    elapsed = time.perf_counter() - start

    src_mb = Path(args.parquet).stat().st_size / (1024 * 1024)
    out_mb = Path(args.out).stat().st_size / (1024 * 1024)
    n = con.execute(f"SELECT count(*) FROM read_parquet('{out}')").fetchone()[0]
    print(f"Wrote {n:,} rows in {elapsed:.1f}s")
    print(f"Size: source {src_mb:.0f} MB -> sorted {out_mb:.0f} MB")


if __name__ == "__main__":
    main()

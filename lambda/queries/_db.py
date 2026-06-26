"""Shared DuckDB helpers for the query actions.

A single configured connection (httpfs + aws extensions, S3 credentials from the
Lambda execution role) is built once and reused across warm invocations. Schema
introspection and layer-name validation live here so that describe-layer and
query enforce exactly the same rules.
"""

import os
import re

import duckdb

from queries.list_layers import list_layers

# Lambda sets AWS_REGION automatically; default matches the project's region.
_REGION = os.environ.get("AWS_REGION", "ap-southeast-2")
# Where the build step pre-installed the httpfs / aws extensions.
_EXT_DIR = os.environ.get("DUCKDB_EXTENSION_DIR", "/opt/duckdb_extensions")

# Layer names come from feature-class names (alphanumerics + underscores). This
# guard is defence-in-depth on top of the whitelist check so the value is never
# used to read an arbitrary S3 path.
_SAFE_LAYER = re.compile(r"^[A-Za-z0-9_.\-]+$")

# GeoParquet stores geometry as WKB, which DuckDB surfaces as BLOB. Flagging the
# geometry column lets callers treat it specially (map vs. attribute).
_GEOMETRY_NAMES = {"geometry", "geom", "shape", "wkb_geometry", "the_geom"}

_con = None


def connection():
    """Build (once) a DuckDB connection that can read parquet from S3.

    Reused across warm invocations. Extensions load from the baked image
    directory and the only writable scratch space in a Lambda sandbox (/tmp).
    """
    global _con
    if _con is not None:
        return _con

    con = duckdb.connect(database=":memory:")
    con.execute(f"SET extension_directory='{_EXT_DIR}'")
    con.execute("SET home_directory='/tmp'")
    con.execute("SET temp_directory='/tmp'")
    con.execute("LOAD httpfs")
    con.execute("LOAD aws")
    # spatial provides ST_AsGeoJSON / ST_GeomFromWKB for geometry output.
    con.execute("LOAD spatial")
    con.execute(f"SET s3_region='{_REGION}'")
    # Pull credentials from the Lambda execution role via the standard chain.
    con.execute("CREATE SECRET aws_creds (TYPE s3, PROVIDER credential_chain)")
    _con = con
    return con


def s3_uri(bucket: str, prefix: str, layer: str) -> str:
    return f"s3://{bucket}/{prefix}{layer}.parquet"


def is_geometry(name: str, col_type: str) -> bool:
    return name.lower() in _GEOMETRY_NAMES or col_type.upper() == "BLOB"


def validate_layer(bucket: str, prefix: str, layer):
    """Raise ValueError unless `layer` is a real, safely-named layer."""
    if not layer:
        raise ValueError("missing required parameter: layer")
    if not _SAFE_LAYER.match(layer):
        raise ValueError(f"invalid layer name: {layer!r}")
    if layer not in list_layers(bucket, prefix):
        raise ValueError(f"unknown layer: {layer!r}")


def layer_columns(bucket: str, prefix: str, layer: str) -> list:
    """Return [{name, type, nullable, is_geometry}] for a validated layer."""
    con = connection()
    uri = s3_uri(bucket, prefix, layer)
    # DESCRIBE returns: column_name, column_type, null, key, default, extra.
    rows = con.execute(f"DESCRIBE SELECT * FROM read_parquet('{uri}')").fetchall()
    return [
        {
            "name": name,
            "type": col_type,
            "nullable": (nullable == "YES"),
            "is_geometry": is_geometry(name, col_type),
        }
        for name, col_type, nullable, *_ in rows
    ]

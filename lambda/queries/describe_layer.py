"""describe-layer: return a layer's column schema (and feature count).

The front-end uses this to show the user what's in a layer so they can build a
query against it later.

DuckDB reads only the parquet footer (column metadata + row counts) via httpfs
range requests, so this stays cheap even for large layers. The DuckDB
extensions are baked into the image at build time (see Dockerfile), so cold
starts just LOAD them from DUCKDB_EXTENSION_DIR with no network download.
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
# guard is defence-in-depth on top of the whitelist check below so the value is
# never used to read an arbitrary S3 path.
_SAFE_LAYER = re.compile(r"^[A-Za-z0-9_.\-]+$")

# GeoParquet stores geometry as WKB, which DuckDB surfaces as BLOB. Flagging the
# geometry column lets the front-end treat it specially (map vs. attribute).
_GEOMETRY_NAMES = {"geometry", "geom", "shape", "wkb_geometry", "the_geom"}

_con = None


def _connection():
    """Build (once) a DuckDB connection that can read parquet from S3.

    Reused across warm invocations. Extensions are loaded from the baked image
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
    con.execute(f"SET s3_region='{_REGION}'")
    # Pull credentials from the Lambda execution role via the standard chain.
    con.execute("CREATE SECRET aws_creds (TYPE s3, PROVIDER credential_chain)")
    _con = con
    return con


def describe_layer(bucket: str, prefix: str, layer):
    if not layer:
        raise ValueError("missing required parameter: layer")
    if not _SAFE_LAYER.match(layer):
        raise ValueError(f"invalid layer name: {layer!r}")
    # Whitelist: the layer must be one the pipeline actually produced.
    if layer not in list_layers(bucket, prefix):
        raise ValueError(f"unknown layer: {layer!r}")

    s3_uri = f"s3://{bucket}/{prefix}{layer}.parquet"
    con = _connection()

    # DESCRIBE returns: column_name, column_type, null, key, default, extra.
    schema = con.execute(
        f"DESCRIBE SELECT * FROM read_parquet('{s3_uri}')"
    ).fetchall()
    columns = [
        {
            "name": name,
            "type": col_type,
            "nullable": (nullable == "YES"),
            "is_geometry": (
                name.lower() in _GEOMETRY_NAMES or col_type.upper() == "BLOB"
            ),
        }
        for name, col_type, nullable, *_ in schema
    ]

    feature_count = con.execute(
        f"SELECT count(*) FROM read_parquet('{s3_uri}')"
    ).fetchone()[0]

    return {
        "layer": layer,
        "feature_count": feature_count,
        "columns": columns,
    }

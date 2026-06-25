"""describe-layer: return a layer's column schema (and feature count).

The front-end uses this to show the user what's in a layer so they can build a
query against it later.

DuckDB reads only the parquet footer (column metadata + row counts) via httpfs
range requests, so this stays cheap even for large layers. The shared connection
and schema introspection live in queries._db so describe and query validate
layers and columns identically.
"""

from queries._db import connection, layer_columns, s3_uri, validate_layer


def describe_layer(bucket: str, prefix: str, layer):
    validate_layer(bucket, prefix, layer)

    columns = layer_columns(bucket, prefix, layer)

    con = connection()
    feature_count = con.execute(
        f"SELECT count(*) FROM read_parquet('{s3_uri(bucket, prefix, layer)}')"
    ).fetchone()[0]

    return {
        "layer": layer,
        "feature_count": feature_count,
        "columns": columns,
    }

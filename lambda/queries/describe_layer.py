"""describe-layer: return a layer's column schema.

STUB - to be implemented with DuckDB (DESCRIBE on the parquet in S3 via the
httpfs extension). Add `duckdb` to requirements.txt and import it lazily here
when implementing, so list-layers cold starts stay light.
"""


def describe_layer(bucket: str, prefix: str, layer):
    raise NotImplementedError("describe-layer is not implemented yet")

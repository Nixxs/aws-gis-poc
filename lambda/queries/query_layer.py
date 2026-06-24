"""query: return rows from a layer with filters.

STUB - to be implemented with DuckDB querying the parquet in S3 directly
(SELECT ... FROM read_parquet('s3://...') WHERE ...), optionally emitting
GeoJSON via the spatial extension. Import duckdb lazily when implementing.
"""


def query_layer(event: dict, bucket: str, prefix: str):
    raise NotImplementedError("query is not implemented yet")

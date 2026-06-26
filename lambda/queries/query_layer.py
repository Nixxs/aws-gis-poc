"""query: return rows from a layer, Esri-style.

This mirrors a useful subset of the ArcGIS Feature Service ``query`` operation
so the parameters are familiar to GIS clients:

    layer              required, the feature class to query
    where              SQL-92 WHERE clause (the only raw user SQL we accept)
    outFields          comma list of fields, or * (default: all attributes)
    orderByFields      e.g. "AREA_HA DESC, NAME ASC"
    resultOffset       skip N rows (default 0)
    resultRecordCount  page size, clamped to MAX_RECORD_COUNT
    returnCountOnly    "true" -> {"count": N} fast path
    f                  "json" (default, attributes only) or "geojson"
    returnGeometry     "true" also forces geometry output (GeoJSON)

For f=geojson the response is a GeoJSON FeatureCollection: each feature's
attributes become ``properties`` and the layer's geometry column is converted to
GeoJSON via the spatial extension (ST_AsGeoJSON), ready to drop onto a map.

Security model ("standardized queries", lite): the only place raw user SQL
lands is ``where``, which we inject as ``WHERE (<where>)``. We harden it the way
Esri's standardized queries do:

  * single statement only - reject ``;`` and SQL comments,
  * a blocklist of file/SSRF table functions (read_*, glob, parquet_scan, URLs),
  * the clause is wrapped in parentheses so an attempted breakout (e.g.
    ``1=1) UNION SELECT ...``) produces unbalanced parens and a clean parse error,
  * outFields / orderByFields are validated against the live schema, and the
    page size is clamped.

This is acceptable here because the data behind it is already public. If this
ever fronts private data, replace the raw ``where`` with a parsed/whitelisted
filter builder instead.
"""

import datetime
import decimal
import json

import duckdb

from queries._db import connection, layer_columns, s3_uri, validate_layer

# Server-side cap on rows returned, mirroring Esri's maxRecordCount.
MAX_RECORD_COUNT = 1000
DEFAULT_RECORD_COUNT = 200

# DuckDB errors that mean "the user's query is bad" (-> 400) rather than an
# infrastructure failure (-> 500).
_BAD_QUERY_ERRORS = (
    duckdb.ParserException,
    duckdb.BinderException,
    duckdb.ConversionException,
    duckdb.InvalidInputException,
    duckdb.CatalogException,
)

_ORDER_DIRECTIONS = {"ASC", "DESC"}

# Lowercased fragments that must never appear in a WHERE clause: SQL statement
# terminators/comments and the table functions / URL schemes that could read
# arbitrary files or make outbound requests from inside a scalar subquery.
_FORBIDDEN = (
    ";", "--", "/*", "*/",
    "read_", "parquet_scan", "glob(",
    "http://", "https://", "file:",
)


def _truthy(value) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes"} if value is not None else False


def _jsonable(value):
    """Coerce DuckDB values into something json.dumps can handle."""
    if isinstance(value, (datetime.date, datetime.datetime, datetime.time)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        return None
    return value


def _clamp_int(value, default: int, lo: int, hi=None) -> int:
    if value is None or str(value).strip() == "":
        n = default
    else:
        try:
            n = int(value)
        except (TypeError, ValueError):
            raise ValueError(f"expected an integer, got {value!r}")
    if n < lo:
        n = lo
    if hi is not None and n > hi:
        n = hi
    return n


def _check_where(where: str):
    lowered = where.lower()
    for token in _FORBIDDEN:
        if token in lowered:
            raise ValueError("where clause contains disallowed syntax")


def _select_fields(out_fields, attribute_names):
    """Resolve outFields to a validated column list (geometry excluded)."""
    if not out_fields or out_fields.strip() == "*":
        return list(attribute_names)
    requested = [f.strip() for f in out_fields.split(",") if f.strip()]
    unknown = [f for f in requested if f not in attribute_names]
    if unknown:
        raise ValueError(f"unknown outFields: {', '.join(unknown)}")
    return requested


def _order_by_clause(order_by_fields, valid_names):
    if not order_by_fields or not order_by_fields.strip():
        return ""
    parts = []
    for token in order_by_fields.split(","):
        token = token.strip()
        if not token:
            continue
        bits = token.split()
        field = bits[0]
        direction = bits[1].upper() if len(bits) > 1 else "ASC"
        if field not in valid_names:
            raise ValueError(f"unknown orderByFields field: {field!r}")
        if direction not in _ORDER_DIRECTIONS:
            raise ValueError(f"invalid sort direction: {direction!r}")
        parts.append(f'"{field}" {direction}')
    return " ORDER BY " + ", ".join(parts) if parts else ""


def _run(con, sql):
    """Execute SQL, mapping user-caused query errors to ValueError (HTTP 400)."""
    try:
        return con.execute(sql)
    except _BAD_QUERY_ERRORS as exc:
        raise ValueError(f"invalid query: {exc}")


def query_layer(params: dict, bucket: str, prefix: str):
    layer = params.get("layer")
    validate_layer(bucket, prefix, layer)

    fmt = (params.get("f") or "json").lower()
    if fmt not in ("json", "geojson"):
        raise ValueError(f"unsupported format: {fmt!r} (use 'json' or 'geojson')")
    want_geometry = fmt == "geojson" or _truthy(params.get("returnGeometry"))

    columns = layer_columns(bucket, prefix, layer)
    all_names = [c["name"] for c in columns]
    attribute_names = [c["name"] for c in columns if not c["is_geometry"]]
    geometry_cols = [c for c in columns if c["is_geometry"]]

    uri = s3_uri(bucket, prefix, layer)
    con = connection()

    # Optional WHERE clause, wrapped in parens so a breakout attempt can't escape
    # it. "1=1" is the Esri idiom for "no filter", so treat it as empty.
    where = params.get("where")
    where_sql = ""
    if where and where.strip() and where.strip() != "1=1":
        _check_where(where)
        where_sql = f" WHERE ({where})"

    if _truthy(params.get("returnCountOnly")):
        sql = f"SELECT count(*) FROM read_parquet('{uri}'){where_sql}"
        count = _run(con, sql).fetchone()[0]
        return {"layer": layer, "count": count}

    fields = _select_fields(params.get("outFields"), attribute_names)
    order_sql = _order_by_clause(params.get("orderByFields"), all_names)
    limit = _clamp_int(
        params.get("resultRecordCount"), DEFAULT_RECORD_COUNT, 1, MAX_RECORD_COUNT
    )
    offset = _clamp_int(params.get("resultOffset"), 0, 0)

    if want_geometry:
        if not geometry_cols:
            raise ValueError(f"layer {layer!r} has no geometry column")
        return _query_geojson(
            con, uri, layer, fields, geometry_cols[0],
            where_sql, order_sql, limit, offset,
        )

    select_list = ", ".join(f'"{f}"' for f in fields)
    sql = (
        f"SELECT {select_list} FROM read_parquet('{uri}')"
        f"{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}"
    )

    cursor = _run(con, sql)
    col_names = [d[0] for d in cursor.description]
    features = [
        {name: _jsonable(val) for name, val in zip(col_names, record)}
        for record in cursor.fetchall()
    ]

    return {
        "layer": layer,
        "count": len(features),
        "resultOffset": offset,
        "resultRecordCount": limit,
        "fields": fields,
        "features": features,
    }


def _geometry_expr(name: str, col_type: str) -> str:
    """SQL that turns the geometry column into a GeoJSON string.

    GeoParquet geometry surfaces either as a native DuckDB GEOMETRY (when the
    spatial extension recognises it) or as raw WKB bytes (BLOB); handle both.
    Coordinates are emitted as stored - this data is GDA2020, which is within a
    couple of metres of WGS84, so web maps can treat it as EPSG:4326 directly.
    """
    if col_type.upper().startswith("GEOMETRY"):
        return f'ST_AsGeoJSON("{name}")'
    return f'ST_AsGeoJSON(ST_GeomFromWKB("{name}"))'


def _query_geojson(con, uri, layer, fields, geom_col, where_sql, order_sql, limit, offset):
    """Return a GeoJSON FeatureCollection (attributes as properties + geometry)."""
    geom_expr = _geometry_expr(geom_col["name"], geom_col["type"])
    select_list = ", ".join(f'"{f}"' for f in fields)
    if select_list:
        select_list += ", "
    sql = (
        f"SELECT {select_list}{geom_expr} AS __geojson "
        f"FROM read_parquet('{uri}')"
        f"{where_sql}{order_sql} LIMIT {limit} OFFSET {offset}"
    )

    cursor = _run(con, sql)
    col_names = [d[0] for d in cursor.description]
    features = []
    for record in cursor.fetchall():
        row = dict(zip(col_names, record))
        geom_raw = row.pop("__geojson", None)
        geometry = json.loads(geom_raw) if geom_raw else None
        properties = {k: _jsonable(v) for k, v in row.items()}
        features.append(
            {"type": "Feature", "geometry": geometry, "properties": properties}
        )

    return {
        "type": "FeatureCollection",
        "features": features,
        # Non-standard extras the client can ignore; handy for paging/debugging.
        "layer": layer,
        "count": len(features),
        "resultOffset": offset,
        "resultRecordCount": limit,
    }

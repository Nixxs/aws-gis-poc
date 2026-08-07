"""spatial-query: return a layer's features that intersect a drawn geometry.

The client draws a point or polygon on the map, picks a layer, and calls this
route. We take that GeoJSON geometry, optionally buffer it, and return every
feature in the layer whose geometry intersects the (buffered) input as a GeoJSON
FeatureCollection - ready to drop straight onto the map.

Parameters:
    layer              required, the feature class to query
    geometry           required, a GeoJSON geometry (or a Feature wrapping one)
    buffer             optional, buffer distance in METRES (default 0 = none)
    outFields          comma list of attribute fields, or * (default: all)
    resultRecordCount  page size, clamped to query_layer.MAX_RECORD_COUNT

Buffer units: the GeoParquet data is stored in GDA2020 lon/lat (treated as
EPSG:4326), so distances in the SQL are in degrees. We convert the requested
metres to an approximate degree radius (metres / 111,320). This is a deliberate
POC simplification - the buffer is a few percent narrower east-west than
north-south at Victorian latitudes. If metre-accurate buffers are ever needed,
reproject to a metric CRS (e.g. GDA2020 MGA zone 55) with ST_Transform first.

Security: the geometry and buffer reach the database only as bound parameters
(never string-interpolated), and the layer name is whitelist-validated, so no
raw user input is concatenated into SQL.
"""

import json

from queries._db import (
    connection,
    layer_columns,
    s3_uri,
    validate_layer,
)
from queries.query_layer import (
    DEFAULT_RECORD_COUNT,
    MAX_RECORD_COUNT,
    _BAD_QUERY_ERRORS,
    _clamp_int,
    _geometry_expr,
    _jsonable,
    _select_fields,
)

# One degree of latitude ~= 111.32 km; used to turn a metre buffer into degrees.
_METERS_PER_DEGREE = 111_320.0

# Guard against absurd buffers that would scan/return the whole layer.
_MAX_BUFFER_METERS = 50_000.0

_GEOMETRY_TYPES = {
    "Point", "MultiPoint", "LineString", "MultiLineString",
    "Polygon", "MultiPolygon", "GeometryCollection",
}


def _extract_geometry(geometry):
    """Normalise the input to a bare GeoJSON geometry dict.

    Accepts a geometry, a Feature, or a single-feature FeatureCollection so the
    client can send whatever its draw tool produces.
    """
    if geometry is None:
        raise ValueError("missing required parameter: geometry")
    if isinstance(geometry, str):
        try:
            geometry = json.loads(geometry)
        except (ValueError, TypeError):
            raise ValueError("geometry must be valid GeoJSON")
    if not isinstance(geometry, dict):
        raise ValueError("geometry must be a GeoJSON object")

    gtype = geometry.get("type")
    if gtype == "Feature":
        return _extract_geometry(geometry.get("geometry"))
    if gtype == "FeatureCollection":
        features = geometry.get("features") or []
        if len(features) != 1:
            raise ValueError("geometry FeatureCollection must contain exactly one feature")
        return _extract_geometry(features[0].get("geometry"))
    if gtype not in _GEOMETRY_TYPES:
        raise ValueError(f"unsupported geometry type: {gtype!r}")
    return geometry


def _parse_buffer(value) -> float:
    if value is None or str(value).strip() == "":
        return 0.0
    try:
        meters = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"buffer must be a number of metres, got {value!r}")
    if meters < 0:
        raise ValueError("buffer must be >= 0")
    return min(meters, _MAX_BUFFER_METERS)


def _geometry_value(name: str, col_type: str) -> str:
    """SQL that yields the layer geometry as a DuckDB GEOMETRY (for ST_Intersects)."""
    if col_type.upper().startswith("GEOMETRY"):
        return f'"{name}"'
    return f'ST_GeomFromWKB("{name}")'


def spatial_query(params: dict, bucket: str, prefix: str):
    layer = params.get("layer")
    validate_layer(bucket, prefix, layer)

    geometry = _extract_geometry(params.get("geometry"))
    geojson_str = json.dumps(geometry)
    buffer_m = _parse_buffer(params.get("buffer"))
    buffer_deg = buffer_m / _METERS_PER_DEGREE

    columns = layer_columns(bucket, prefix, layer)
    attribute_names = [c["name"] for c in columns if not c["is_geometry"]]
    geometry_cols = [c for c in columns if c["is_geometry"]]
    if not geometry_cols:
        raise ValueError(f"layer {layer!r} has no geometry column")
    geom_col = geometry_cols[0]

    fields = _select_fields(params.get("outFields"), attribute_names)
    limit = _clamp_int(
        params.get("resultRecordCount"), DEFAULT_RECORD_COUNT, 1, MAX_RECORD_COUNT
    )

    uri = s3_uri(bucket, prefix, layer)
    con = connection()

    # Build the (optionally buffered) query geometry once, with the GeoJSON and
    # buffer bound as parameters so no user text is interpolated into SQL.
    if buffer_deg > 0:
        query_geom_sql = "ST_Buffer(ST_GeomFromGeoJSON(?), ?)"
        bind = [geojson_str, buffer_deg]
    else:
        query_geom_sql = "ST_GeomFromGeoJSON(?)"
        bind = [geojson_str]

    layer_geom_value = _geometry_value(geom_col["name"], geom_col["type"])
    geom_expr = _geometry_expr(geom_col["name"], geom_col["type"])

    select_list = ", ".join(f'"{f}"' for f in fields)
    if select_list:
        select_list += ", "

    sql = (
        f"WITH q AS (SELECT {query_geom_sql} AS g) "
        f"SELECT {select_list}{geom_expr} AS __geojson "
        f"FROM read_parquet('{uri}'), q "
        f"WHERE ST_Intersects({layer_geom_value}, q.g) "
        f"LIMIT {limit}"
    )

    try:
        cursor = con.execute(sql, bind)
    except _BAD_QUERY_ERRORS as exc:
        raise ValueError(f"invalid spatial query: {exc}")

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

    # The buffered query geometry, so the client can outline what was searched.
    buf_row = con.execute(f"SELECT ST_AsGeoJSON({query_geom_sql})", bind).fetchone()
    query_geometry = json.loads(buf_row[0]) if buf_row and buf_row[0] else None

    return {
        "type": "FeatureCollection",
        "features": features,
        "layer": layer,
        "count": len(features),
        "bufferMeters": buffer_m,
        "queryGeometry": query_geometry,
    }

"""unique-values: return the distinct values of one column in a layer.

The front-end uses this to power an autocomplete in the query builder: after
``describe-layer`` tells it which columns exist, the user picks a column and
this returns the values to suggest as they type.

Parameters:
    layer    required, the feature class to read
    field    required, the (attribute) column to list values for
    search   optional, case-insensitive substring filter for autocomplete
    limit    optional, max values to return (clamped to MAX_VALUES)

Only real attribute columns are allowed - geometry columns are rejected. The
field is validated against the live schema and then quoted as an identifier, so
no raw user text reaches the SQL except via the parameterised ``search`` value.
"""

from queries._db import connection, layer_columns, s3_uri, validate_layer

# Cap how many distinct values we hand back so a high-cardinality column (e.g. a
# parcel id) can't return a huge payload. The UI only needs enough to suggest.
MAX_VALUES = 200
DEFAULT_VALUES = 50


def _clamp_limit(value) -> int:
    if value is None or str(value).strip() == "":
        return DEFAULT_VALUES
    try:
        n = int(value)
    except (TypeError, ValueError):
        raise ValueError(f"expected an integer limit, got {value!r}")
    if n < 1:
        return 1
    return min(n, MAX_VALUES)


def unique_values(params: dict, bucket: str, prefix: str):
    layer = params.get("layer")
    validate_layer(bucket, prefix, layer)

    field = params.get("field")
    if not field:
        raise ValueError("missing required parameter: field")

    columns = layer_columns(bucket, prefix, layer)
    by_name = {c["name"]: c for c in columns}
    if field not in by_name:
        raise ValueError(f"unknown field: {field!r}")
    if by_name[field]["is_geometry"]:
        raise ValueError(f"field {field!r} is a geometry column")

    limit = _clamp_limit(params.get("limit"))
    uri = s3_uri(bucket, prefix, layer)
    con = connection()

    # The field name is validated against the schema above, so quoting it as an
    # identifier is safe. The search term is bound as a parameter ($search).
    sql = f'SELECT DISTINCT "{field}" AS value FROM read_parquet(\'{uri}\') WHERE "{field}" IS NOT NULL'
    args = []
    search = params.get("search")
    if search and str(search).strip():
        sql += f' AND lower(CAST("{field}" AS VARCHAR)) LIKE ?'
        args.append(f"%{str(search).strip().lower()}%")
    sql += " ORDER BY value LIMIT ?"
    args.append(limit)

    rows = con.execute(sql, args).fetchall()
    values = [row[0] for row in rows]

    return {
        "layer": layer,
        "field": field,
        "values": values,
        "truncated": len(values) >= limit,
    }

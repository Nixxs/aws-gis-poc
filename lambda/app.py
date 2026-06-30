"""gis-poc-query Lambda - a single function that answers queries about the
GeoParquet layers the pipeline writes to the app bucket.

It uses an "action" router so one Lambda can serve every query type:
    action=list-layers       -> names of the layers available to query
    action=describe-layer     -> a layer's column schema
    action=unique-values      -> distinct values of one column (for autocomplete)
    action=query              -> rows from a layer with an Esri-style filter

The handler reads the API Gateway / Lambda Function URL "v2.0" event shape, so
this exact function can sit behind a Function URL now and an API Gateway HTTP
API later with no code changes.
"""

import json
import logging
import os

log = logging.getLogger()
log.setLevel(logging.INFO)

APP_BUCKET = os.environ["APP_BUCKET"]
GEOPARQUET_PREFIX = os.environ.get("GEOPARQUET_PREFIX", "public/geoparquet/")

CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "*",
}


def _response(status: int, payload) -> dict:
    return {"statusCode": status, "headers": CORS_HEADERS, "body": json.dumps(payload)}


def get_param(event: dict, name: str, default=None):
    """Read a parameter from the query string, falling back to a JSON body."""
    qs = event.get("queryStringParameters") or {}
    if name in qs:
        return qs[name]
    body = event.get("body")
    if body:
        try:
            data = json.loads(body)
            if isinstance(data, dict) and name in data:
                return data[name]
        except (ValueError, TypeError):
            pass
    return default


def all_params(event: dict) -> dict:
    """Merge JSON-body params (POST) with query-string params (GET).

    Query-string values win on conflict. Used by the query action, which has a
    larger, Esri-style parameter set than the simpler routes.
    """
    params = {}
    body = event.get("body")
    if body:
        try:
            data = json.loads(body)
            if isinstance(data, dict):
                params.update(data)
        except (ValueError, TypeError):
            pass
    params.update(event.get("queryStringParameters") or {})
    return params


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    if method == "OPTIONS":  # CORS preflight
        return _response(200, {})

    action = get_param(event, "action")
    log.info("action=%s", action)

    try:
        if action == "list-layers":
            from queries.list_layers import list_layers
            return _response(200, {"layers": list_layers(APP_BUCKET, GEOPARQUET_PREFIX)})

        if action == "describe-layer":
            from queries.describe_layer import describe_layer
            layer = get_param(event, "layer")
            return _response(200, describe_layer(APP_BUCKET, GEOPARQUET_PREFIX, layer))

        if action == "unique-values":
            from queries.unique_values import unique_values
            return _response(200, unique_values(all_params(event), APP_BUCKET, GEOPARQUET_PREFIX))

        if action == "query":
            from queries.query_layer import query_layer
            return _response(200, query_layer(all_params(event), APP_BUCKET, GEOPARQUET_PREFIX))

        return _response(400, {
            "error": f"unknown or missing action: {action!r}",
            "actions": ["list-layers", "describe-layer", "unique-values", "query"],
        })
    except ValueError as exc:  # bad/missing parameters -> client error
        return _response(400, {"error": str(exc)})
    except NotImplementedError as exc:
        return _response(501, {"error": str(exc)})
    except Exception as exc:  # noqa: BLE001 - surface a clean error to the caller
        log.exception("handler failed")
        return _response(500, {"error": str(exc)})
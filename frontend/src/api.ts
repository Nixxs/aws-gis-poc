// Thin client for the gis-poc-query Lambda (Function URL).
// One function per action; everything goes over GET with query-string params,
// which matches the Lambda's verb-agnostic router and avoids body escaping.
const API_BASE = import.meta.env.VITE_QUERY_API_URL as string

export interface ColumnInfo {
  name: string
  type: string
  nullable: boolean
  is_geometry: boolean
}

export interface DescribeLayerResult {
  layer: string
  feature_count: number
  columns: ColumnInfo[]
}

export interface UniqueValuesResult {
  layer: string
  field: string
  values: (string | number | null)[]
  truncated: boolean
}

// A GeoJSON FeatureCollection (loosely typed — good enough for the map).
export type FeatureCollection = {
  type: 'FeatureCollection'
  features: Array<{
    type: 'Feature'
    geometry: unknown
    properties: Record<string, unknown>
  }>
}

async function call<T>(params: Record<string, string>): Promise<T> {
  const url = new URL(API_BASE)
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v)
  const res = await fetch(url.toString())
  const data = await res.json()
  if (!res.ok) throw new Error(data?.error ?? `request failed: ${res.status}`)
  return data as T
}

// POST for actions whose payload (e.g. a drawn geometry) is too big/complex for
// the query string. The Lambda router reads params from the JSON body too.
async function callPost<T>(body: Record<string, unknown>): Promise<T> {
  const res = await fetch(API_BASE, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const data = await res.json()
  if (!res.ok) throw new Error(data?.error ?? `request failed: ${res.status}`)
  return data as T
}

export function describeLayer(layer: string) {
  return call<DescribeLayerResult>({ action: 'describe-layer', layer })
}

export function getUniqueValues(layer: string, field: string, search = '', limit = 50) {
  const params: Record<string, string> = {
    action: 'unique-values',
    layer,
    field,
    limit: String(limit),
  }
  if (search) params.search = search
  return call<UniqueValuesResult>(params)
}

export function queryLayer(layer: string, where: string, recordCount = 1000) {
  return call<FeatureCollection>({
    action: 'query',
    layer,
    where,
    f: 'geojson',
    resultRecordCount: String(recordCount),
  })
}

// A spatial-query response: a FeatureCollection plus the buffered geometry that
// was intersected (so the map can outline the search area).
export type SpatialQueryResult = FeatureCollection & {
  layer: string
  count: number
  bufferMeters: number
  queryGeometry: unknown | null
}

// Find features in `layer` that intersect the drawn `geometry`, optionally
// buffered by `bufferMeters`. Sent as POST because the geometry can be large.
export function spatialQuery(layer: string, geometry: unknown, bufferMeters = 0) {
  return callPost<SpatialQueryResult>({
    action: 'spatial-query',
    layer,
    geometry,
    buffer: bufferMeters,
  })
}

// Fire-and-forget warm-up fired as the page loads, so the user's first real
// query doesn't eat the container cold start. Unlike a plain "ping", this runs
// an actual DuckDB query (describe-layer -> SELECT count(*) over the layer's
// parquet footer), which spins up the Lambda container AND exercises the
// DuckDB/httpfs path. A unique `id` (Date.now()) is attached to defeat any
// HTTP/CDN caching so the query always executes server-side. Best-effort: never
// throws, never blocks the UI. Note: this warms the container only — it does not
// pre-cache the large parcels GeoParquet, so the first parcels spatial query is
// still heavier than subsequent ones.
export function warmUp(layer: string): void {
  if (!layer) return
  const url = new URL(API_BASE)
  url.searchParams.set('action', 'describe-layer')
  url.searchParams.set('layer', layer)
  url.searchParams.set('id', String(Date.now())) // cache-buster — force a fresh run
  // keepalive lets the request survive if the user navigates quickly.
  fetch(url.toString(), { keepalive: true }).catch(() => {
    /* ignore — warm-up is best-effort */
  })
}


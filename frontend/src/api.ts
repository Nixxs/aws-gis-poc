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

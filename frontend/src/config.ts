import { useEffect, useState } from 'react'

export interface LayerConfig {
  id: string            // matches the pmtiles stem / tippecanoe source-layer
  label: string
  visibleByDefault: boolean
  opacity: number       // 0..1, applied to the polygon fill
  color: string         // hex, used for fill AND outline
  requiresAuth?: boolean // if true, only shown to logged-in users (MOCK gate)
  minZoom?: number      // only render/enable at/above this map zoom (e.g. dense
                        // layers like parcels that only make sense zoomed in)
  maxZoom?: number      // only render/enable below this map zoom
}

export interface BasemapConfig {
  id: string            // unique id, used as the map source/layer id
  label: string
  url: string           // raster tile URL template ({z}/{x}/{y}). For WMTS,
                        // use the GetTile template mapping {z}->TileMatrix,
                        // {x}->TileCol, {y}->TileRow.
  visibleByDefault: boolean
  attribution?: string  // shown in the map's attribution control
  tileSize?: number     // defaults to 256
  requiresAuth?: boolean // if true, only shown to logged-in users (MOCK gate)
}

export interface AppConfig {
  basemaps?: BasemapConfig[]
  layers: LayerConfig[]
}

// True when `zoom` falls inside a layer's allowed range. Mirrors MapLibre's
// own minzoom/maxzoom semantics (min inclusive, max exclusive) so the layer
// switcher's "greyed out" state matches what the map actually renders.
export function isLayerInZoomRange(
  layer: { minZoom?: number; maxZoom?: number },
  zoom: number,
): boolean {
  if (layer.minZoom != null && zoom < layer.minZoom) return false
  if (layer.maxZoom != null && zoom >= layer.maxZoom) return false
  return true
}

export async function loadConfig(): Promise<AppConfig> {
  // In prod this points at the hosted config.json in the app bucket
  // (VITE_CONFIG_URL); in local dev it falls back to public/config.json.
  // NOTE: use || not ?? — a blank VITE_CONFIG_URL is exposed as an empty
  // string (not undefined), and fetch('') would load index.html instead.
  const url = import.meta.env.VITE_CONFIG_URL || '/config.json'
  const res = await fetch(url)
  if (!res.ok) throw new Error(`Failed to load config.json: ${res.status}`)
  return res.json() as Promise<AppConfig>
}

export function useConfig() {
  const [config, setConfig] = useState<AppConfig | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    loadConfig().then(setConfig).catch((e) => setError(String(e)))
  }, [])

  return { config, error }
}
import { useEffect, useState } from 'react'

export interface LayerConfig {
  id: string            // matches the pmtiles stem / tippecanoe source-layer
  label: string
  visibleByDefault: boolean
  opacity: number       // 0..1, applied to the polygon fill
  color: string         // hex, used for fill AND outline
}

export interface AppConfig {
  layers: LayerConfig[]
}

export async function loadConfig(): Promise<AppConfig> {
  // In prod this points at the hosted config.json in the app bucket
  // (VITE_CONFIG_URL); in local dev it falls back to public/config.json.
  const url = import.meta.env.VITE_CONFIG_URL ?? '/config.json'
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
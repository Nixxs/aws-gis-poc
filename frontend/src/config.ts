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
  const res = await fetch('/config.json')   // served from public/
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
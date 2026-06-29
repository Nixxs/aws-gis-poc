import { useEffect, useRef } from 'react'
import maplibregl from 'maplibre-gl'
import { Protocol } from 'pmtiles'
import 'maplibre-gl/dist/maplibre-gl.css'
import type { AppConfig } from './config'
import { onLayerToggle } from './events'

// Register the pmtiles:// protocol ONCE, at module load — not per render.
const protocol = new Protocol()
maplibregl.addProtocol('pmtiles', protocol.tile)

const PMTILES_BASE = import.meta.env.VITE_PMTILES_BASE_URL

interface MapContainerProps {
  config: AppConfig
}

export default function MapContainer({ config }: MapContainerProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | null>(null)

  useEffect(() => {
    if (!containerRef.current) return

    const map = new maplibregl.Map({
      container: containerRef.current,
      style: {
        version: 8,
        sources: {
          osm: {
            type: 'raster',
            tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
            tileSize: 256,
            attribution: '© OpenStreetMap contributors',
          },
        },
        layers: [{ id: 'osm', type: 'raster', source: 'osm' }],
      },
      center: [144.9631, -37.8136], // Melbourne [lng, lat] — replaced by fitBounds below
      zoom: 8,
    })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    mapRef.current = map

    // Listen for layer toggles from the sidebar. For now just alert it.
    const unsubscribe = onLayerToggle((e) =>
      alert(`${e.name} turned ${e.visible ? 'on' : 'off'}`),
    )

    // Quiet safety net: surface any MapLibre style/tile errors in the console.
    map.on('error', (e) => console.error('[map error]', e.error ?? e))

    // Sources/layers can only be added AFTER the base style has loaded.
    map.on('load', () => {
      for (const layer of config.layers) {
        const url = `pmtiles://${PMTILES_BASE}${layer.id}.pmtiles`
        const initialVisibility = layer.visibleByDefault ? 'visible' : 'none'

        map.addSource(layer.id, { type: 'vector', url })

        // Translucent fill — opacity comes from config.
        map.addLayer({
          id: `${layer.id}-fill`,
          type: 'fill',
          source: layer.id,
          'source-layer': layer.id, // == tippecanoe -l name == file stem
          paint: {
            'fill-color': layer.color,
            'fill-opacity': layer.opacity,
          },
          layout: { visibility: initialVisibility },
        })

        // Solid outline — same colour, full opacity.
        map.addLayer({
          id: `${layer.id}-line`,
          type: 'line',
          source: layer.id,
          'source-layer': layer.id,
          paint: {
            'line-color': layer.color,
            'line-width': 1,
          },
          layout: { visibility: initialVisibility },
        })
      }
    })

    return () => {
      unsubscribe()
      map.remove()
      mapRef.current = null
    }
  }, [config])

  return <div ref={containerRef} style={{ width: '100%', height: '100%' }} />
}

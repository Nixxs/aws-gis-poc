import { useEffect, useRef } from 'react'
import maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'

export default function MapContainer() {
  // The <div> MapLibre draws into. ref = a stable handle to a DOM node.
  const containerRef = useRef<HTMLDivElement>(null)
  // The map instance itself. We keep it in a ref so it survives re-renders
  // WITHOUT triggering them (unlike useState).
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
            layers: [
                { id: 'osm', type: 'raster', source: 'osm' },
            ],
        },
        center: [144.9631, -37.8136], // Melbourne [lng, lat]
        zoom: 12,
    })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    mapRef.current = map

    // Cleanup: destroy the map when the component unmounts.
    return () => {
      map.remove()
      mapRef.current = null
    }
  }, []) // empty deps = run ONCE after first render

  return <div ref={containerRef} style={{ width: '100%', height: '100%' }} />
}
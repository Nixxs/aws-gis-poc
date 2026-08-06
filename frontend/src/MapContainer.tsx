import { useEffect, useRef } from 'react'
import maplibregl from 'maplibre-gl'
import { Protocol } from 'pmtiles'
import 'maplibre-gl/dist/maplibre-gl.css'
import type { AppConfig } from './config'
import { onLayerToggle, onQueryResult, onClearQuery } from './events'
import { GoToLatLngControl } from './GoToLatLngControl'

// Register the pmtiles:// protocol ONCE, at module load — not per render.
const protocol = new Protocol()
maplibregl.addProtocol('pmtiles', protocol.tile)

const PMTILES_BASE = import.meta.env.VITE_PMTILES_BASE_URL

// Walk any GeoJSON coordinate nesting and stretch the bounds to include it.
function extendBounds(bounds: maplibregl.LngLatBounds, coords: any) {
  if (typeof coords[0] === 'number') {
    bounds.extend(coords as [number, number])
  } else {
    for (const c of coords) extendBounds(bounds, c)
  }
}

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

    // "Find my location" — built-in geolocate control (top-left toolbar).
    // Uses the browser Geolocation API: on click it centres the map on the
    // user and drops a marker with an accuracy circle.
    map.addControl(
      new maplibregl.GeolocateControl({
        positionOptions: { enableHighAccuracy: true },
        trackUserLocation: true,   // keep the marker updated as the user moves
        showAccuracyCircle: true,
        showUserLocation: true,
      }),
      'top-left',
    )

    // "Go to lat/long" — custom control, sits next to the geolocate button.
    map.addControl(new GoToLatLngControl(), 'top-left')

    // Distance scale bar — bottom-left, metric units.
    map.addControl(
      new maplibregl.ScaleControl({ unit: 'metric' }),
      'bottom-left',
    )

    mapRef.current = map

    // Listen for layer toggles from the sidebar and flip visibility.
    const subs: Array<() => void> = []
    subs.push(onLayerToggle((e) => {
      const v = e.visible ? 'visible' : 'none'
      // Vector layers render as -fill/-line; basemap rasters use the bare id.
      for (const id of [`${e.id}-fill`, `${e.id}-line`, e.id]) {
        if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', v)
      }
    }))

    // Quiet safety net: surface any MapLibre style/tile errors in the console.
    map.on('error', (e) => console.error('[map error]', e.error ?? e))

    // Sources/layers can only be added AFTER the base style has loaded.
    map.on('load', () => {
      // Basemaps first so they sit BENEATH the vector data layers.
      for (const bm of config.basemaps ?? []) {
        map.addSource(bm.id, {
          type: 'raster',
          tiles: [bm.url],
          tileSize: bm.tileSize ?? 256,
          ...(bm.attribution ? { attribution: bm.attribution } : {}),
        })
        map.addLayer({
          id: bm.id,
          type: 'raster',
          source: bm.id,
          layout: { visibility: bm.visibleByDefault ? 'visible' : 'none' },
        })
      }

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

      // Click a feature -> show its attributes in a popup.
      const fillLayerIds = config.layers.map((l) => `${l.id}-fill`)
      map.on('click', fillLayerIds, (e) => {
        const feature = e.features?.[0]
        if (!feature) return

        // Highlight: rebuild a single outline layer matching the clicked feature.
        if (map.getLayer('highlight')) map.removeLayer('highlight')

        // A MapLibre filter is "match every property this feature has".
        // Start with 'all' (logical AND), then add one ['==', field, value] test per attribute.
        const attributes = feature.properties ?? {}
        const filter: any = ['all']
        for (const fieldName of Object.keys(attributes)) {
          const fieldValue = attributes[fieldName]
          filter.push(['==', ['get', fieldName], fieldValue])
        }

        map.addLayer({
          id: 'highlight',
          type: 'line',
          source: feature.source,
          'source-layer': feature.sourceLayer!,
          paint: { 'line-color': '#ffeb3b', 'line-width': 3 },
          filter,
        })

        const rows = Object.entries(feature.properties ?? {})
          .map(([k, v]) => `<tr><td><b>${k}</b></td><td>${v}</td></tr>`)
          .join('')
        const popup = new maplibregl.Popup({ maxWidth: '320px' })
          .setLngLat(e.lngLat)
          .setHTML(`<table>${rows}</table>`)
          .addTo(map)
        // Clear the highlight when the popup is dismissed.
        popup.on('close', () => { if (map.getLayer('highlight')) map.removeLayer('highlight') })
      })
      // Hint that features are clickable.
      map.on('mouseenter', fillLayerIds, () => (map.getCanvas().style.cursor = 'pointer'))
      map.on('mouseleave', fillLayerIds, () => (map.getCanvas().style.cursor = ''))

      // Query results: a GeoJSON source the QueryPanel feeds via events.
      const EMPTY = { type: 'FeatureCollection' as const, features: [] }
      map.addSource('query-result', { type: 'geojson', data: EMPTY })
      map.addLayer({
        id: 'query-result-fill',
        type: 'fill',
        source: 'query-result',
        paint: { 'fill-color': '#e91e63', 'fill-opacity': 0.35 },
      })
      map.addLayer({
        id: 'query-result-line',
        type: 'line',
        source: 'query-result',
        paint: { 'line-color': '#e91e63', 'line-width': 2 },
      })

      subs.push(onQueryResult((e) => {
        const source = map.getSource('query-result') as maplibregl.GeoJSONSource
        source.setData(e.geojson as any)
        // Zoom to the results.
        const bounds = new maplibregl.LngLatBounds()
        for (const f of e.geojson.features) {
          if (f.geometry) extendBounds(bounds, (f.geometry as any).coordinates)
        }
        if (!bounds.isEmpty()) map.fitBounds(bounds, { padding: 40, maxZoom: 14 })
      }))

      subs.push(onClearQuery(() => {
        const source = map.getSource('query-result') as maplibregl.GeoJSONSource
        source.setData(EMPTY as any)
      }))
    })

    return () => {
      subs.forEach((off) => off())
      map.remove()
      mapRef.current = null
    }
  }, [config])

  return <div ref={containerRef} style={{ width: '100%', height: '100%' }} />
}

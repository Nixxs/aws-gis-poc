import { useEffect, useRef } from 'react'
import maplibregl from 'maplibre-gl'
import { Protocol } from 'pmtiles'
import 'maplibre-gl/dist/maplibre-gl.css'
import type { AppConfig, LayerConfig, BasemapConfig } from './config'
import { useAuth } from './auth'
import { onLayerToggle, onQueryResult, onClearQuery } from './events'
import {
  onSpatialDrawStart, onSpatialDrawFinish, onSpatialDrawClear,
  onSpatialDrawGeometry, emitSpatialDrawComplete,
  emitFeatureSelect, onFeatureClear, onResultFeatureSelect,
} from './events'
import { createSpatialDraw, type SpatialDraw } from './spatialDraw'
import { GoToLatLngControl } from './GoToLatLngControl'

// Register the pmtiles:// protocol ONCE, at module load — not per render.
const protocol = new Protocol()
maplibregl.addProtocol('pmtiles', protocol.tile)

const PMTILES_BASE = import.meta.env.VITE_PMTILES_BASE_URL

// Add a vector (PMTiles) layer's source + fill + line. Idempotent.
function addVectorLayer(map: maplibregl.Map, layer: LayerConfig, layers: LayerConfig[]) {
  if (map.getSource(layer.id)) return
  const url = `pmtiles://${PMTILES_BASE}${layer.id}.pmtiles`
  const visibility = layer.visibleByDefault ? 'visible' : 'none'
  // Preserve config order as Z-order: earlier in config = higher on the map.
  // Insert beneath the fill of the closest data layer ABOVE this one (smaller
  // index) that's on the map; if none, sit just beneath the query-result
  // highlight (i.e. at the top of the data stack, above the basemaps).
  const index = layers.findIndex((l) => l.id === layer.id)
  let beforeId: string | undefined
  for (let i = index - 1; i >= 0; i--) {
    if (map.getLayer(`${layers[i].id}-fill`)) { beforeId = `${layers[i].id}-fill`; break }
  }
  if (!beforeId && map.getLayer('query-result-fill')) beforeId = 'query-result-fill'

  map.addSource(layer.id, { type: 'vector', url })
  map.addLayer({
    id: `${layer.id}-fill`,
    type: 'fill',
    source: layer.id,
    'source-layer': layer.id, // == tippecanoe -l name == file stem
    paint: {
      'fill-color': layer.color,
      'fill-opacity': layer.opacity,
    },
    layout: { visibility },
  }, beforeId)
  map.addLayer({
    id: `${layer.id}-line`,
    type: 'line',
    source: layer.id,
    'source-layer': layer.id,
    paint: {
      'line-color': layer.color,
      'line-width': 1,
    },
    layout: { visibility },
  }, beforeId)
}

// Remove a vector layer's fill + line + source. Idempotent.
function removeVectorLayer(map: maplibregl.Map, layer: LayerConfig) {
  for (const id of [`${layer.id}-fill`, `${layer.id}-line`]) {
    if (map.getLayer(id)) map.removeLayer(id)
  }
  if (map.getSource(layer.id)) map.removeSource(layer.id)
}

// Add a raster basemap source + layer. Idempotent. Inserts beneath the data
// layers so basemaps never cover the vector features, AND preserves config
// order as Z-order: earlier in config = higher on the map.
function addRasterBasemap(map: maplibregl.Map, bm: BasemapConfig, basemaps: BasemapConfig[]) {
  if (map.getSource(bm.id)) return
  map.addSource(bm.id, {
    type: 'raster',
    tiles: [bm.url],
    tileSize: bm.tileSize ?? 256,
    ...(bm.attribution ? { attribution: bm.attribution } : {}),
  })
  // Insert directly beneath the closest basemap ABOVE this one in config (a
  // smaller index) that's currently on the map. If none, sit just beneath the
  // first data/query layer (i.e. at the top of the basemap stack).
  const index = basemaps.findIndex((b) => b.id === bm.id)
  let beforeId: string | undefined
  for (let i = index - 1; i >= 0; i--) {
    if (map.getLayer(basemaps[i].id)) { beforeId = basemaps[i].id; break }
  }
  if (!beforeId) {
    const layers = map.getStyle().layers ?? []
    beforeId = layers.find(
      (l) => l.id.endsWith('-fill') || l.id.endsWith('-line') || l.id.startsWith('query-result'),
    )?.id
  }
  map.addLayer({
    id: bm.id,
    type: 'raster',
    source: bm.id,
    layout: { visibility: bm.visibleByDefault ? 'visible' : 'none' },
  }, beforeId)
}

// Remove a raster basemap's layer + source. Idempotent.
function removeRasterBasemap(map: maplibregl.Map, bm: BasemapConfig) {
  if (map.getLayer(bm.id)) map.removeLayer(bm.id)
  if (map.getSource(bm.id)) map.removeSource(bm.id)
}

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
  const { user } = useAuth()

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
      // The spatial-draw tool is created after the query-result layers below so
      // its shapes sit on top; declared here so the popup handler can defer to it.
      let draw: SpatialDraw | null = null

      // Basemaps first so they sit BENEATH the vector data layers.
      for (const bm of config.basemaps ?? []) {
        if (bm.requiresAuth) continue // auth-gated basemaps handled by a separate effect
        addRasterBasemap(map, bm, config.basemaps ?? [])
      }

      for (const layer of config.layers) {
        if (layer.requiresAuth) continue // auth-gated layers handled by a separate effect
        addVectorLayer(map, layer, config.layers)
      }

      // Click a feature -> show its attributes in a popup.
      const fillLayerIds = config.layers.map((l) => `${l.id}-fill`)
      map.on('click', fillLayerIds, (e) => {
        // While the user is drawing a spatial query, clicks add vertices, not popups.
        if (draw?.isActive()) return
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

        // Show the attributes in the docked FeatureInfoPanel (not a popup).
        emitFeatureSelect({
          layer: String(feature.source),
          properties: feature.properties ?? {},
        })
      })
      // Hint that features are clickable — but not while drawing (keep the crosshair).
      map.on('mouseenter', fillLayerIds, () => {
        if (draw?.isActive()) return
        map.getCanvas().style.cursor = 'pointer'
      })
      map.on('mouseleave', fillLayerIds, () => {
        if (draw?.isActive()) return
        map.getCanvas().style.cursor = ''
      })

      // Panel dismissed -> drop the highlight outline.
      subs.push(onFeatureClear(() => {
        if (map.getLayer('highlight')) map.removeLayer('highlight')
      }))

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

      // A single highlighted result (from clicking a row in the attribute table).
      map.addSource('result-highlight', { type: 'geojson', data: EMPTY })
      map.addLayer({
        id: 'result-highlight-fill',
        type: 'fill',
        source: 'result-highlight',
        paint: { 'fill-color': '#ffeb3b', 'fill-opacity': 0.4 },
      })
      map.addLayer({
        id: 'result-highlight-line',
        type: 'line',
        source: 'result-highlight',
        paint: { 'line-color': '#ffeb3b', 'line-width': 3 },
      })

      const clearResultHighlight = () => {
        const src = map.getSource('result-highlight') as maplibregl.GeoJSONSource
        src?.setData(EMPTY as any)
      }

      subs.push(onQueryResult((e) => {
        const source = map.getSource('query-result') as maplibregl.GeoJSONSource
        source.setData(e.geojson as any)
        clearResultHighlight() // a fresh result set clears any previous row highlight
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
        clearResultHighlight()
      }))

      // Click a row in the attribute table -> highlight that feature and pan to it.
      subs.push(onResultFeatureSelect((e) => {
        const geometry = e.feature?.geometry as any
        if (!geometry) return
        const src = map.getSource('result-highlight') as maplibregl.GeoJSONSource
        src.setData({ type: 'FeatureCollection', features: [e.feature as any] } as any)

        const bounds = new maplibregl.LngLatBounds()
        extendBounds(bounds, geometry.coordinates)
        if (bounds.isEmpty()) return
        // A point has zero-area bounds; ease to it at a sensible zoom instead.
        if (geometry.type === 'Point') {
          map.easeTo({ center: bounds.getCenter(), zoom: Math.max(map.getZoom(), 15) })
        } else {
          map.fitBounds(bounds, { padding: 60, maxZoom: 16 })
        }
      }))

      // Spatial-draw tool: the SpatialQueryPanel drives it over the event bus.
      // Added last so its point/line/fill sit above the query-result highlight.
      draw = createSpatialDraw(map, (geometry) => emitSpatialDrawComplete({ geometry }))
      subs.push(onSpatialDrawStart((e) => draw?.start(e.mode)))
      subs.push(onSpatialDrawFinish(() => draw?.finish()))
      subs.push(onSpatialDrawClear(() => draw?.clear()))
      subs.push(onSpatialDrawGeometry((e) => draw?.showGeometry(e.geometry)))
    })

    return () => {
      subs.forEach((off) => off())
      map.remove()
      mapRef.current = null
    }
  }, [config])

  // React to auth changes: add auth-gated layers on login, remove on logout —
  // without rebuilding the whole map. (MOCK gate: visibility only, not security.)
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    const apply = () => {
      for (const layer of config.layers) {
        if (!layer.requiresAuth) continue
        if (user) addVectorLayer(map, layer, config.layers)
        else removeVectorLayer(map, layer)
      }
      for (const bm of config.basemaps ?? []) {
        if (!bm.requiresAuth) continue
        if (user) addRasterBasemap(map, bm, config.basemaps ?? [])
        else removeRasterBasemap(map, bm)
      }
    }
    if (map.isStyleLoaded()) apply()
    else map.once('load', apply)
  }, [user, config])

  return <div ref={containerRef} style={{ width: '100%', height: '100%' }} />
}

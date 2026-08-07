// A tiny draw tool for the spatial query: lets the user drop a point or trace a
// polygon on the map, with no extra dependency. It owns one GeoJSON source and a
// fill/line/point layer trio, and reports the finished geometry via onComplete.
import maplibregl from 'maplibre-gl'
import type { DrawGeometry } from './events'

const SRC = 'spatial-draw'
const FILL = 'spatial-draw-fill'
const LINE = 'spatial-draw-line'
const PT = 'spatial-draw-point'
const EMPTY = { type: 'FeatureCollection', features: [] as unknown[] }

export type DrawMode = 'point' | 'polygon'

export interface SpatialDraw {
  start(mode: DrawMode): void
  finish(): void
  clear(): void
  showGeometry(geometry: DrawGeometry): void
  isActive(): boolean
  destroy(): void
}

export function createSpatialDraw(
  map: maplibregl.Map,
  onComplete: (geometry: DrawGeometry) => void,
): SpatialDraw {
  let mode: DrawMode | null = null
  let coords: [number, number][] = []

  if (!map.getSource(SRC)) {
    map.addSource(SRC, { type: 'geojson', data: EMPTY as never })
    map.addLayer({
      id: FILL, type: 'fill', source: SRC,
      filter: ['==', ['geometry-type'], 'Polygon'],
      paint: { 'fill-color': '#1976d2', 'fill-opacity': 0.15 },
    })
    map.addLayer({
      id: LINE, type: 'line', source: SRC,
      paint: { 'line-color': '#1976d2', 'line-width': 2, 'line-dasharray': [2, 1] },
    })
    map.addLayer({
      id: PT, type: 'circle', source: SRC,
      filter: ['==', ['geometry-type'], 'Point'],
      paint: {
        'circle-radius': 5, 'circle-color': '#1976d2',
        'circle-stroke-color': '#ffffff', 'circle-stroke-width': 2,
      },
    })
  }

  const source = () => map.getSource(SRC) as maplibregl.GeoJSONSource

  const setFeatures = (features: unknown[]) =>
    source().setData({ type: 'FeatureCollection', features } as never)

  // Render the in-progress polygon: vertices + running line + preview fill.
  function renderProgress() {
    const features: unknown[] = coords.map((c) => ({
      type: 'Feature', geometry: { type: 'Point', coordinates: c }, properties: {},
    }))
    if (coords.length >= 2) {
      features.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: coords }, properties: {} })
    }
    if (coords.length >= 3) {
      features.push({
        type: 'Feature',
        geometry: { type: 'Polygon', coordinates: [[...coords, coords[0]]] },
        properties: {},
      })
    }
    setFeatures(features)
  }

  function showGeometry(geometry: DrawGeometry) {
    setFeatures([{ type: 'Feature', geometry, properties: {} }])
  }

  function stop() {
    mode = null
    coords = []
    map.getCanvas().style.cursor = ''
    map.doubleClickZoom.enable()
  }

  function onClick(e: maplibregl.MapMouseEvent) {
    if (!mode) return
    const c: [number, number] = [e.lngLat.lng, e.lngLat.lat]
    if (mode === 'point') {
      const geometry: DrawGeometry = { type: 'Point', coordinates: c }
      showGeometry(geometry)
      stop()
      onComplete(geometry)
      return
    }
    coords.push(c)
    renderProgress()
  }

  function start(next: DrawMode) {
    clear()
    mode = next
    map.getCanvas().style.cursor = 'crosshair'
    if (next === 'polygon') map.doubleClickZoom.disable()
  }

  function finish() {
    if (mode !== 'polygon' || coords.length < 3) return
    const geometry: DrawGeometry = {
      type: 'Polygon', coordinates: [[...coords, coords[0]]],
    }
    showGeometry(geometry)
    stop()
    onComplete(geometry)
  }

  function clear() {
    stop()
    setFeatures([])
  }

  map.on('click', onClick)

  return {
    start,
    finish,
    clear,
    showGeometry,
    isActive: () => mode !== null,
    destroy() {
      map.off('click', onClick)
      for (const id of [FILL, LINE, PT]) if (map.getLayer(id)) map.removeLayer(id)
      if (map.getSource(SRC)) map.removeSource(SRC)
    },
  }
}

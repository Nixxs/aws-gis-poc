// Event bus built on mitt — a tiny (~200B), well-tested emitter.
// We keep our own emit/on wrappers so the rest of the app stays decoupled
// from the library: if we ever swap mitt out, only this file changes.
import mitt from 'mitt'
import type { FeatureCollection } from './api'

export interface LayerToggleEvent {
  id: string        // the layer that was switched (matches config + map layer id)
  visible: boolean  // true = turned on, false = turned off
}

export interface QueryResultEvent {
  layer: string                 // the layer that was queried
  geojson: FeatureCollection    // features to draw on the map
}

// The map of event-name -> payload type. Add more events here later.
type Events = {
  layerToggle: LayerToggleEvent
  queryResult: QueryResultEvent
  clearQuery: void
}

const bus = mitt<Events>()

export function emitLayerToggle(event: LayerToggleEvent) {
  bus.emit('layerToggle', event)
}

export function onLayerToggle(fn: (e: LayerToggleEvent) => void): () => void {
  bus.on('layerToggle', fn)
  return () => bus.off('layerToggle', fn) // call this to stop listening
}

export function emitQueryResult(event: QueryResultEvent) {
  bus.emit('queryResult', event)
}

export function onQueryResult(fn: (e: QueryResultEvent) => void): () => void {
  bus.on('queryResult', fn)
  return () => bus.off('queryResult', fn)
}

export function emitClearQuery() {
  bus.emit('clearQuery')
}

export function onClearQuery(fn: () => void): () => void {
  bus.on('clearQuery', fn)
  return () => bus.off('clearQuery', fn)
}

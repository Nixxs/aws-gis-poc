// Event bus built on mitt — a tiny (~200B), well-tested emitter.
// We keep our own emit/on wrappers so the rest of the app stays decoupled
// from the library: if we ever swap mitt out, only this file changes.
import mitt from 'mitt'

export interface LayerToggleEvent {
  id: string        // the layer that was switched (matches config + map layer id)
  visible: boolean  // true = turned on, false = turned off
}

// The map of event-name -> payload type. Add more events here later.
type Events = {
  layerToggle: LayerToggleEvent
}

const bus = mitt<Events>()

export function emitLayerToggle(event: LayerToggleEvent) {
  bus.emit('layerToggle', event)
}

export function onLayerToggle(fn: (e: LayerToggleEvent) => void): () => void {
  bus.on('layerToggle', fn)
  return () => bus.off('layerToggle', fn) // call this to stop listening
}

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

// Results from a single action that queried several layers at once (e.g. the
// buffer-intersect tool). Each entry becomes its own tab in the attribute table.
export interface QueryResultMultiEvent {
  results: Array<{ layer: string; label?: string; geojson: FeatureCollection }>
}

export interface FeatureSelectEvent {
  layer: string                          // the layer/source the feature belongs to
  properties: Record<string, unknown>    // the clicked feature's attributes
}

export interface ResultFeatureSelectEvent {
  feature: FeatureCollection['features'][number]  // a result row to highlight + pan to
}

// A loose GeoJSON geometry — enough for the draw tool and spatial query.
export type DrawGeometry = {
  type: string
  coordinates?: unknown
  geometries?: unknown[]
}

export interface SpatialDrawStartEvent {
  mode: 'point' | 'polygon'     // what shape the user is about to draw
}

export interface SpatialDrawGeometryEvent {
  geometry: DrawGeometry        // a geometry to display (drawn shape or buffer)
}

export interface MapZoomEvent {
  zoom: number                  // the map's current zoom level
}

// The map of event-name -> payload type. Add more events here later.
type Events = {
  layerToggle: LayerToggleEvent
  queryResult: QueryResultEvent
  queryResultMulti: QueryResultMultiEvent   // buffer-intersect: many layers -> tabs
  clearQuery: void
  featureSelect: FeatureSelectEvent         // map -> panel: a feature was clicked
  featureClear: void                        // panel -> map: dismiss the selection
  resultFeatureSelect: ResultFeatureSelectEvent // table -> map: highlight + pan to a result
  spatialDrawStart: SpatialDrawStartEvent   // panel -> map: begin drawing
  spatialDrawFinish: void                   // panel -> map: close the polygon
  spatialDrawClear: void                    // panel -> map: erase the drawing
  spatialDrawComplete: SpatialDrawGeometryEvent // map -> panel: a shape was drawn
  spatialDrawGeometry: SpatialDrawGeometryEvent // panel -> map: show this geometry (buffer)
  mapZoom: MapZoomEvent                     // map -> sidebar: current zoom changed
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

export function emitQueryResultMulti(event: QueryResultMultiEvent) {
  bus.emit('queryResultMulti', event)
}

export function onQueryResultMulti(fn: (e: QueryResultMultiEvent) => void): () => void {
  bus.on('queryResultMulti', fn)
  return () => bus.off('queryResultMulti', fn)
}

export function emitClearQuery() {
  bus.emit('clearQuery')
}

export function onClearQuery(fn: () => void): () => void {
  bus.on('clearQuery', fn)
  return () => bus.off('clearQuery', fn)
}

// --- feature click / info panel -------------------------------------------

export function emitFeatureSelect(event: FeatureSelectEvent) {
  bus.emit('featureSelect', event)
}

export function onFeatureSelect(fn: (e: FeatureSelectEvent) => void): () => void {
  bus.on('featureSelect', fn)
  return () => bus.off('featureSelect', fn)
}

export function emitFeatureClear() {
  bus.emit('featureClear')
}

export function onFeatureClear(fn: () => void): () => void {
  bus.on('featureClear', fn)
  return () => bus.off('featureClear', fn)
}

// --- results table row -> map --------------------------------------------

export function emitResultFeatureSelect(event: ResultFeatureSelectEvent) {
  bus.emit('resultFeatureSelect', event)
}

export function onResultFeatureSelect(fn: (e: ResultFeatureSelectEvent) => void): () => void {
  bus.on('resultFeatureSelect', fn)
  return () => bus.off('resultFeatureSelect', fn)
}

// --- spatial draw ---------------------------------------------------------

export function emitSpatialDrawStart(event: SpatialDrawStartEvent) {
  bus.emit('spatialDrawStart', event)
}

export function onSpatialDrawStart(fn: (e: SpatialDrawStartEvent) => void): () => void {
  bus.on('spatialDrawStart', fn)
  return () => bus.off('spatialDrawStart', fn)
}

export function emitSpatialDrawFinish() {
  bus.emit('spatialDrawFinish')
}

export function onSpatialDrawFinish(fn: () => void): () => void {
  bus.on('spatialDrawFinish', fn)
  return () => bus.off('spatialDrawFinish', fn)
}

export function emitSpatialDrawClear() {
  bus.emit('spatialDrawClear')
}

export function onSpatialDrawClear(fn: () => void): () => void {
  bus.on('spatialDrawClear', fn)
  return () => bus.off('spatialDrawClear', fn)
}

export function emitSpatialDrawComplete(event: SpatialDrawGeometryEvent) {
  bus.emit('spatialDrawComplete', event)
}

export function onSpatialDrawComplete(fn: (e: SpatialDrawGeometryEvent) => void): () => void {
  bus.on('spatialDrawComplete', fn)
  return () => bus.off('spatialDrawComplete', fn)
}

export function emitSpatialDrawGeometry(event: SpatialDrawGeometryEvent) {
  bus.emit('spatialDrawGeometry', event)
}

export function onSpatialDrawGeometry(fn: (e: SpatialDrawGeometryEvent) => void): () => void {
  bus.on('spatialDrawGeometry', fn)
  return () => bus.off('spatialDrawGeometry', fn)
}

// --- map zoom -> sidebar --------------------------------------------------

export function emitMapZoom(event: MapZoomEvent) {
  bus.emit('mapZoom', event)
}

export function onMapZoom(fn: (e: MapZoomEvent) => void): () => void {
  bus.on('mapZoom', fn)
  return () => bus.off('mapZoom', fn)
}

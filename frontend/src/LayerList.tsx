import { useState, useEffect } from 'react'
import {
  List, ListItem, ListItemText, ListItemIcon,
  Switch, Typography, Box, Tooltip,
} from '@mui/material'
import { useConfig, isLayerInZoomRange } from './config'
import { useAuth } from './auth'
import { emitLayerToggle, onMapZoom } from './events'

export default function LayerList() {
  const { config, error } = useConfig()
  const { user } = useAuth()
  const [visible, setVisible] = useState<Record<string, boolean>>({})
  const [zoom, setZoom] = useState(0)

  // Track the map's current zoom so we can grey out layers that are outside
  // their configured min/max zoom range.
  useEffect(() => onMapZoom((e) => setZoom(e.zoom)), [])

  // Seed the on/off state once the config arrives (basemaps + data layers).
  useEffect(() => {
    if (!config) return
    const all = [...(config.basemaps ?? []), ...config.layers]
    setVisible(
      Object.fromEntries(all.map((l) => [l.id, l.visibleByDefault])),
    )
  }, [config])

  const toggle = (id: string) =>
    setVisible((prev) => {
      const next = !prev[id]
      emitLayerToggle({ id, visible: next })
      return { ...prev, [id]: next }
    })

  if (error) return <Typography color="error" sx={{ p: 2 }}>{error}</Typography>
  if (!config) return <Typography sx={{ p: 2 }}>Loading layers…</Typography>

  // Auth-gated basemaps hide when signed out (same rule as data layers).
  const visibleBasemaps = (config.basemaps ?? []).filter(
    (b) => !b.requiresAuth || user,
  )

  // Explain why a layer is greyed out, so the tooltip is actionable.
  const zoomHint = (item: { minZoom?: number; maxZoom?: number }): string => {
    if (item.minZoom != null && zoom < item.minZoom) {
      return `Zoom in to level ${item.minZoom} to view this layer (currently ${zoom.toFixed(1)})`
    }
    if (item.maxZoom != null && zoom >= item.maxZoom) {
      return `Zoom out below level ${item.maxZoom} to view this layer (currently ${zoom.toFixed(1)})`
    }
    return ''
  }

  // Render a toggle row for each item. `color` is optional (basemaps have none);
  // `minZoom`/`maxZoom` are optional (only data layers restrict by zoom).
  const renderItems = (
    items: Array<{ id: string; label: string; color?: string; minZoom?: number; maxZoom?: number }>,
  ) => (
    <List dense>
      {items.map((item) => {
        const inRange = isLayerInZoomRange(item, zoom)
        const row = (
          <ListItem
            key={item.id}
            disablePadding
            sx={{ px: 1, opacity: inRange ? 1 : 0.4 }}
          >
            <ListItemIcon sx={{ minWidth: 0 }}>
              <Switch
                edge="start"
                size="small"
                checked={visible[item.id] ?? false}
                onChange={() => toggle(item.id)}
              />
            </ListItemIcon>
            {/* colour swatch so you can see each layer's colour */}
            {item.color && (
              <Box
                sx={{
                  width: 14, height: 14, mr: 1, borderRadius: '2px',
                  bgcolor: item.color, flexShrink: 0,
                }}
              />
            )}
            <ListItemText primary={item.label} />
          </ListItem>
        )
        // Wrap greyed-out rows in a tooltip explaining the zoom requirement.
        return inRange ? row : (
          <Tooltip key={item.id} title={zoomHint(item)} placement="right" arrow>
            {row}
          </Tooltip>
        )
      })}
    </List>
  )

  return (
    <>
      <Typography variant="overline" sx={{ px: 2, color: 'text.secondary' }}>
        Layers
      </Typography>
      {renderItems(config.layers.filter((l) => !l.requiresAuth || user))}

      {visibleBasemaps.length > 0 && (
        <>
          <Typography variant="overline" sx={{ px: 2, color: 'text.secondary' }}>
            Basemaps
          </Typography>
          {renderItems(visibleBasemaps)}
        </>
      )}
    </>
  )
}
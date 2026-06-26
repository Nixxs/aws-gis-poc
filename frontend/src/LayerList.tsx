import { useState, useEffect } from 'react'
import {
  List, ListItem, ListItemText, ListItemIcon,
  Switch, Typography, Box,
} from '@mui/material'
import { useConfig } from './config'

export default function LayerList() {
  const { config, error } = useConfig()
  const [visible, setVisible] = useState<Record<string, boolean>>({})

  // Seed the on/off state once the config arrives.
  useEffect(() => {
    if (!config) return
    setVisible(
      Object.fromEntries(config.layers.map((l) => [l.id, l.visibleByDefault])),
    )
  }, [config])

  const toggle = (id: string) =>
    setVisible((prev) => ({ ...prev, [id]: !prev[id] }))

  if (error) return <Typography color="error" sx={{ p: 2 }}>{error}</Typography>
  if (!config) return <Typography sx={{ p: 2 }}>Loading layers…</Typography>

  return (
    <>
      <Typography variant="overline" sx={{ px: 2, color: 'text.secondary' }}>
        Layers
      </Typography>
      <List dense>
        {config.layers.map((layer) => (
          <ListItem key={layer.id} disablePadding sx={{ px: 1 }}>
            <ListItemIcon sx={{ minWidth: 0 }}>
              <Switch
                edge="start"
                size="small"
                checked={visible[layer.id] ?? false}
                onChange={() => toggle(layer.id)}
              />
            </ListItemIcon>
            {/* colour swatch so you can see each layer's colour */}
            <Box
              sx={{
                width: 14, height: 14, mr: 1, borderRadius: '2px',
                bgcolor: layer.color, flexShrink: 0,
              }}
            />
            <ListItemText primary={layer.label} />
          </ListItem>
        ))}
      </List>
    </>
  )
}
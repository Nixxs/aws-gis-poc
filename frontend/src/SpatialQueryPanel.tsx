import { useEffect, useMemo, useState } from 'react'
import {
  Box, Typography, TextField, MenuItem,
  Button, Stack, CircularProgress, Alert, Collapse, IconButton,
} from '@mui/material'
import ExpandMoreIcon from '@mui/icons-material/ExpandMore'
import ExpandLessIcon from '@mui/icons-material/ExpandLess'
import { useConfig } from './config'
import { useAuth } from './auth'
import { spatialQuery } from './api'
import {
  emitSpatialDrawStart, emitSpatialDrawFinish, emitSpatialDrawClear,
  onSpatialDrawComplete, emitSpatialDrawGeometry,
  emitQueryResult, emitClearQuery, type DrawGeometry,
} from './events'

// The UI intentionally hides the buffer distance; the route still takes it, so
// we send a fixed buffer here. Set to 0 for a pure intersect (no buffering).
const DEFAULT_BUFFER_METERS = 0

export default function SpatialQueryPanel() {
  const { config } = useConfig()
  const { user } = useAuth()

  // Same auth-aware layer list the QueryPanel uses (config-driven, with labels).
  const availableLayers = useMemo(
    () => config?.layers.filter((l) => !l.requiresAuth || user) ?? [],
    [config, user],
  )

  const [layer, setLayer] = useState('')
  const [open, setOpen] = useState(false)
  const [geometry, setGeometry] = useState<DrawGeometry | null>(null)
  const [drawingPolygon, setDrawingPolygon] = useState(false)
  const [running, setRunning] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [resultCount, setResultCount] = useState<number | null>(null)

  // Drop the selection if the layer becomes unavailable (e.g. user logs out).
  useEffect(() => {
    if (layer && !availableLayers.some((l) => l.id === layer)) setLayer('')
  }, [availableLayers, layer])

  // The map reports back the finished shape here.
  useEffect(() => {
    return onSpatialDrawComplete((e) => {
      setGeometry(e.geometry)
      setDrawingPolygon(false)
    })
  }, [])

  const beginDraw = (mode: 'point' | 'polygon') => {
    setError(null)
    setResultCount(null)
    setGeometry(null)
    emitSpatialDrawClear()
    emitSpatialDrawStart({ mode })
    setDrawingPolygon(mode === 'polygon')
  }

  const finishPolygon = () => emitSpatialDrawFinish()

  const canRun = Boolean(layer) && Boolean(geometry) && !running && !drawingPolygon

  const run = async () => {
    if (!layer || !geometry) return
    setRunning(true)
    setError(null)
    setResultCount(null)
    try {
      const result = await spatialQuery(layer, geometry, DEFAULT_BUFFER_METERS)
      setResultCount(result.features.length)
      emitQueryResult({ layer, geojson: result })
      // Outline the buffered search area the server actually used.
      if (result.queryGeometry) {
        emitSpatialDrawGeometry({ geometry: result.queryGeometry as DrawGeometry })
      }
    } catch (e: any) {
      setError(String(e.message ?? e))
    } finally {
      setRunning(false)
    }
  }

  const clear = () => {
    emitClearQuery()
    emitSpatialDrawClear()
    setGeometry(null)
    setDrawingPolygon(false)
    setResultCount(null)
    setError(null)
  }

  const status = drawingPolygon
    ? 'Click the map to add points, then Finish.'
    : geometry?.type === 'Point'
      ? 'Point selected.'
      : geometry?.type === 'Polygon'
        ? 'Polygon selected.'
        : 'Draw a point or polygon on the map.'

  return (
    <Box>
      <Box
        onClick={() => setOpen((o) => !o)}
        sx={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          cursor: 'pointer', userSelect: 'none',
        }}
      >
        <Typography variant="overline" sx={{ color: 'text.secondary' }}>
          Spatial query
        </Typography>
        <IconButton size="small" aria-label={open ? 'Collapse spatial query' : 'Expand spatial query'}>
          {open ? <ExpandLessIcon fontSize="small" /> : <ExpandMoreIcon fontSize="small" />}
        </IconButton>
      </Box>

      <Collapse in={open}>
      <Stack spacing={1.5} sx={{ mt: 1 }}>
        {/* 1. Layer */}
        <TextField
          select size="small" label="Layer"
          value={layer} onChange={(e) => setLayer(e.target.value)}
        >
          {config?.layers?.length
            ? availableLayers.map((l) => (
                <MenuItem key={l.id} value={l.id}>{l.label}</MenuItem>
              ))
            : <MenuItem disabled value="">Loading layers…</MenuItem>}
        </TextField>

        {/* 2. Draw controls */}
        <Stack direction="row" spacing={1}>
          <Button
            variant="outlined" size="small" fullWidth
            onClick={() => beginDraw('point')} disabled={running}
          >
            Point
          </Button>
          <Button
            variant="outlined" size="small" fullWidth
            onClick={() => beginDraw('polygon')} disabled={running}
          >
            Polygon
          </Button>
        </Stack>

        {drawingPolygon && (
          <Stack direction="row" spacing={1}>
            <Button variant="contained" size="small" fullWidth onClick={finishPolygon}>
              Finish
            </Button>
            <Button variant="text" size="small" fullWidth onClick={clear}>
              Cancel
            </Button>
          </Stack>
        )}

        <Typography variant="caption" sx={{ color: 'text.secondary' }}>
          {status}
        </Typography>

        {/* 3. Run / clear */}
        <Stack direction="row" spacing={1}>
          <Button
            variant="contained" size="small" onClick={run} disabled={!canRun}
            startIcon={running ? <CircularProgress size={16} color="inherit" /> : undefined}
          >
            Run spatial query
          </Button>
          <Button variant="outlined" size="small" onClick={clear}>Clear</Button>
        </Stack>

        <Typography variant="caption" sx={{ color: 'text.secondary' }}>
          {DEFAULT_BUFFER_METERS > 0
            ? `Finds features within ${DEFAULT_BUFFER_METERS} m of your selection.`
            : 'Finds features that intersect your selection.'}
        </Typography>

        {error && <Alert severity="error">{error}</Alert>}
        {resultCount !== null && !error && (
          <Alert severity={resultCount ? 'success' : 'info'}>
            {resultCount} feature{resultCount === 1 ? '' : 's'} found
          </Alert>
        )}
      </Stack>
      </Collapse>
    </Box>
  )
}

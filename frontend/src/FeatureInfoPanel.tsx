import { useEffect, useMemo, useState } from 'react'
import {
  Box, Paper, Typography, IconButton, Table, TableBody, TableCell,
  TableContainer, TableRow, Tooltip,
} from '@mui/material'
import CloseIcon from '@mui/icons-material/Close'
import { onFeatureSelect, emitFeatureClear } from './events'
import { useConfig } from './config'

// Turn any property value into something printable in a table cell.
function formatValue(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

export default function FeatureInfoPanel() {
  const { config } = useConfig()
  const [layer, setLayer] = useState('')
  const [properties, setProperties] = useState<Record<string, unknown> | null>(null)

  useEffect(() => {
    return onFeatureSelect((e) => {
      setLayer(e.layer)
      setProperties(e.properties)
    })
  }, [])

  // Friendly layer name if we have it in config; otherwise the raw source id.
  const title = useMemo(() => {
    const match = config?.layers.find((l) => l.id === layer)
    return match?.label ?? layer
  }, [config, layer])

  const rows = useMemo(
    () => (properties ? Object.entries(properties) : []),
    [properties],
  )

  const close = () => {
    setProperties(null)
    emitFeatureClear() // tell the map to drop its highlight outline
  }

  if (!properties) return null

  return (
    <Paper
      elevation={6}
      sx={{
        position: 'absolute',
        // --- tweak these two to reposition the panel ---
        top: 10,        // distance from the top of the map
        right: 52,      // clears the top-right nav control (~40px) so we sit to its LEFT
        // ------------------------------------------------
        width: 300,
        maxHeight: 'calc(100% - 100px)',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
        zIndex: 5,
      }}
    >
      {/* Header bar */}
      <Box
        sx={{
          display: 'flex',
          alignItems: 'center',
          gap: 1,
          px: 1.5,
          py: 0.5,
          borderBottom: 1,
          borderColor: 'divider',
          bgcolor: 'grey.100',
        }}
      >
        <Typography variant="subtitle2" sx={{ flexGrow: 1 }} noWrap title={title}>
          {title}
        </Typography>
        <Tooltip title="Close">
          <IconButton size="small" onClick={close}>
            <CloseIcon fontSize="small" />
          </IconButton>
        </Tooltip>
      </Box>

      {/* Field / value table */}
      <TableContainer sx={{ overflow: 'auto' }}>
        <Table size="small">
          <TableBody>
            {rows.map(([key, value]) => (
              <TableRow key={key} hover>
                <TableCell
                  sx={{ fontWeight: 600, verticalAlign: 'top', width: '40%', wordBreak: 'break-word' }}
                >
                  {key}
                </TableCell>
                <TableCell sx={{ wordBreak: 'break-word' }}>{formatValue(value)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>
    </Paper>
  )
}

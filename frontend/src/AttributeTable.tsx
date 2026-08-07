import { useEffect, useMemo, useState } from 'react'
import {
  Box, Paper, Typography, IconButton, Table, TableBody, TableCell,
  TableContainer, TableHead, TableRow, Tooltip,
} from '@mui/material'
import CloseIcon from '@mui/icons-material/Close'
import UnfoldLessIcon from '@mui/icons-material/UnfoldLess'
import UnfoldMoreIcon from '@mui/icons-material/UnfoldMore'
import { onQueryResult, onClearQuery } from './events'
import type { FeatureCollection } from './api'

type Feature = FeatureCollection['features'][number]

// Turn any property value into something printable in a table cell.
function formatValue(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

export default function AttributeTable() {
  const [layer, setLayer] = useState('')
  const [features, setFeatures] = useState<Feature[]>([])
  const [collapsed, setCollapsed] = useState(false)

  useEffect(() => {
    const offResult = onQueryResult((e) => {
      setLayer(e.layer)
      setFeatures(e.geojson.features ?? [])
      setCollapsed(false)
    })
    const offClear = onClearQuery(() => {
      setFeatures([])
      setLayer('')
    })
    return () => {
      offResult()
      offClear()
    }
  }, [])

  // Column headers = the union of every feature's property keys, first-seen order.
  const columns = useMemo(() => {
    const seen = new Set<string>()
    for (const f of features) {
      for (const key of Object.keys(f.properties ?? {})) seen.add(key)
    }
    return [...seen]
  }, [features])

  if (features.length === 0) return null

  return (
    <Paper
      elevation={6}
      sx={{
        position: 'absolute',
        left: 8,
        right: 8,
        bottom: 8,
        maxHeight: collapsed ? 'auto' : '42%',
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
          borderBottom: collapsed ? 'none' : 1,
          borderColor: 'divider',
          bgcolor: 'grey.100',
        }}
      >
        <Typography variant="subtitle2" sx={{ flexGrow: 1 }}>
          Results — {layer} ({features.length})
        </Typography>
        <Tooltip title={collapsed ? 'Expand' : 'Collapse'}>
          <IconButton size="small" onClick={() => setCollapsed((c) => !c)}>
            {collapsed ? <UnfoldMoreIcon fontSize="small" /> : <UnfoldLessIcon fontSize="small" />}
          </IconButton>
        </Tooltip>
        <Tooltip title="Close">
          <IconButton size="small" onClick={() => setFeatures([])}>
            <CloseIcon fontSize="small" />
          </IconButton>
        </Tooltip>
      </Box>

      {/* Scrollable table */}
      {!collapsed && (
        <TableContainer sx={{ overflow: 'auto' }}>
          <Table size="small" stickyHeader>
            <TableHead>
              <TableRow>
                {columns.map((col) => (
                  <TableCell key={col} sx={{ fontWeight: 600, whiteSpace: 'nowrap' }}>
                    {col}
                  </TableCell>
                ))}
              </TableRow>
            </TableHead>
            <TableBody>
              {features.map((f, i) => (
                <TableRow key={i} hover>
                  {columns.map((col) => (
                    <TableCell key={col} sx={{ whiteSpace: 'nowrap' }}>
                      {formatValue(f.properties?.[col])}
                    </TableCell>
                  ))}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Paper>
  )
}

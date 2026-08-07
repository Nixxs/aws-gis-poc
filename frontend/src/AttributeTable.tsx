import { useEffect, useMemo, useState } from 'react'
import {
  Box, Paper, Typography, IconButton, Table, TableBody, TableCell,
  TableContainer, TableHead, TableRow, Tooltip, Tabs, Tab,
} from '@mui/material'
import CloseIcon from '@mui/icons-material/Close'
import UnfoldLessIcon from '@mui/icons-material/UnfoldLess'
import UnfoldMoreIcon from '@mui/icons-material/UnfoldMore'
import {
  onQueryResult, onQueryResultMulti, onClearQuery, emitResultFeatureSelect,
} from './events'
import type { FeatureCollection } from './api'

type Feature = FeatureCollection['features'][number]

// One layer's worth of results — becomes a tab when there is more than one.
type ResultSet = { layer: string; label: string; features: Feature[] }

// Turn any property value into something printable in a table cell.
function formatValue(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

export default function AttributeTable() {
  const [results, setResults] = useState<ResultSet[]>([])
  const [active, setActive] = useState(0)
  const [collapsed, setCollapsed] = useState(false)
  const [selected, setSelected] = useState<number | null>(null)

  useEffect(() => {
    const offResult = onQueryResult((e) => {
      setResults([{ layer: e.layer, label: e.layer, features: e.geojson.features ?? [] }])
      setActive(0)
      setCollapsed(false)
      setSelected(null)
    })
    // Buffer intersect: one result set per queried layer. Drop empty layers so
    // the tabs only show layers that actually returned features.
    const offMulti = onQueryResultMulti((e) => {
      const sets = e.results
        .map((r) => ({
          layer: r.layer,
          label: r.label ?? r.layer,
          features: r.geojson.features ?? [],
        }))
        .filter((r) => r.features.length > 0)
      setResults(sets)
      setActive(0)
      setCollapsed(false)
      setSelected(null)
    })
    const offClear = onClearQuery(() => {
      setResults([])
      setActive(0)
      setSelected(null)
    })
    return () => {
      offResult()
      offMulti()
      offClear()
    }
  }, [])

  // Guard against a stale active index if the result set shrank.
  const activeIndex = active < results.length ? active : 0
  const current = results[activeIndex]
  const features = current?.features ?? []

  // Click a row -> highlight that feature on the map and pan to it.
  const selectRow = (index: number, feature: Feature) => {
    setSelected(index)
    emitResultFeatureSelect({ feature })
  }

  const switchTab = (index: number) => {
    setActive(index)
    setSelected(null)
  }

  // Column headers = the union of every feature's property keys, first-seen order.
  const columns = useMemo(() => {
    const seen = new Set<string>()
    for (const f of features) {
      for (const key of Object.keys(f.properties ?? {})) seen.add(key)
    }
    return [...seen]
  }, [features])

  if (results.length === 0) return null

  const multi = results.length > 1

  return (
    <Paper
      elevation={6}
      sx={{
        position: 'absolute',
        left: 8,
        right: 8,
        bottom: 40,     // raised off the bottom to clear the scale bar + attribution text
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
          Results — {current?.label} ({features.length})
        </Typography>
        <Tooltip title={collapsed ? 'Expand' : 'Collapse'}>
          <IconButton size="small" onClick={() => setCollapsed((c) => !c)}>
            {collapsed ? <UnfoldMoreIcon fontSize="small" /> : <UnfoldLessIcon fontSize="small" />}
          </IconButton>
        </Tooltip>
        <Tooltip title="Close">
          <IconButton size="small" onClick={() => setResults([])}>
            <CloseIcon fontSize="small" />
          </IconButton>
        </Tooltip>
      </Box>

      {/* One tab per layer when a multi-layer query returned several result sets. */}
      {multi && !collapsed && (
        <Tabs
          value={activeIndex}
          onChange={(_, v) => switchTab(v)}
          variant="scrollable"
          scrollButtons="auto"
          sx={{ minHeight: 36, borderBottom: 1, borderColor: 'divider' }}
        >
          {results.map((r) => (
            <Tab
              key={r.layer}
              label={`${r.label} (${r.features.length})`}
              sx={{ minHeight: 36, textTransform: 'none' }}
            />
          ))}
        </Tabs>
      )}

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
                <TableRow
                  key={i}
                  hover
                  selected={selected === i}
                  onClick={() => selectRow(i, f)}
                  sx={{ cursor: 'pointer' }}
                >
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

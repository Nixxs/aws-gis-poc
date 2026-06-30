import { useEffect, useMemo, useState } from 'react'
import {
  Box, Typography, TextField, MenuItem, Autocomplete,
  Button, Stack, CircularProgress, Alert,
} from '@mui/material'
import { useConfig } from './config'
import {
  describeLayer, getUniqueValues, queryLayer, type ColumnInfo,
} from './api'
import { emitQueryResult, emitClearQuery } from './events'

const OPERATORS = ['=', '!=', '>', '<', '>=', '<=', 'LIKE'] as const
type Operator = (typeof OPERATORS)[number]

// DuckDB types that should NOT be quoted in the WHERE clause.
function isNumeric(type: string): boolean {
  return /INT|DOUBLE|DECIMAL|FLOAT|REAL|NUMERIC|HUGEINT/i.test(type)
}

// Build a safe-ish WHERE clause. The Lambda still validates/escapes server-side;
// this just produces valid SQL for the common cases.
function buildWhere(col: ColumnInfo, op: Operator, value: string): string {
  if (op === 'LIKE') {
    const escaped = value.replace(/'/g, "''")
    return `"${col.name}" LIKE '${escaped}'`
  }
  if (isNumeric(col.type) && value.trim() !== '' && !Number.isNaN(Number(value))) {
    return `"${col.name}" ${op} ${value}`
  }
  const escaped = value.replace(/'/g, "''")
  return `"${col.name}" ${op} '${escaped}'`
}

export default function QueryPanel() {
  const { config } = useConfig()

  const [layer, setLayer] = useState('')
  const [columns, setColumns] = useState<ColumnInfo[]>([])
  const [field, setField] = useState('')
  const [op, setOp] = useState<Operator>('=')
  const [value, setValue] = useState('')

  const [suggestions, setSuggestions] = useState<string[]>([])
  const [loadingSuggestions, setLoadingSuggestions] = useState(false)
  const [describing, setDescribing] = useState(false)
  const [running, setRunning] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [resultCount, setResultCount] = useState<number | null>(null)

  const selectedColumn = useMemo(
    () => columns.find((c) => c.name === field),
    [columns, field],
  )

  // When the layer changes, fetch its column schema.
  useEffect(() => {
    if (!layer) return
    setDescribing(true)
    setError(null)
    setColumns([])
    setField('')
    setValue('')
    setSuggestions([])
    describeLayer(layer)
      .then((res) => setColumns(res.columns.filter((c) => !c.is_geometry)))
      .catch((e) => setError(String(e.message ?? e)))
      .finally(() => setDescribing(false))
  }, [layer])

  // Debounced autocomplete: fetch unique values as the user types in the value box.
  useEffect(() => {
    if (!layer || !field) return
    const handle = setTimeout(() => {
      setLoadingSuggestions(true)
      getUniqueValues(layer, field, value, 50)
        .then((res) => setSuggestions(res.values.map((v) => String(v))))
        .catch(() => setSuggestions([]))
        .finally(() => setLoadingSuggestions(false))
    }, 250)
    return () => clearTimeout(handle)
  }, [layer, field, value])

  const canSubmit = layer && field && value.trim() !== '' && !running

  const submit = async () => {
    if (!selectedColumn) return
    setRunning(true)
    setError(null)
    setResultCount(null)
    try {
      const where = buildWhere(selectedColumn, op, value)
      const geojson = await queryLayer(layer, where)
      setResultCount(geojson.features.length)
      emitQueryResult({ layer, geojson })
    } catch (e: any) {
      setError(String(e.message ?? e))
    } finally {
      setRunning(false)
    }
  }

  const clear = () => {
    setValue('')
    setResultCount(null)
    setError(null)
    emitClearQuery()
  }

  return (
    <Box>
      <Typography variant="overline" sx={{ color: 'text.secondary' }}>
        Query
      </Typography>

      <Stack spacing={1.5} sx={{ mt: 1 }}>
        {/* 1. Layer */}
        <TextField
          select size="small" label="Layer"
          value={layer} onChange={(e) => setLayer(e.target.value)}
        >
          {config?.layers?.length
            ? config.layers.map((l) => (
                <MenuItem key={l.id} value={l.id}>{l.label}</MenuItem>
              ))
            : <MenuItem disabled value="">Loading layers…</MenuItem>}
        </TextField>

        {/* 2. Column */}
        <TextField
          select size="small" label="Column"
          value={field}
          onChange={(e) => {
            setField(e.target.value)
            setValue('')
            setSuggestions([])
          }}
          disabled={!layer || describing}
          helperText={describing ? 'Loading columns…' : ' '}
        >
          {columns.length
            ? columns.map((c) => (
                <MenuItem key={c.name} value={c.name}>{c.name}</MenuItem>
              ))
            : <MenuItem disabled value="">Pick a layer first</MenuItem>}
        </TextField>

        {/* 3. Operator */}
        <TextField
          select size="small" label="Operator"
          value={op} onChange={(e) => setOp(e.target.value as Operator)}
          disabled={!field}
        >
          {OPERATORS.map((o) => (
            <MenuItem key={o} value={o}>{o}</MenuItem>
          ))}
        </TextField>

        {/* 4. Value (autocomplete from unique values) */}
        <Autocomplete
          freeSolo size="small" options={suggestions}
          inputValue={value} onInputChange={(_, v) => setValue(v)}
          disabled={!field}
          loading={loadingSuggestions}
          renderInput={(params) => (
            <TextField
              {...params}
              label="Value"
              slotProps={{
                ...params.slotProps,
                input: {
                  ...params.slotProps.input,
                  endAdornment: (
                    <>
                      {loadingSuggestions ? <CircularProgress size={16} color="inherit" /> : null}
                      {params.slotProps.input.endAdornment}
                    </>
                  ),
                },
              }}
            />
          )}
        />

        <Stack direction="row" spacing={1}>
          <Button
            variant="contained" size="small" onClick={submit} disabled={!canSubmit}
            startIcon={running ? <CircularProgress size={16} color="inherit" /> : undefined}
          >
            Run query
          </Button>
          <Button variant="outlined" size="small" onClick={clear}>Clear</Button>
        </Stack>

        {error && <Alert severity="error">{error}</Alert>}
        {resultCount !== null && !error && (
          <Alert severity={resultCount ? 'success' : 'info'}>
            {resultCount} feature{resultCount === 1 ? '' : 's'} found
          </Alert>
        )}
      </Stack>
    </Box>
  )
}

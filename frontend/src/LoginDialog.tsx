import { useState } from 'react'
import {
  Dialog, DialogTitle, DialogContent, DialogActions,
  TextField, Button, Alert, Stack,
} from '@mui/material'
import { useAuth } from './auth'

interface LoginDialogProps {
  open: boolean
  onClose: () => void
}

export default function LoginDialog({ open, onClose }: LoginDialogProps) {
  const { login } = useAuth()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState(false)

  const reset = () => {
    setUsername('')
    setPassword('')
    setError(false)
  }

  const handleClose = () => {
    reset()
    onClose()
  }

  const submit = () => {
    if (login(username, password)) {
      reset()
      onClose()
    } else {
      setError(true)
    }
  }

  return (
    <Dialog open={open} onClose={handleClose} maxWidth="xs" fullWidth>
      <DialogTitle>Sign in</DialogTitle>
      <DialogContent>
        <Stack spacing={2} sx={{ mt: 1 }}>
          <Alert severity="info">
            Demo login — use <b>demo</b> / <b>demo</b>. This is a mock for the
            prototype and is not real authentication.
          </Alert>
          {error && <Alert severity="error">Invalid username or password.</Alert>}
          <TextField
            label="Username" size="small" autoFocus
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') submit() }}
          />
          <TextField
            label="Password" type="password" size="small"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') submit() }}
          />
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={handleClose}>Cancel</Button>
        <Button variant="contained" onClick={submit}>Sign in</Button>
      </DialogActions>
    </Dialog>
  )
}

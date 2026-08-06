import { useState } from 'react'
import {
  Button, IconButton, Menu, MenuItem, Typography, Box,
} from '@mui/material'
import AccountCircleIcon from '@mui/icons-material/AccountCircle'
import { useAuth } from './auth'
import LoginDialog from './LoginDialog'

// The AppBar auth control: a "Login" button when anonymous, or an account
// menu (showing the username + Logout) when signed in.
export default function LoginControl() {
  const { user, logout } = useAuth()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [anchor, setAnchor] = useState<null | HTMLElement>(null)

  if (!user) {
    return (
      <>
        <Button
          color="inherit"
          startIcon={<AccountCircleIcon />}
          onClick={() => setDialogOpen(true)}
        >
          Login
        </Button>
        <LoginDialog open={dialogOpen} onClose={() => setDialogOpen(false)} />
      </>
    )
  }

  return (
    <Box sx={{ display: 'flex', alignItems: 'center' }}>
      <IconButton
        color="inherit"
        onClick={(e) => setAnchor(e.currentTarget)}
        aria-label="account menu"
      >
        <AccountCircleIcon />
      </IconButton>
      <Menu anchorEl={anchor} open={Boolean(anchor)} onClose={() => setAnchor(null)}>
        <MenuItem disabled>
          <Typography variant="body2">
            Signed in as <b>{user}</b>
          </Typography>
        </MenuItem>
        <MenuItem onClick={() => { setAnchor(null); logout() }}>Logout</MenuItem>
      </Menu>
    </Box>
  )
}

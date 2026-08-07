import { Box, AppBar, Toolbar, Typography, Drawer, Divider, IconButton } from '@mui/material'
import MapIcon from '@mui/icons-material/Map'
import MenuIcon from '@mui/icons-material/Menu'
import ChevronLeftIcon from '@mui/icons-material/ChevronLeft'
import MapContainer from './MapContainer'
import LayerList from './LayerList'
import QueryPanel from './QueryPanel'
import SpatialQueryPanel from './SpatialQueryPanel'
import AttributeTable from './AttributeTable'
import FeatureInfoPanel from './FeatureInfoPanel'
import LoginControl from './LoginControl'
import { useConfig } from './config'
import { useAuth } from './auth'
import { warmUp } from './api'
import { useState, useEffect } from 'react'

const DRAWER_WIDTH = 340

export default function App() {
    const { config } = useConfig()
    const { user } = useAuth()
    const [hasAuth, setHasAuth] = useState(false)
    const [sidebarOpen, setSidebarOpen] = useState(true)

    useEffect(() => {
        setHasAuth(!!user)
    }, [user])

    // Warm the Lambda container as soon as the app loads so the user's first
    // query isn't slowed by a container cold start. Best-effort, runs once.
    useEffect(() => {
        warmUp()
    }, [])

    return (
        <Box sx={
                { 
                    display: 'flex', 
                    flexDirection: 'row',
                    height: '100vh', 
                    overflow: 'hidden' 
                }
            }
        >
            {/* Top bar — sits above everything (zIndex bumped over the drawer) */}
            <AppBar position="fixed" sx={{ zIndex: (t) => t.zIndex.drawer + 1 }}>
                <Toolbar variant="dense">
                <IconButton
                    color="inherit"
                    edge="start"
                    onClick={() => setSidebarOpen((o) => !o)}
                    aria-label={sidebarOpen ? 'Hide panel' : 'Show panel'}
                    sx={{ mr: 1 }}
                >
                    <MenuIcon />
                </IconButton>
                <MapIcon sx={{ mr: 1 }} />
                <Typography variant="h6" noWrap sx={{ flexGrow: 1 }}>
                    AWS GIS POC - {hasAuth ? 'Private' : 'Public'}
                </Typography>
                <LoginControl />
                </Toolbar>
            </AppBar>

            {/* Left sidebar — permanent, collapsible */}
            <Drawer
                variant="permanent"
                sx={{
                width: sidebarOpen ? DRAWER_WIDTH : 0,
                flexShrink: 0,
                whiteSpace: 'nowrap',
                transition: (t) => t.transitions.create('width', { duration: t.transitions.duration.shorter }),
                '& .MuiDrawer-paper': {
                    width: sidebarOpen ? DRAWER_WIDTH : 0,
                    boxSizing: 'border-box',
                    overflowX: 'hidden',
                    borderRight: sidebarOpen ? undefined : 'none',
                    transition: (t) => t.transitions.create('width', { duration: t.transitions.duration.shorter }),
                },
                }}
            >
                <Toolbar variant="dense" />{/* spacer so content starts below the AppBar */}
                <Box
                    sx={{
                        p: 2,
                        height: '100%',
                        overflowY: 'auto',
                        overflowX: 'hidden',
                        // Keep it scrollable but hide the visible scrollbar.
                        scrollbarWidth: 'none',
                        '&::-webkit-scrollbar': { display: 'none' },
                    }}
                >
                    <Box sx={{ display: 'flex', justifyContent: 'flex-end', mb: 1 }}>
                        <IconButton size="small" onClick={() => setSidebarOpen(false)} aria-label="Collapse panel">
                            <ChevronLeftIcon />
                        </IconButton>
                    </Box>
                    <LayerList />
                    <Divider sx={{ my: 2 }} />
                    <QueryPanel />
                    <Divider sx={{ my: 2 }} />
                    <SpatialQueryPanel />
                </Box>
            </Drawer>

            {/* Main content area — where the map will live */}
            <Box component="main" sx={{ flexGrow: 1, position: 'relative' }}>
                <Toolbar variant="dense" />{/* spacer under the AppBar */}
                <Box sx={{ position: 'absolute', inset: 0, top: 48 }}>
                    {config && <MapContainer config={config} />}
                    <FeatureInfoPanel />
                    <AttributeTable />
                </Box>
            </Box>
        </Box>
    )
}
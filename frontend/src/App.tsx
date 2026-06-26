import { Box, AppBar, Toolbar, Typography, Drawer } from '@mui/material'
import MapIcon from '@mui/icons-material/Map'
import MapContainer from './MapContainer'
import LayerList from './LayerList'
import { useConfig } from './config'

const DRAWER_WIDTH = 340

export default function App() {
    const { config } = useConfig()

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
                <MapIcon sx={{ mr: 1 }} />
                <Typography variant="h6" noWrap>
                    AWS GIS POC
                </Typography>
                </Toolbar>
            </AppBar>

            {/* Left sidebar — permanent, fixed width */}
            <Drawer
                variant="permanent"
                sx={{
                width: DRAWER_WIDTH,
                flexShrink: 0,
                '& .MuiDrawer-paper': { width: DRAWER_WIDTH, boxSizing: 'border-box' },
                }}
            >
                <Toolbar variant="dense" />{/* spacer so content starts below the AppBar */}
                <Box sx={{ overflow: 'auto', p: 2 }}>
                    <LayerList />
                </Box>
            </Drawer>

            {/* Main content area — where the map will live */}
            <Box component="main" sx={{ flexGrow: 1, position: 'relative' }}>
                <Toolbar variant="dense" />{/* spacer under the AppBar */}
                <Box sx={{ position: 'absolute', inset: 0, top: 48 }}>
                    {config && <MapContainer config={config} />}
                </Box>
            </Box>
        </Box>
    )
}
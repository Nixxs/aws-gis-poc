import { createContext, useContext, useState, type ReactNode } from 'react'

// ---------------------------------------------------------------------------
// MOCK AUTHENTICATION — for the prototype UI only.
//
// This is NOT real security. It gates the *visibility* of layers in the UI so
// the client can see the intended UX (anonymous vs signed-in). The underlying
// tiles are still publicly reachable, so real enforcement must be added later
// in the client's own backend (e.g. per-role signed tile URLs / a gated tile
// endpoint / auth on the query API). Keep this module's surface small so it can
// be swapped for the real identity provider with minimal churn elsewhere.
// ---------------------------------------------------------------------------

const MOCK_USER = 'demo'
const MOCK_PASS = 'demo'

interface AuthState {
  user: string | null
  login: (username: string, password: string) => boolean
  logout: () => void
}

const AuthContext = createContext<AuthState | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  // Ephemeral: state lives in memory only, so a refresh logs you back out.
  const [user, setUser] = useState<string | null>(null)

  const login = (username: string, password: string): boolean => {
    if (username === MOCK_USER && password === MOCK_PASS) {
      setUser(username)
      return true
    }
    return false
  }

  const logout = () => setUser(null)

  return (
    <AuthContext.Provider value={{ user, login, logout }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within an AuthProvider')
  return ctx
}

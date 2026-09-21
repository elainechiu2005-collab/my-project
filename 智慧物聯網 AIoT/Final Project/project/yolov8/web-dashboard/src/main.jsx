import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'
import RawStream from './RawStream.jsx'

function Root() {
  const pathname = window.location.pathname.replace(/\/+$/, '') || '/'
  if (pathname === '/raw' || pathname.startsWith('/raw/')) {
    return <RawStream />
  }

  return <App />
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <Root />
  </StrictMode>,
)

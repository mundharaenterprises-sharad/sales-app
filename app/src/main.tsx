import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { startUpdateWatch } from './lib/updates'
import './styles.css'

startUpdateWatch()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)

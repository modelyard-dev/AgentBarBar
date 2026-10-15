import React from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { initializeHost } from './host'
import './style.css'

initializeHost()
createRoot(document.getElementById('root')!).render(<React.StrictMode><App /></React.StrictMode>)

import React from 'react'
import { createRoot } from 'react-dom/client'
import { initializeHost } from './host'
import PopupView from './PopupView'
import './style.css'
initializeHost()
createRoot(document.getElementById('root')!).render(<React.StrictMode><PopupView /></React.StrictMode>)

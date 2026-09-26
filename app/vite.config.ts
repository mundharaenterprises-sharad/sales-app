import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      // 'prompt', not 'autoUpdate', and registered by hand in src/lib/updates.ts.
      // autoUpdate installs a new build quietly and lets the open page carry on
      // running the old one, so a phone stays a version behind until it is next
      // opened twice — see the note at the top of updates.ts. Driving the
      // registration ourselves means we decide when the swap happens, and can
      // put the build date on screen so nobody has to guess.
      registerType: 'prompt',
      injectRegister: null,
      includeAssets: ['icon-192.png', 'icon-512.png', 'apple-touch-icon.png'],
      manifest: {
        name: 'Sales App',
        short_name: 'Sales',
        description: 'Orders, billing and collections',
        theme_color: '#1f3864',
        background_color: '#ffffff',
        display: 'standalone',
        orientation: 'portrait',
        start_url: '/',
        icons: [
          { src: 'icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,png,svg,woff2}'],
        // Never cache API calls. Stock and money must be live or explicitly
        // read from our own IndexedDB snapshot, never silently stale from a
        // service worker.
        navigateFallbackDenylist: [/^\/api/],
        runtimeCaching: [],
      },
    }),
  ],
  // Stamped into the bundle so the Home screen can say which build is running.
  define: { __BUILD_TIME__: JSON.stringify(new Date().toISOString()) },
  build: { sourcemap: true },
})

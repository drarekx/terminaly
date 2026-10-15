# Terminaly brand

Concept: **"Todos tus agentes. Un solo terminal."** A prompt `❯` and three session rows whose dots
use the app's status colors: blue (working), amber with a soft glow (needs you), green (ready).

| File | Use |
|---|---|
| `icon.svg` | Master app icon (1024 canvas, 824 squircle, macOS shadow). Source of truth. |
| `icon-small.svg` | Simplified icon for 16–32 px (no shadow/glow, bigger dots). |
| `icon-1024.png` | Rendered master, for stores and docs. |
| `logo-dark.png`, `logo-light.png` | Lockup (icon + wordmark + tagline) for dark and light backgrounds. |
| `banner.png` | 1280×640 (@2x) repository social preview. |
| `src/*.html` | Sources of the logo and banner PNGs. |

Colors: Grafito `#0B0C0E`, Panel `#0F1013`, Niebla `#ECECF1`, Trabajando `#4C8DFF`, Te necesita `#FFB020`,
Listo `#3DD68C`. Type: JetBrains Mono 700 for the wordmark, SF Pro for the app UI.

Regenerate:

```sh
scripts/make-icon.sh        # Resources/AppIcon.icns + icon-1024.png from icon.svg / icon-small.svg
swiftc -O scripts/tools/render-html.swift -o /tmp/render-html
/tmp/render-html brand/src/banner.html 1280 640 brand/banner.png
/tmp/render-html brand/src/logo-dark.html 1100 312 brand/logo-dark.png
/tmp/render-html brand/src/logo-light.html 1100 312 brand/logo-light.png
```

Design canvas: https://claude.ai/artifact/BtRUQ9yMD1XKC6oL22NuNd

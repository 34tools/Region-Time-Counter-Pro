# Region Time Counter Pro

**Advanced region duration calculator for REAPER**

Region Time Counter Pro is a lightweight, cross-platform REAPER script that
calculates total and selected region duration using *union logic* — without
double-counting overlapping regions.

Part of **34tools.edit** — Audio Tools by Alexey Vorobyov (34birds).

---

## Latest Release

[Download latest release](https://github.com/34tools/Region-Time-Counter-Pro/releases/latest)

## Features

- Total region duration (union of all regions)
- Selected region duration (union of checked regions)
- Markers displayed (not included in totals)
- Searchable region list
- Per-region duration display
- Shift-click range selection
- Mouse wheel + draggable scrollbar
- Keyboard scrolling (↑ / ↓)
- Persistent checkbox state (stored in project)
- No js_ReaScriptAPI required
- macOS & Windows compatible

---

## Installation

1. Download `Region-Time-Counter-Pro.lua`
2. Place it in your REAPER Scripts folder
3. Open **Actions → Show action list**
4. Click **ReaScript → Load**
5. Run the script

---

## Usage

- Check regions to include them in **Selected**
- Markers are visible but do not affect total calculations
- Use **Shift-click** to select ranges
- Use **Search** to filter regions
- Use **All / Clear** for quick selection
- Scroll with mouse wheel or ↑ / ↓ keys

---

## License

MIT  
© 2026 — 34dev — Audio Tools by Alexey Vorobyov (34birds)

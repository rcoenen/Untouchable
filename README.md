# Untouchable

Kills the macOS Touch Bar and replaces it with weather + clock.

Because the Touch Bar is useless and I want it to be useful.

## Build

```
./build.sh
open Untouchable.app
```

Requires: macOS with a Touch Bar, Command Line Tools (`xcode-select --install`).

## How it works

- `DFRSetStatus(2)` — suppresses the default system strip.
- `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` (private) — pushes our `NSTouchBar` to the hardware.
- `NSTouchBarItem.addSystemTrayItem:` (private) — claims the left tray slot so the close-box X has nothing to render.
- `DFRSystemModalShowsCloseBoxWhenFrontMost(false)` — hides the X.
- Re-presents every 0.3s to survive focus changes.
- Weather via [Open-Meteo](https://open-meteo.com) (no API key). Location hardcoded; edit `WeatherClient.latitude/longitude` in `Sources/main.swift`.

## Status

Works on macOS 26 (Tahoe). Uses private frameworks — could break on future macOS updates.

Not signed beyond ad-hoc. First launch: right-click → Open, or `xattr -d com.apple.quarantine Untouchable.app`.

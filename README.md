# SwiftTab
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078d4?logo=windows)
![Language](https://img.shields.io/badge/language-AutoHotkey%20v2-334455?logo=autohotkey)
[![Release](https://img.shields.io/github/v/release/geethut-stack/SwiftTab)](https://github.com/geethut-stack/SwiftTab/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/geethut-stack/SwiftTab/total)](https://github.com/geethut-stack/SwiftTab/releases)
[![License: MIT](https://img.shields.io/github/license/geethut-stack/SwiftTab)](LICENSE)



**A light, fast Alt+Tab replacement for Windows 10/11, written in a single AutoHotkey v2 file.**

Instant overlay, live window previews, search, same-app switching, and a quick tap that switches with no UI at all. No installer, no background service, no idle CPU.

<!-- Replace with a real GIF: 800px wide, ~10s, shows Alt+Tab, search, close-window -->

<img width="972" height="342" alt="image" src="https://github.com/user-attachments/assets/9be00876-46ae-49d2-9669-cb1a18625969" />


---

## Why

The built-in Alt+Tab has a long list of everyday annoyances: blank thumbnails, laggy or black-screen switching on some builds, a switcher that shows every monitor's windows on one screen, Edge tabs mixed in with windows, ghost entries, and no way to search. SwiftTab is a small script that fixes those without replacing your shell or running anything heavy.

## Features

- **Quick-tap switching.** Tap Alt+Tab and release: you switch instantly and the overlay never appears, so there is no flicker.
- **Overlay built once at startup.** Showing it is just "fill the list and display".
- **Live previews.** Uses DWM thumbnails of the selected window, not a cached screenshot, so previews aren't stale or blank.
- **Search.** Press `/` (or `Ctrl+Alt+Space`) and type part of a window title or app name.
- **Same-app cycling.** `Alt+`` ` cycles only the current app's windows.
- **Per-monitor.** Opens on the active monitor; press `m` to show only that monitor's windows.
- **Close from the list.** Press `Delete` to close the selected window without leaving the switcher.
- **Number jump.** Press `1`-`9` to jump to a window.
- **Real windows only.** Filters out other virtual desktops, suspended UWP ghosts, tool windows and owned popups, following the same rules as the native switcher. Edge tabs never appear as separate entries.
- **UWP aware.** Resolves the real app behind `ApplicationFrameHost`.
- **Game friendly.** Exclusive-fullscreen games get the native Alt+Tab. Add borderless-fullscreen games to `BypassExe`.
- **Zero idle cost.** No hooks polling, no timers, no background threads while you aren't switching.

## Install

**Option A: run the script** (recommended)
1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Download `SwiftTab.ahk` and double-click it.
3. Press Alt+Tab.

To start with Windows, put a shortcut to the script in `shell:startup`.

**Option B: compiled exe**
Download `SwiftTab.exe` from [Releases](../../releases). Compiled AutoHotkey programs are sometimes flagged by antivirus or SmartScreen. If that worries you, use Option A, which is the same code in plain text.

## Keys

| Key | Action |
|---|---|
| `Alt+Tab` / `Alt+Shift+Tab` | Open, next / previous |
| `Alt+`` ` | Same-app windows only |
| `Ctrl+Alt+Space` | Open in search mode |
| `Tab`, `Down`, `Up`, `Right`, `Left`, `Home`, `End` | Move (wraps) |
| Release `Alt` or `Enter` | Switch |
| `Esc` | Cancel |
| `Delete` | Close selected window |
| `1`-`9` | Jump to nth window |
| `/` | Search (type, then `Enter`) |
| `m` | Toggle this-monitor-only |
| Click a row | Switch to it |

## Configure

All settings are in the `Cfg` block at the top of `SwiftTab.ahk`:

```ahk
ShowDelay: 90,               ; ms before overlay appears (0 = immediately)
Preview: true,               ; live thumbnail of selected window
ShowOn: "active",            ; "active" | "mouse" | "primary" monitor
OnlyCurrentMonitor: false,
BypassExe: [],               ; e.g. ["game.exe"]
HideExe: [],
AdminMode: false,            ; true = work over elevated windows (UAC prompt on launch)
```
Exclusive fullscreen detection is active by default (BypassD3DFullscreen: true). While a true exclusive-fullscreen game is running, SwiftTab steps aside and Windows’ native Alt+Tab handles the keys.
BypassExe ships as [], so nothing is listed. The check only runs once you add at least one name.

If a game uses borderless fullscreen (common for modern games), the exclusive-fullscreen check won’t catch it. Add its process name in the Cfg block:

```BypassExe: ["game.exe", "anothergame.exe"],```

Then save and reload the script (tray icon, then Reload Script, or just launch it again).

Finding the exe name: open Task Manager, go to the Details tab, and copy the name exactly as shown. Matching ignores upper/lower case.
When it applies: it’s checked at the moment you press Alt+Tab, using whichever window is in the foreground. So it bypasses while that program has focus, and SwiftTab works normally in every other window.
If you put a browser or other everyday app in the list, SwiftTab will stop working whenever that app is focused.

## Known limitations

- **Elevated (administrator) windows.** Windows blocks normal scripts from intercepting keys inside elevated windows, so you get the native Alt+Tab there. Set `AdminMode: true` to cover them (you will see a UAC prompt at launch), or run the script from Task Scheduler with highest privileges to avoid the prompt.
- **Order is z-order.** Z-order closely tracks recency but isn't an exact most-recently-used list.
- **Mixed-DPI setups.** Sizing uses the primary monitor's DPI.
- **Previews of elevated windows** may be empty.
- **Dark theme only** for now. Rounded corners are Windows 11 only.

## How it compares

| | Native Windows | SwiftTab | Heavier AHK switchers |
|---|---|---|---|
| Search / filter | No | Yes | Varies |
| Quick-tap, no flicker | Overlay logic is built in | Yes | Varies |
| Live previews | Yes (sometimes blank) | Yes | Often icons only |
| Idle resource use | n/a | None | Often timers/processes |
| Size | n/a | One ~400-line file | Often many files |
| Visual effects / themes | Basic | Basic | Often extensive |

SwiftTab is deliberately small. If you want shaders, workspace integration or hundreds of options, look at projects such as [Alt-Tabby](https://github.com/cwilliams5/Alt-Tabby).

## FAQ

**Does it replace the Windows Alt+Tab completely?**
While the script runs it intercepts Alt+Tab. Exit it from the tray icon and the native one returns immediately.

**Why does my game still use the normal Alt+Tab?**
That's the bypass for exclusive fullscreen. Use `BypassExe` for borderless-fullscreen games.

**Does it use a lot of memory?**
It's a single AutoHotkey process. Measure it on your machine and report numbers in an issue if you like.

## Roadmap

- [ ] Light theme and custom colors in a config file
- [ ] Per-window DPI handling
- [ ] Optional true MRU tracking
- [ ] Winget / Scoop packages

## Contributing

Bug reports with your Windows build, monitor setup and the window involved are the most useful thing you can send. Pull requests that keep the script small are welcome.

## License

MIT. See [LICENSE](LICENSE).


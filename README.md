# open_dock

**Mono Dock** — an intelligent dock layer for macOS. It replaces the Apple Dock with one small bar per
display that holds your open apps, shows when something needs you, and lets you steer apps and agents
without opening their windows.

## What it does

- **A dock per display** with the apps that have windows there (and on the current desktop). Dots show
  windows; hollow dots are minimized ones.
- **Activity at a glance** — unread badges, audio playing, apps working hard, and new-message alerts.
- **Steer windows** — halves, maximize, move to the next display, and an even **Tile** grid.
- **Steer apps from a widget** — click a supported app's icon to open its widget instead of the app:
  - **Claude** — see sessions with live status, read the latest messages, and reply in the background.
  - **Codex / ChatGPT** — threads by project; replies go through the bundled `codex queue` command.
  - **Messages** — recent conversations, previews, unread counts, and sending.
  - **Chrome** — search Google with clean native results, hover a result for a summary (recipes show
    ingredients and time), open pages in a reader view, or get an on-device answer from the top results.
  - **Spotify** — now playing, controls, volume, search.
- **Mono**, an on-device assistant (Apple's Foundation Models, free and private): "What needs me?",
  conversation summaries, suggested replies, and `@`-mentions to point it at an app or conversation.
  It only ever writes drafts you approve.

## Build and run

Requires macOS 26 on Apple silicon (for the on-device model) and the Xcode 26 toolchain.

```bash
./build.sh
open "Mono Dock.app"
```

`build.sh` builds a release binary, wraps it in `Mono Dock.app`, and signs it with your Apple Development
identity if you have one (otherwise ad-hoc).

## Permissions

macOS will ask for these; each unlocks part of the dock:

| Permission | Used for |
| --- | --- |
| Accessibility | Reading and moving windows, reading Claude's sidebar |
| Automation (Messages, Chrome, Spotify) | Sending messages, reading tabs, playback controls |
| Full Disk Access (optional) | Message previews, unread counts and new-message alerts |

While it runs, Mono Dock auto-hides the Apple Dock and restores it exactly as it was on quit
(toggle in the menu bar menu).

## Layout

- `Sources/Fractal/` — the app (the Swift target keeps its original name).
- `Archive/` — earlier experiments: an infinite desktop canvas and hierarchical tiling.

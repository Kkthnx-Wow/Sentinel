<div align="center">

# Sentinel

**A modern, Secret-Value-safe Lua error watcher for World of Warcraft — it catches, dedupes, persists, and lets you share UI bugs.**

[![Last Commit](https://img.shields.io/github/last-commit/Kkthnx-Wow/Sentinel)](https://github.com/Kkthnx-Wow/Sentinel/commits/main)
[![Issues](https://img.shields.io/github/issues/Kkthnx-Wow/Sentinel)](https://github.com/Kkthnx-Wow/Sentinel/issues)
[![CurseForge](https://img.shields.io/badge/CurseForge-Download-orange)](https://www.curseforge.com/wow/addons/sentinel)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/Kkthnx-Wow/Sentinel/blob/main/LICENSE)

</div>

---

## Overview

**Sentinel** is a from-the-ground-up Lua error display built for the modern WoW client. It quietly takes ownership of the game's error handler, captures the full call stack and locals at the fault site, and presents everything in a clean, dark, readable window — then lets you copy, export, or **send a bug straight to a friend** for help.

It's designed for the **Midnight** era from day one: every value that touches the UI is checked against the new Secret Value system, so Sentinel degrades gracefully instead of throwing errors of its own.

- **Catches everything that matters** — Lua errors with stack + locals, plus blocked/forbidden action taint and Lua warnings.
- **Never spams your frame rate** — a token-bucket throttle pauses capture during an error storm so addon CPU never competes with rendering.
- **Remembers across sessions** — errors persist in SavedVariables, grouped by play session, with a hard cap so the file never balloons.
- **Share bugs peer-to-peer** — send a caught error to another Sentinel user and triage it together.
- **Native & modern** — Blizzard Settings panel, Addon Compartment entry, modern scrollbars, and an ornate Maw/runecarving frame skin over a flat dark theme.

---

## Installation

**Via an addon manager (recommended)**
- [CurseForge](https://www.curseforge.com/wow/addons/sentinel) — search for **Sentinel** and install.

**Manual**
1. Download the latest release from the [Releases](https://github.com/Kkthnx-Wow/Sentinel/releases) page.
2. Extract the `!Sentinel` folder into `World of Warcraft\_retail_\Interface\AddOns`.
3. Restart the game (or `/reload` if already in-game).

The leading `!` keeps Sentinel near the top of the load order so it can hook the error handler as early as possible.

---

## Getting Started

| Command | Description |
| --- | --- |
| `/sentinel` or `/sen` | Toggle the Sentinel window |
| `/sen config` | Open the settings panel |
| `/sen clear` | Wipe all stored errors |
| `/sen test` | Fire a genuine test error (real stack + locals) to verify capture |

### Minimap button

| Action | Result |
| --- | --- |
| **Left-click** | Open the error window |
| **Right-click** | Open settings |
| **Shift-click** | Reload the UI |
| **Alt-click** | Wipe all stored errors |
| **Drag** | Reposition around the minimap ring |

Sentinel also registers an **Addon Compartment** entry, so it's reachable even with the minimap button hidden.

---

## Features

### Error Capture
- **Full stack + locals** — captures the call stack and local variables at the real fault site, the same way Blizzard's own handler does.
- **Sole-owner handler** — installs its error handler last and prevents it from being silently replaced, and disables legacy grabbers (`!BugGrabber`, `!Swatter`, `!BaudErrorFrame`) so capture is never swallowed.
- **Taint & warnings** — also records `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN`, the macro equivalents, and `LUA_WARNING`, while suppressing the default blue blocked-action popups.
- **Dedupe + counts** — repeated errors are collapsed into one entry with an occurrence counter and re-stamped time.
- **Flood protection** — a token-bucket throttle pauses capture if errors arrive faster than a safe rate, protecting your FPS.

### The Window
- **Tabbed views** — **All bugs**, **This session**, **Previous session**, **Received**, plus live **Search**.
- **Smart default** — opens to *This session*, or falls back to *All bugs* when the session is clean but older bugs exist, so you never land on an empty list.
- **Syntax-highlighted detail** — colourised stack traces and locals in a readable, scrollable pane.
- **Hover tooltips** — every row shows occurrences, last-seen date/time, session, and (for shared bugs) who sent it.
- **Copy & Export** — copy a single error or export the whole list as clean plaintext, ready to paste into a ticket or Discord.

### Sharing
- **Send to a player** — share the selected error with another Sentinel user via a chunked, throttled addon channel (AceComm-3.0 + AceSerializer-3.0).
- **Received tab** — incoming bugs are tagged with the sender's name and marked with a `*` in the list.
- **Secret-safe transport** — Secret values are stripped before sending, and sharing is disabled inside instances (where Midnight blocks addon messages) with a nudge to use Export instead.

### Settings
A clean options page built on Blizzard's own **Settings API**:
- Toggle the minimap button
- Throttled sound on new errors
- Chat announcement on new errors
- Auto-open the window on a new error (never during combat)
- One-click **wipe** of all stored errors

### Performance & Safety
- **Event-driven throughout** — no idle `OnUpdate`; the minimap button only polls while being dragged.
- **Combat-aware** — never opens the window or fights the secure environment during combat lockdown.
- **Memory-conscious** — pooled list rows, reused tables, and a capped error store.
- **Persistence done right** — `LoadSavedVariablesFirst`, default-merging, and schema versioning for safe upgrades.

---

## Configuration

Open the panel with **`/sen config`** (or through the Blizzard AddOns settings). All toggles apply live. Settings are bound directly to your SavedVariables, so they persist per account.

---

## Contributing

Contributions, bug reports and ideas are welcome! Open an [issue](https://github.com/Kkthnx-Wow/Sentinel/issues) or a pull request. When filing a bug, including your client version and a `/reload`-able repro helps a ton.

---

## Credits

Sentinel is a ground-up rewrite, but it stands on the shoulders of the addons that defined Lua error handling in WoW — studied with respect and reimagined for the modern client:

- **Rabbit & contributors** (**!BugGrabber**) — the proven error-handler ownership and stack/locals capture approach.
- **Funkydude & contributors** (**BugSack**) — inspiration for friendly error display and peer sharing.
- **Baudtack** (**!BaudErrorFrame**) — the original lightweight error-frame concept this project grew out of.
- **The Ace3 team** — AceComm-3.0, AceSerializer-3.0, CallbackHandler-1.0 and LibStub, embedded for sharing.

Sentinel reuses none of their code verbatim — it's a new implementation with its own architecture, UI, persistence, sharing, and Midnight Secret-Value compatibility layer.

---

## Support

Appreciate the work that goes into Sentinel? Consider showing your support:

- **PayPal** — [paypal.me/KkthnxTV](https://www.paypal.com/paypalme/kkthnxtv)
- **Patreon** — [patreon.com/Kkthnx](https://www.patreon.com/Kkthnx)
- **Battle.net / Balance** — `Kkthnx#1105` or `JRussell20@gmail.com`
- **In-game gold** — Kkthnx on Area 52 (US)

---

## License

Released under the **MIT License**. See [LICENSE](https://github.com/Kkthnx-Wow/Sentinel/blob/main/LICENSE) for details.

<div align="center">

Developed and maintained by **Josh "Kkthnx" Russell**. Built to keep your UI honest.

</div>

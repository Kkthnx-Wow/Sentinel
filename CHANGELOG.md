# Changelog

All notable changes to **Sentinel** are documented here. This project follows
[Semantic Versioning](https://semver.org/) and the spirit of
[Keep a Changelog](https://keepachangelog.com/).

## [1.5.5] - 2026-06-16

### Added

- **Wipe confirmation** dialog before Clear, settings Wipe, Alt-click minimap wipe,
  and `/sen clear` — prevents accidental total data loss.
- **Comm protocol v1** (`{ v = 1, errors = {…} }`) with legacy bare-array receive
  support and a localized notice for unknown versions.
- **Per-sender receive rate cap** (30 new stored reports per 60s) to limit
  SavedVariables growth from whisper spam.
- **Taint log** button in the Blizzard settings panel (retail clients with the
  `taintLog` CVar).
- **`ns.NotSecret`** helper alongside `ns.IsSecret` / `ns.CanAccess`.
- **Full locale overrides** for all UI strings (settings, slash help, tooltips,
  taint log) across deDE, esES/esMX, frFR, koKR, ruRU, zhCN, zhTW, ptBR, itIT.

### Fixed

- **False login alerts** when only deduped load-screen errors were present (alerts
  now require a genuinely new capture via `hadNewErrorThisLoad`).
- **Secret guards** on comm receive path (`clip`, dedupe compare) before any
  string operations on deserialized data.

### Changed

- Search box refresh is **debounced** (150ms) to reduce list rebuild churn while
  typing.
- `DB.GetBySession` / `DB.GetReceived` reuse scratch tables; main window list
  building avoids throwaway `{}` on every refresh.
- Localized hardcoded English prints (missing-library comm fallback, `/sen test`).

## [1.5.4] - 2026-06-16

### Fixed

- **Minimap button orbit** now uses LibDBIcon-style positioning (minimap shape quads,
  half-width + 5px radius, 18×18 retail icon) so the tracking ring sits on the
  outside edge instead of overlapping the minimap border. Repositions when the
  minimap is resized (Edit Mode).

### Changed

- Minimap button uses file IDs for ring/background art and `SetFixedFrameStrata`
  where supported, matching current retail minimap button conventions.

## [1.5.3] - 2026-06-16

### Added

- **Stack/locals refresh** on recurring errors idle for more than two minutes (from
  !BugGrabber), so long-running intermittent bugs keep an up-to-date trace.
- **Session-wide send**: Shift+click **Send** (or the session send dialog) whispers
  every error from the current session to another Sentinel user, up to 50 per
  message. Receive cap raised to match.
- **DB sanitation** on load strips corrupt rows where `message` was stored as a table
  (BugGrabber `lastSanitation` pass).
- **Locale overrides** for deDE, esES/esMX, frFR, koKR, ruRU, zhCN, zhTW, ptBR,
  and itIT (`Core/LocaleOverrides.lua`).

## [1.5.2] - 2026-06-16

### Added

- **TaintLog** button on the error window footer (between Send and Delete). Left-click
  cycles Blizzard's `taintLog` CVar (0–4); the label shows the current level
  (`TaintLog: Off` or `TaintLog: 1` … `TaintLog: 4`). Debug output is written to
  `taint.log` in your World of Warcraft folder. Also available via `/sen taintlog`
  and shown in `/sen status`. Hidden on clients without the CVar (Classic flavors).

## [1.5.1] - 2026-06-16

### Fixed

- 12.0.7 / Midnight hardening: error capture now checks `issecretvalue()` **before**
  calling `tostring()` on the fault message (which can throw on a Secret), and
  `LUA_WARNING` text is guarded with both `issecretvalue` and `canaccessvalue`
  before any string concatenation.
- `!BugGrabber` is now included in the legacy grabber disable list, matching the
  README and ensuring a clean handoff of `seterrorhandler` ownership.
- Automatic flood-protection pause (`too many errors per second`) is now visible in
  `/sen status` and the minimap/broker tooltip, distinct from the manual pause
  toggle.

### Changed

- TOC now declares both `120007` (12.0.7) and `120005` (12.0.5) interface numbers.
- Added `ns.IsSecret`, `ns.CanAccess`, `canaccessvalue` caching, and runtime
  `IS_MIDNIGHT` / `IS_12_0_7` flags for patch-aware code paths.
- Public API: `Sentinel.GetVersion()` and `Sentinel.IsFloodPaused()`.

## [1.5.0] - 2026-06-13

### Added

- Selected-error deletion. A new `Delete` button removes only the currently
  selected report, leaving the rest of your history intact; `Clear` remains the
  full wipe action.
- Manual capture pause/resume. Use the new "Pause error capture" setting, `/sen
  pause`, or `/sen resume` when a known bad addon is spamming and you want
  Sentinel to stop recording new errors temporarily. The minimap/broker tooltip
  now shows when capture is paused.
- `/sen sound` toggles the new-error sound on/off on the fly, mirroring the
  existing "Play a sound on new errors" setting without opening the panel.
- `/sen chat` toggles new-error chat announcements the same way, and `/sen status`
  prints the current capture, sound, chat, blocked-action, and stored-error state
  at a glance.
- `/sen help` now lists every slash command so users can discover `config`,
  `clear`, `pause`, `resume`, `sound`, `chat`, `status`, `test`, and `build`
  without reading the README.
### Security

- Hardened inbound error sharing against abuse. Reports received from other
  players are now fully untrusted: the serialized payload is size-capped before
  decoding, at most a handful of errors are accepted per message, the message,
  stack, and locals fields are length-capped, repeats from the same sender are
  deduped into a single entry, and the "received from" chat line is throttled.
  Together these stop a malicious or buggy peer from flooding your chat or bloating
  your SavedVariables. Received entries are also rebuilt from known fields only and
  stamped with your own clock rather than the sender's.

### Fixed

- The new-error sound (and chat announcement / auto-open) now fires only for
  genuinely new, unique errors, matching the setting's own description. Previously
  the alert pipeline ran for every captured error, including repeats, so a single
  recurring error from another addon would replay the sound and re-print "A new
  error was caught" every few seconds — and could re-open a window you had just
  closed. Repeats still refresh the window and minimap count; they just no longer
  re-alert.

## [1.4.0] - 2026-06-12

### Added

- Setting to ignore blocked-action (taint) errors. A new "Capture blocked-action
  errors" toggle (on by default) lets you opt out of `ADDON_ACTION_FORBIDDEN` /
  `ADDON_ACTION_BLOCKED` and the macro equivalents. When off, these are ignored at
  capture time — no list entry, no sound/chat alert, no auto-open — so unfixable
  taint noise from other addons stays out of your way.

### Fixed

- Fixed Copy/Export showing an empty box for some errors. When the captured stack
  or locals contained WoW escape sequences — most often the Battle.net name token
  (`|K…|k`) seen in friends-list errors, or inline textures (`|T…|t`) — they were
  fed raw into the read-only EditBox, which renders blank on an escape it can't
  resolve. Copy/Export now neutralises those sequences (matching the pipe escaping
  the detail pane already used), so every error copies reliably.
- Restored non-printable character escaping. It was wired to
  `C_StringUtil.EscapeDecimalNonPrintables`, which does not exist on the live
  client, so the guard silently did nothing. Control bytes in an error message,
  stack, or locals dump are now escaped in Lua (preserving tabs, newlines, and
  UTF-8 text), so a stray control character can't corrupt the display or truncate
  the text.

## [1.3.0] - 2026-06-10

### Added

- LibDataBroker-1.1 "data source" launcher. Sentinel now exposes an LDB object so
  broker display addons (Titan Panel, ChocolateBar, Bazooka, etc.) can surface the
  live error count, tooltip, and left/right/shift/alt click actions on a panel
  instead of the minimap ring — useful when the minimap is already crowded. The
  data source always registers and stays in sync even when the minimap button is
  hidden, and the library degrades gracefully if it ever fails to load.
- Hover tooltips on every tab and action button. Each tab (All bugs, This
  session, Previous session, Received) and each button (Copy, Export, Send,
  Clear, Reload UI) now explains what it does on hover, making the difference
  between Copy (just the selected error) and Export (every error in the current
  tab) obvious at a glance.

### Fixed

- Copy/Export now produces genuinely plain text. Captured data such as Blizzard
  POI/map field dumps embeds WoW colour escapes, which previously leaked into the
  export box — rendering as colour on screen and pasting into Discord/pastebin as
  raw colour-code garbage. Both the classic hex (`|cAARRGGBB…|r`) and the named
  (`|cnCOLOR_NAME:…|r`) colour forms are now stripped, so shared reports are
  clean. The colored detail pane is unaffected.

## [1.2.0] - 2026-06-09

### Added

- Added `/sen wowbuild` (also available as `/sen build`) to print the current
  WoW client version, build number, build date, and numeric interface/TOC
  version for quick bug-report context.

### Changed

- The selected tab is now clearly highlighted. Previously the active and resting
  tabs used nearly identical teal vertex tints, so the current view was almost
  impossible to tell apart. Each tab now draws Blizzard's
  `auctionhouse-nav-button-secondary-select` atlas — purpose-built for
  rectangular nav buttons — as a cyan highlight that shows only on the active
  tab and follows tab/search selection automatically.
- Error-message identifiers now stand out. The offending symbol that Lua names in
  single quotes (e.g. `attempt to index local 'victim'`) is lifted into the same
  aqua used for local variable names, so the culprit pops against the white
  headline while the rest of the message stays crisp. This applies only to the
  colored detail pane; copy/export plaintext is unchanged.

## [1.1.0] - 2026-06-09

### Changed

- Reworked the detail-pane syntax highlighting around a centralized cyan/silver
  palette (`ns.SYNTAX`). The headline now tokenizes `path:line: message` so the
  file path is soft cyan, the line number is bright cyan, punctuation is slate
  gray, and the actual error message stays crisp white. Stack and locals
  highlighting still use lightweight `gsub` passes, with light-silver base text,
  electric-blue counts/numbers, aqua local names, silver strings, soft-red `nil`,
  and amber booleans. Color prefixes are cached once at load so formatting does
  not regenerate WoW color codes.
- Refined the visual theme to use Sentinel's cyan/teal brand consistently across
  the window title, addon-list title, counters, minimap tooltip header, tabs,
  action buttons, and close buttons. Buttons now keep Blizzard's native bevel art
  while using desaturated teal-tinted states and white labels.

### Fixed

- The window now selects its default tab the very first time it is opened.
  Previously the tab was only chosen in the frame's `OnShow` handler, but a newly
  created frame is already shown, so the first `UI.Open()` call to `Show()` was a
  no-op that never fired `OnShow` — leaving the list with no active tab until the
  window was closed and reopened. The frame is now hidden once at build time so
  the first open is a real hidden-to-shown transition.
- Receiving a shared error from another player no longer behaves like a fresh
  local fault. It previously fired the same event as a local capture, so it
  played the alert sound, printed "A new error was caught," and could auto-open
  the window. Received bugs now fire a distinct `Sentinel.ErrorReceived` event
  that only refreshes the window and minimap badge, while the alert pipeline
  stays reserved for genuine local errors (mirroring BugGrabber/BugSack's split
  between grabbed and received reports).

## [1.0.0] - 2026-06-09

The first public release of Sentinel — a modern, Secret-Value-safe Lua error
watcher for the Midnight-era WoW client.

### Added

**Error capture**

- Sole-owner error handler that captures the full call stack and locals at the
  real fault site, installed early via the leading `!` load order.
- Capture of taint events (`ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN`),
  the macro equivalents, and `LUA_WARNING`, with the default blue blocked-action
  popups suppressed.
- Deduplication with per-error occurrence counters and re-stamped timestamps.
- Token-bucket flood protection that pauses capture during an error storm to
  protect frame rate, with a re-entrancy guard against recursive faults.
- Automatic disable of legacy grabbers (`!BugGrabber`, `!Swatter`,
  `!BaudErrorFrame`) so capture is never silently swallowed.

**Window & display**

- Tabbed views: All bugs, This session, Previous session, Received, and Search.
- Smart default tab on open (This session, falling back to All bugs when the
  session is clean but older bugs exist).
- Syntax-highlighted, scrollable detail pane for stack traces and locals.
- Per-row hover tooltips showing occurrences, last-seen date/time, session, and
  sender (for shared bugs).
- Copy a single error or export the entire list as clean plaintext.
- Flat dark theme with an ornate Maw/runecarving frame border and modern
  scrollbars.

**Sharing**

- Send a caught error to another Sentinel user over a chunked, throttled addon
  channel (AceComm-3.0 + AceSerializer-3.0).
- Received bugs are tagged with the sender's name and flagged with a `*`.
- Secret values are stripped before sending; sharing is blocked inside instances
  (where Midnight disallows addon messages) with a prompt to use Export instead.

**Access & settings**

- Self-contained minimap button with a live error-count badge, drag-to-position,
  a rich tooltip, and an Addon Compartment entry.
- Options panel on Blizzard's Settings API: minimap toggle, throttled sound,
  chat announcement, auto-open on error, and a one-click wipe.
- Slash commands: `/sentinel`, `/sen`, `/sen config`, `/sen clear`, `/sen test`.

**Under the hood**

- Midnight Secret-Value safety across every UI and formatting path.
- Persistence via SavedVariables with `LoadSavedVariablesFirst`, default
  merging, schema versioning, and a hard cap on stored errors.
- Event-driven design with no idle `OnUpdate`, pooled list rows, and
  combat-lockdown-aware behavior throughout.

[1.5.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.5.0
[1.4.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.4.0
[1.3.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.3.0
[1.2.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.2.0
[1.1.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.1.0
[1.0.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.0.0

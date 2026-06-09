# Changelog

All notable changes to **Sentinel** are documented here. This project follows
[Semantic Versioning](https://semver.org/) and the spirit of
[Keep a Changelog](https://keepachangelog.com/).

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

[1.1.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.1.0
[1.0.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.0.0

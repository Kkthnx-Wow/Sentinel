# Changelog

All notable changes to **Sentinel** are documented here. This project follows
[Semantic Versioning](https://semver.org/) and the spirit of
[Keep a Changelog](https://keepachangelog.com/).

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

[1.0.0]: https://github.com/Kkthnx-Wow/Sentinel/releases/tag/v1.0.0

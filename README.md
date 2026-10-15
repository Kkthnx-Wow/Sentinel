# Sentinel

[![Last Commit](https://img.shields.io/github/last-commit/Kkthnx-Wow/Sentinel)](https://github.com/Kkthnx-Wow/Sentinel/commits/main)
[![Issues](https://img.shields.io/github/issues/Kkthnx-Wow/Sentinel)](https://github.com/Kkthnx-Wow/Sentinel/issues)
[![CurseForge](https://img.shields.io/badge/CurseForge-Download-orange)](https://www.curseforge.com/wow/addons/sentinel)
[![License](https://img.shields.io/badge/License-All%20Rights%20Reserved-red.svg)](https://github.com/Kkthnx-Wow/Sentinel/blob/main/LICENSE)

A modern Lua error display for World of Warcraft. It captures full stacks and locals, then lets you copy, export, or send the bug straight to a friend.

## What it does

- Takes over the game's error handler and captures Lua errors with full call stacks and locals.
- Shows errors in a clean, dark window with copy, export, and peer-to-peer sharing.
- Records taint and Lua warnings, deduplicates repeats, and throttles capture during error storms so your frame rate stays safe.
- Persists errors across sessions, grouped by play session, with a hard cap on file size.
- Respects Midnight's Secret Value system, so it degrades safely instead of erroring on its own.
- Reaches it from a minimap button, the Addon Compartment, or any LibDataBroker display.

## Get it

Install from [CurseForge](https://www.curseforge.com/wow/addons/sentinel), or download the latest release from the [Releases](https://github.com/Kkthnx-Wow/Sentinel/releases) page and extract the `!Sentinel` folder into `World of Warcraft/_retail_/Interface/AddOns`.

## Quick start

1. Install Sentinel. The leading `!` in the folder name keeps it early in the load order.
2. Restart the game, or type `/reload` if you are already logged in.
3. Open the window with `/sen`.
4. Run `/sen test` to fire a real test error and confirm capture works.
5. Tweak behavior anytime with `/sen config`.

## Support the work

Free forever. If it saved you time, chip in:

- [Ko-fi](https://ko-fi.com/kkthnx)
- [Buy Me a Coffee](https://buymeacoffee.com/kkthnx)
- [PayPal](https://www.paypal.com/paypalme/kkthnxtv)

Every bit goes back into building more.

## Community

- Glitch Haven Discord: https://discord.gg/FaVGhTYmck
- Website: https://kkthnx.com

## License

All Rights Reserved. Download and run Sentinel for your own personal use in World of Warcraft. Do not copy its source or assets into another project, redistribute the addon, or publish a modified version without written permission. Bundled libraries under `Libs/` keep their own original licenses. See LICENSE for the full text.

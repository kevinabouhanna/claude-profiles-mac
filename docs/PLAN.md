# The plan

Claude Profiles shows every Claude Code account's usage in the Mac's menu bar, and switches
between them in one click, through claude-swap (`cswap`). It runs all day on battery, so it
spends almost nothing, and it never touches a credential itself.

This file is the map. Each phase has a page in [`phases/`](phases/), a GitHub milestone and a
phase issue; each thing to build in it is an issue under that phase issue. The order is the
[project board](https://github.com/users/kevinabouhanna/projects/7)'s, and
[`phases/README.md`](phases/README.md) lists it, written by `docs-kit plan sync`.

## Where it stands

The app is out, signed and notarized: usage in the menu bar and a dropdown for every account,
pace markers and a forecast, switching from the status bar's Switch menu, renaming, Auto-Switch,
a menu bar styled to taste, light and dark, local only. Its README pictures redraw themselves
from made-up data (product-kit's shots-kit).

## The phases

| Phase | What it gives | Page |
|---|---|---|
| **1. The app** | Usage and switching in the menu bar, for every account | [01-the-app](phases/01-the-app.md) |
| **2. Numbers you can trust** | Readings that match Claude's own, pace colours by how much is used, a forecast only when it means something | [02-numbers-you-can-trust](phases/02-numbers-you-can-trust.md) |
| **3. API credits** | The credits left, shown only when there are some | [03-api-credits](phases/03-api-credits.md) |

Phase numbers are names, not the order: the board's Order is.

## Why this order

The numbers come first: an app whose whole job is to show usage has to show it right before it
shows anything more. The inaccurate reading (#34) is a bug, so it leads; then the colours (#20)
and the forecast (#30), which decide how the numbers read. API credits (#31) are something new,
for later.

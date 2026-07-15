# Cooldown

A tiny macOS menu-bar app that keeps a fanless Mac (M-series Air) from getting hot.
A fanless Mac can only cool by doing **less work**, so Cooldown shows live CPU load
and can calm the two chronic heat sources: Spotlight indexing and runaway CPU hogs.

## Features
- **Live CPU %** in the menu bar (instantaneous, from mach tick counters — no polling overhead when idle).
- **Ring gauge + load averages + top CPU consumers** in the popover.
- **Calm Down** — pauses Spotlight indexing (if sudo is cached) and lowers the priority of your CPU hogs. All reversible.
- **Auto-calm** — optionally calms automatically when CPU stays above 85% for 30s (3-minute re-arm, no spam).
- **Self-update** — checks GitHub Releases and updates in place.

Wraps the `~/cooldown.sh` script for the heavy actions.

## Install / update
One-liner (downloads, unpacks, installs to `~/Applications`, launches):
```bash
cd /tmp && curl -fsSL https://github.com/haonguyenstech/cooldown/releases/latest/download/Cooldown.zip -o Cooldown.zip && ditto -x -k Cooldown.zip . && bash Cooldown/Install.command
```
Or download `Cooldown.zip` from
[Releases](https://github.com/haonguyenstech/cooldown/releases), unzip, and run `Install.command`.

> Note: the old `Cooldown-*.zip` wildcard URL does **not** work — the shell tries to
> glob `*` locally and GitHub doesn't expand it. Use the stable `Cooldown.zip` name above.

Once installed, the app self-updates: **Check** → **Update Now** in the popover.

## Build from source
```
./build.sh      # compile universal binary → ~/Applications/Cooldown.app
./release.sh    # package + publish a new GitHub release (maintainer)
```

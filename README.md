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
One-liner (installs the latest release to `~/Applications`, strips quarantine, launches):
```bash
curl -fsSL https://raw.githubusercontent.com/haonguyenstech/cooldown/master/install.sh | bash
```
Run it again any time to update. Or download `Cooldown.zip` from
[Releases](https://github.com/haonguyenstech/cooldown/releases), unzip, and run `Install.command`.

Then toggle **Start at login** in the popover so it launches automatically — and the app
also self-updates via **Check → Update Now**.

> The old `Cooldown-*.zip` wildcard URL does **not** work — the shell globs `*` locally
> and GitHub doesn't expand it. Use the installer above (or the stable `Cooldown.zip` name).

## Build from source
```
./build.sh      # compile universal binary → ~/Applications/Cooldown.app
./release.sh    # package + publish a new GitHub release (maintainer)
```

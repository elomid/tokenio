# Tokenio

Tiny macOS menu bar app that shows your Claude AI usage at a glance.

![Menu bar and popup](docs/screenshot.png)

## What it shows

- **Current session** (5-hour window) — usage % with pace indicator
- **Weekly — All models** (7-day window)
- **Weekly — Sonnet only** (7-day window)
- **Extra usage** — dollar amount and utilization

Each bar is color-coded by pace: **green** = under pace, **yellow** = on pace, **orange** = over pace. The transparent notch shows where you are in the time window.

## Install

Download the latest `.zip` from [Releases](https://github.com/elomid/tokenio/releases), unzip, and drag `Tokenio.app` to your Applications folder.

Requires macOS 13 (Ventura) or later.

## Auth

On first launch, Tokenio opens a browser window to sign in to your Claude account. This works with any login method (Google, Apple, email, etc.).

Your session is stored in the macOS Keychain. If you also use Claude Code CLI, Tokenio can use its existing credentials as a fallback — no login needed.

## Build from source

```bash
git clone https://github.com/elomid/tokenio.git
cd tokenio
xcodebuild -project Tokenio.xcodeproj -scheme Tokenio -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/Tokenio-*/Build/Products/Release/Tokenio.app`.

## How it works

Tokenio reads usage data from Claude's internal API using your session cookie — the same data you see on the [usage page](https://claude.ai/settings/usage). It refreshes every 5 minutes.

No data is sent anywhere except to `claude.ai` for fetching your usage.

## License

MIT

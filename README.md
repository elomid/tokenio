# Tokenio

Tiny macOS menu bar app that shows your Claude AI usage at a glance.

![Menu bar and popup](docs/screenshot.png)

## What it shows

- **Current session** (5-hour window) — usage % with pace indicator
- **Weekly — All models** (7-day window)
- **Weekly — Sonnet only** (7-day window)
- **Extra usage** — dollar amount and utilization

Each bar is color-coded: **green** = normal, **orange** = near limit (≥90%), **red** = at limit. The transparent notch shows where you are in the time window.

The menu bar icon shows two small bars: the top bar is your current session usage, and the bottom bar is your weekly usage.

## Install

Download the latest `.zip` from [Releases](https://github.com/elomid/tokenio/releases), unzip, and drag `Tokenio.app` to your Applications folder.

Requires macOS 13 (Ventura) or later, and **Claude Code CLI** (must be installed and logged in). Designed for Claude Pro and Max subscribers.

Tokenio enables Launch at Login on first run — you can toggle this from the menu.

## Auth

Tokenio reads usage data using Claude Code CLI's OAuth credentials — no separate login required. On first launch (or after installing a new version), click **Connect to Claude Code…** in the menu. macOS may show a one-time prompt to allow Tokenio access to Claude Code's keychain item — click Always Allow if it appears. After that, Tokenio runs silently with no further prompts.

## Build from source

```bash
git clone https://github.com/elomid/tokenio.git
cd tokenio
xcodebuild -project Tokenio.xcodeproj -scheme Tokenio -configuration Release -derivedDataPath build build
```

The built app will be in `build/Build/Products/Release/Tokenio.app`.

## How it works

Tokenio reads usage data from Anthropic's OAuth usage API using Claude Code's credentials. The API is undocumented and may change without notice. Data refreshes every 5 minutes.

Usage data is only exchanged with `api.anthropic.com`. No credentials leave your machine.

## Known limitations

- Relies on Claude's internal API, which may break when Anthropic changes it.
- Requires Claude Code CLI — does not work with a standalone Claude account.
- If you belong to multiple organizations, usage shown is for your primary account.

## License

MIT

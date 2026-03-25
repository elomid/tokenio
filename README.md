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

Requires macOS 13 (Ventura) or later. Designed for Claude Pro and Max subscribers.

Tokenio enables Launch at Login on first run — you can toggle this from the menu.

## Auth

On first launch, Tokenio opens a sign-in window to log in to your Claude account. This works with any login method (Google, Apple, email, etc.).

Your session is stored in the macOS Keychain. If you also use Claude Code CLI, Tokenio can use its existing credentials as a fallback — no login needed. macOS will show a one-time prompt asking to allow Tokenio access to the Claude Code keychain item; this is expected.

## Build from source

```bash
git clone https://github.com/elomid/tokenio.git
cd tokenio
xcodebuild -project Tokenio.xcodeproj -scheme Tokenio -configuration Release -derivedDataPath build build
```

The built app will be in `build/Build/Products/Release/Tokenio.app`.

## How it works

Tokenio reads usage data from Claude's internal usage API — the same data shown on the [usage settings page](https://claude.ai/settings/usage). This API is undocumented and may change without notice. Data refreshes every 5 minutes.

Usage data is only exchanged with `claude.ai` and `api.anthropic.com`. During login, your browser may connect to third-party auth providers (Google, Apple, Microsoft, GitHub) depending on your sign-in method.

## Known limitations

- Relies on Claude's internal API, which may break when Anthropic changes it.
- If you belong to multiple organizations, Tokenio uses the first one returned by the API.
- Adding a new SSO provider on Claude's side may require an app update.

## License

MIT

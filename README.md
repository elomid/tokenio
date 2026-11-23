# Tokenio

A tiny macOS menu bar app for tracking Claude, Codex, and Antigravity usage.

**[Download Tokenio.zip](https://github.com/elomid/tokenio/releases/latest/download/Tokenio.zip)**

Requires macOS 13 or later. Supports Apple Silicon and Intel. Signed and notarized.

## Get started

Unzip the download, drag `Tokenio.app` to Applications, and open it. Tokenio lives in your menu bar.

Choose a provider on the welcome screen:

- **Claude:** Click **Log in to Claude** and choose **Continue with email**. Google sign-in is not supported.
- **Codex:** Install the Codex CLI, sign in with `codex login`, then click **Use Codex** in Tokenio.
- **Antigravity:** Install the Antigravity CLI (`agy`, version 1.1.11 or later), sign in by running `agy` once in Terminal, then click **Use Antigravity** in Tokenio.

Click the menu bar icon to see your usage. Use **Providers** under the **•••** button to turn each account on or off. Your choices are saved; hidden providers aren't checked for usage.

Use **Menu Bar Icon** to choose which enabled providers get a bar in the menu bar icon. For example, show Claude and Antigravity in the icon while keeping Codex in the menu.

Launch at Login is enabled on first run. You can turn it off under **•••**.

## What it shows

- **Claude:** Current session and weekly usage, plus Fable usage and extra spending when available.
- **Codex:** Usage window from your existing CLI login (weekly, or the plan's longest window such as 30-day).
- **Antigravity:** Google model limits reported by `agy`, such as the 5-hour and weekly Gemini limits (Claude and GPT groups are hidden since Tokenio tracks them directly). The menu bar icon shows the primary 5-hour and weekly limits.

Each limit is a vertical bar, grouped by provider, in both the menu bar icon and the panel. The fill shows how much is used, and the mark shows how much of the window has passed, so you can judge your pace. Under each bar is the time until it resets. Choose **Show › Left** under **•••** if you'd rather see what's left.

Usage refreshes every five minutes and when your Mac wakes. Click **Updated** at the bottom of the panel to refresh every provider. If a refresh fails, saved usage stays visible with a warning sign next to the provider's name; click it for the error and a retry button.

## Update

Quit Tokenio, download the latest ZIP above, replace the app in Applications, and reopen it. Your login and preferences are kept.

See [release notes](https://github.com/elomid/tokenio/releases) for changes.

## Account details

Claude sessions are stored in the macOS Keychain. Codex and Antigravity use their CLIs' existing authentication; checking usage does not start a model turn or spend quota. Tokenio checks the `agy` version first and won't ask older versions for usage, because they would treat the request as a prompt.

Claude's usage API is undocumented and may change. If you belong to multiple Claude organizations, Tokenio shows usage for your primary account.

## Build from source

With Xcode installed:

```bash
git clone https://github.com/elomid/tokenio.git
cd tokenio
xcodebuild -project Tokenio.xcodeproj -scheme Tokenio -configuration Release -derivedDataPath build build
```

The app is at `build/Build/Products/Release/Tokenio.app`.

Run regression checks with `./scripts/test.sh`.

## License

[MIT](LICENSE)

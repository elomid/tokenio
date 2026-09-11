# Tokenio

A tiny macOS menu bar app for tracking Claude usage, Codex usage, or both.

**[Download Tokenio.zip](https://github.com/elomid/tokenio/releases/latest/download/Tokenio.zip)**

Requires macOS 13 or later. Supports Apple Silicon and Intel. Signed and notarized.

## Get started

Unzip the download, drag `Tokenio.app` to Applications, and open it. Tokenio lives in your menu bar.

Choose a provider on the welcome screen:

- **Claude:** Click **Log in to Claude** and choose **Continue with email**. Google sign-in is not supported.
- **Codex:** Install the Codex CLI, sign in with `codex login`, then click **Use Codex** in Tokenio.

Use **Providers** in the menu to enable either account or both. Your choices are saved; hidden providers aren't checked for usage.

Launch at Login is enabled on first run. You can turn it off in the menu.

## What it shows

- **Claude:** Current session and weekly usage, plus Fable usage and extra spending when available.
- **Codex:** Weekly usage from your existing CLI login.

Each bar shows usage and time until reset. The notch marks elapsed time in the usage window so you can judge your pace. Claude bars are monochrome, Fable is blue, and Codex is purple.

Usage refreshes every five minutes and when your Mac wakes. Click the update time to refresh manually. If a refresh fails, saved usage stays visible; click **details…** for the error and a retry button.

## Update

Quit Tokenio, download the latest ZIP above, replace the app in Applications, and reopen it. Your login and preferences are kept.

See [release notes](https://github.com/elomid/tokenio/releases) for changes.

## Account details

Claude sessions are stored in the macOS Keychain. Codex uses the CLI's existing authentication; checking usage does not start a model turn.

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

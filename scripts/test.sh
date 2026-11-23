#!/bin/bash
set -euo pipefail
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Tokenio/CodexUsage.swift Tests/CodexUsageTests.swift -o "$TEST_DIR/codex-tests"
swiftc Tokenio/AntigravityUsage.swift Tests/AntigravityUsageTests.swift -o "$TEST_DIR/antigravity-tests"
"$TEST_DIR/antigravity-tests"
"$TEST_DIR/codex-tests"
# Build a menu harness without starting network requests, login, launch-at-login,
# or touching the user's Keychain/preferences.
python3 - "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
s = Path('Tokenio/TokenioApp.swift').read_text().replace('@main\n', '')
s = s.replace('loadSession()', 'testSession()')
s += '\nvar testSessionValue: Session? = nil\nfunc testSession() -> Session? { testSessionValue }\n'
s += Path('Tests/MenuChecks.swift').read_text()
(out / 'TokenioApp.swift').write_text(s)
(out / 'main.swift').write_text('import AppKit\nAppDelegate.runMenuChecks()\n')
PY
swiftc "$TEST_DIR/TokenioApp.swift" "$TEST_DIR/main.swift" Tokenio/CodexUsage.swift Tokenio/AntigravityUsage.swift Tokenio/UsageService.swift Tokenio/UsagePanel.swift Tokenio/BarRenderer.swift Tokenio/LoginWindow.swift Tokenio/WelcomeWindow.swift -o "$TEST_DIR/menu-tests"
"$TEST_DIR/menu-tests"

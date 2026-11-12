#!/bin/zsh
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/AlparslanSemiz/Serit/main/install.sh | zsh
# Builds Şerit from source on your Mac (so Gatekeeper has nothing to quarantine),
# installs it to ~/Applications and starts it at login.
set -euo pipefail

REPO="https://github.com/AlparslanSemiz/Serit.git"
SRC="$HOME/.local/src/Serit"

if [[ "$(uname)" != "Darwin" ]]; then echo "Şerit runs on macOS only."; exit 1; fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Şerit needs Apple's Command Line Tools to build. Starting the installer…"
  xcode-select --install || true
  echo "Run this script again when the Command Line Tools are installed."; exit 1
fi

echo "→ Getting the source"
if [[ -d "$SRC/.git" ]]; then git -C "$SRC" pull --ff-only --quiet
else mkdir -p "${SRC:h}"; git clone --quiet --depth 1 "$REPO" "$SRC"; fi

pkill -x Pock 2>/dev/null && echo "  (closed Pock so the two don't fight over the Touch Bar)" || true

echo "→ Building"
"$SRC/build.sh"

echo
echo "Done. Two permissions are left, both in System Settings → Privacy & Security:"
echo "  • Accessibility → Şerit   (badges and media keys)"
echo "  • Location Services → Şerit   (weather for where you are; optional)"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true

#!/bin/zsh
# Removes Murmur: the app, its login item, settings, your vocabulary file, dictation
# history and its privacy permissions.
#
#   scripts/uninstall.sh          # asks before removing
#   scripts/uninstall.sh --yes    # no questions
#   scripts/uninstall.sh --keep-vocabulary   # keep vocabulary and history
#
# The "Murmur Dev" signing identity is left in your keychain; the end of the output
# says how to delete it.
set -euo pipefail

BUNDLE_ID="io.github.garfield-oo7.Murmur"
APP="$HOME/Applications/Murmur.app"
SUPPORT="$HOME/Library/Application Support/Murmur"
assume_yes=0
keep_vocabulary=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) assume_yes=1 ;;
    --keep-vocabulary) keep_vocabulary=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "This removes:"
echo "  • $APP"
echo "  • Murmur's login item, settings and privacy permissions"
(( keep_vocabulary )) || echo "  • $SUPPORT (your vocabulary and dictation history)"
if (( ! assume_yes )); then
  read -q "reply?Continue? [y/N] " || { echo; echo "Nothing removed."; exit 1; }
  echo
fi

if pgrep -xq Murmur; then
  echo "→ quitting Murmur"
  osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
  for _ in {1..20}; do pgrep -xq Murmur || break; sleep 0.1; done
  pkill -x Murmur 2>/dev/null || true
fi

if [[ -x "$APP/Contents/MacOS/Murmur" ]]; then
  echo "→ removing login item"
  "$APP/Contents/MacOS/Murmur" --unregister-login-item 2>/dev/null || true
fi

echo "→ removing app"
rm -rf "$APP"

if (( ! keep_vocabulary )); then
  echo "→ removing $SUPPORT"
  rm -rf "$SUPPORT"
fi

echo "→ removing settings and permissions"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "✓ Murmur removed."
echo
echo "The on-device speech model is shared with macOS dictation and stays installed."
echo "To also delete the \"Murmur Dev\" signing identity:"
echo "  security delete-identity -c \"Murmur Dev\" ~/Library/Keychains/login.keychain-db"

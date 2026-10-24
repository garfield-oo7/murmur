#!/bin/zsh
# Builds Murmur, installs it to ~/Applications/Murmur.app and launches it.
#
#   scripts/build.sh            # Debug build, install, launch
#   CONFIG=Release scripts/build.sh
#   scripts/build.sh --no-open  # don't launch
#
# The app is installed at a fixed path and signed with the "Murmur Dev" identity
# (see scripts/make-dev-cert.sh) so macOS keeps its permissions across rebuilds.
# Without that identity it falls back to ad-hoc signing, and Accessibility has to be
# re-granted after every build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
IDENTITY="${MURMUR_SIGN_IDENTITY:-Murmur Dev}"
DEST="$HOME/Applications/Murmur.app"
open_app=1
[[ "${1:-}" == "--no-open" ]] && open_app=0

echo "→ building ($CONFIG)"
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -quiet build 2> >(grep -v -e CoreSimulator -e 'Simulator device support' >&2)
built="build/DerivedData/Build/Products/$CONFIG/Murmur.app"

if pgrep -xq Murmur; then
  echo "→ quitting running Murmur"
  osascript -e 'quit app id "io.github.garfield-oo7.Murmur"' 2>/dev/null || pkill -x Murmur || true
  for _ in {1..20}; do pgrep -xq Murmur || break; sleep 0.1; done
fi

echo "→ installing to $DEST"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto "$built" "$DEST"

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "→ signing with \"$IDENTITY\""
  sign_as="$IDENTITY"
else
  echo "⚠︎ no \"$IDENTITY\" identity (run scripts/make-dev-cert.sh); signing ad-hoc."
  echo "  Accessibility will need re-granting after each build."
  sign_as="-"
fi
codesign --force --options runtime --timestamp=none \
  --entitlements Config/Murmur.entitlements --sign "$sign_as" "$DEST"
codesign --verify --strict "$DEST"

if (( open_app )); then
  echo "→ launching"
  open "$DEST"
fi

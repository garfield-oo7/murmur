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
BUNDLE_ID="io.github.garfield-oo7.Murmur"
DEST="$HOME/Applications/Murmur.app"
open_app=1
[[ "${1:-}" == "--no-open" ]] && open_app=0

# The app's designated code requirement: what TCC stores with a permission grant and
# re-checks against the running binary on every access. Ad-hoc: `cdhash H"…"` (changes
# every build); "Murmur Dev": `identifier … and certificate leaf = H"…"` (stable).
designated_requirement() {
  codesign -d -r- "$1" 2>/dev/null | grep -o 'designated => .*' || true
}

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
old_requirement=""
[[ -d "$DEST" ]] && old_requirement=$(designated_requirement "$DEST")
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

# TCC keeps the requirement the app had when Accessibility was granted and denies
# access when the running binary no longer satisfies it, while System Settings still
# shows the toggle on (and toggling it off/on doesn't refresh the stored requirement).
# When the requirement changes, drop the dead record so the app can register afresh.
new_requirement=$(designated_requirement "$DEST")
if [[ -n "$old_requirement" && "$old_requirement" != "$new_requirement" ]]; then
  echo "→ code requirement changed; resetting Murmur's Accessibility record"
  echo "  was: ${old_requirement#designated => }"
  echo "  now: ${new_requirement#designated => }"
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null
  # Let the app show the system Accessibility prompt again; that re-adds Murmur to
  # the list with the new requirement.
  defaults delete "$BUNDLE_ID" askedForAccessibility 2>/dev/null || true
  echo "  Re-grant: click “Open Settings” in Murmur, then turn Murmur on in Settings."
fi

if (( open_app )); then
  echo "→ launching"
  open "$DEST"
fi

#!/bin/zsh
# Builds Murmur, installs it to ~/Applications/Murmur.app and launches it.
#
#   scripts/install.sh              # release build, install, launch
#   scripts/install.sh --debug      # debug build
#   scripts/install.sh --no-open    # don't launch afterwards
#
# The app is installed at a fixed path and signed with the "Murmur Dev" identity
# (see scripts/make-dev-cert.sh) so macOS keeps its permissions across rebuilds.
# Without that identity it falls back to ad-hoc signing, and Accessibility has to be
# re-granted after every build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
IDENTITY="${MURMUR_SIGN_IDENTITY:-Murmur Dev}"
BUNDLE_ID="io.github.garfield-oo7.Murmur"
DEST="$HOME/Applications/Murmur.app"
open_app=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --no-open) open_app=0 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The app's designated code requirement: what TCC stores with a permission grant and
# re-checks against the running binary on every access. Ad-hoc: `cdhash H"…"` (changes
# every build); "Murmur Dev": `identifier … and certificate leaf = H"…"` (stable).
designated_requirement() {
  codesign -d -r- "$1" 2>/dev/null | grep -o 'designated => .*' || true
}

echo "→ building ($CONFIG)"
swift build -c "$CONFIG" --product Murmur
bin_dir=$(swift build -c "$CONFIG" --show-bin-path)

echo "→ assembling Murmur.app"
app="build/Murmur.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Murmur" "$app/Contents/MacOS/Murmur"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Vocabulary.txt "$app/Contents/Resources/"
plutil -lint -s "$app/Contents/Info.plist"

if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  if [[ "$IDENTITY" == "Murmur Dev" && -t 0 ]]; then
    read -q "reply?No \"$IDENTITY\" signing identity. Create one now (keeps permissions across rebuilds)? [y/N] " || true
    echo
    [[ "${reply:-n}" == y ]] && scripts/make-dev-cert.sh
  fi
fi
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "→ signing with \"$IDENTITY\""
  sign_as="$IDENTITY"
else
  echo "⚠︎ no \"$IDENTITY\" identity (run scripts/make-dev-cert.sh); signing ad-hoc."
  echo "  Accessibility will need re-granting after each build."
  sign_as="-"
fi
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/Murmur.entitlements --sign "$sign_as" "$app"
codesign --verify --strict "$app"

if pgrep -xq Murmur; then
  echo "→ quitting running Murmur"
  osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || pkill -x Murmur || true
  for _ in {1..20}; do pgrep -xq Murmur || break; sleep 0.1; done
  pkill -x Murmur 2>/dev/null || true
fi

echo "→ installing to $DEST"
mkdir -p "$(dirname "$DEST")"
old_requirement=""
[[ -d "$DEST" ]] && old_requirement=$(designated_requirement "$DEST")
rm -rf "$DEST"
ditto "$app" "$DEST"

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
echo "✓ Murmur installed. Hold ⌥D to dictate."

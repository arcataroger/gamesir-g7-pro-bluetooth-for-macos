#!/bin/zsh
# Adds the GameSir G7 Pro (Bluetooth mode) to macOS's third-party game controller database.
# See README.md. Requires SIP to be disabled while this runs.
set -e
HERE=${0:A:h}
source "$HERE/lib.sh"

[ "$(uname)" = Darwin ] || die "macOS only."
require_sip_off

VERSION=${1:-}
if [ -z "$VERSION" ]; then
  VERSION=$(pad_version)
  if [ -n "$VERSION" ]; then
    info "Connected G7 Pro reports firmware VersionNumber $VERSION"
  else
    VERSION=$DEFAULT_VERSION
    echo "warning: no G7 Pro connected over Bluetooth; assuming VersionNumber $VERSION (firmware 1.1.11)." >&2
    echo "         If your pad has different firmware the entry will not match. Connect it and re-run, or pass the number: ./install.sh <VersionNumber>" >&2
  fi
fi

BUNDLES=("${(@f)$(find_bundles)}")
[ -n "${BUNDLES[1]}" ] || die "Apple's GameControllers-Custom.bundle was not found under /System/Library/AssetsV2. This macOS version may store it elsewhere."

STAMP=$(date +%Y%m%d-%H%M%S)
for B in "${BUNDLES[@]}"; do
  info "Patching $B"
  PLIST="$B/Info.plist"
  mkdir -p "$HERE/backup/$STAMP"
  cp "$PLIST" "$HERE/backup/$STAMP/Info.plist"

  TMP=$(mktemp -t g7pro).plist
  cp "$PLIST" "$TMP"
  IDX=$(entry_index "$TMP")
  if [ -n "$IDX" ]; then
    info "Replacing existing entry (index $IDX)"
    plutil -remove "Devices.$IDX" "$TMP"
  fi
  plutil -insert Devices -json "{
      \"Identifier\": \"$IDENTIFIER\",
      \"CompatibilityVersion\": \"10.1.36\",
      \"IOPropertyMatch\": { \"VendorID\": $VENDOR_ID, \"ProductID\": $PRODUCT_ID, \"VersionNumber\": $VERSION },
      \"Personalities\": [ \"$PERSONALITY_REL\" ]
    }" -append "$TMP"
  plutil -lint "$TMP" >/dev/null

  sudo install -m 644 -o root -g wheel "$TMP" "$PLIST"
  sudo install -d -m 755 -o root -g wheel "$B/${PERSONALITY_REL:h}"
  sudo install -m 644 -o root -g wheel "$HERE/personality/GameSir-G7Pro-Bluetooth.plist" "$B/$PERSONALITY_REL"
  rm -f "$TMP"
done

restart_daemon
sleep 3
"$HERE/check.sh" || true
cat <<MSG

Done. If the check above reports the pad, verify buttons in System Settings > General > Game Controllers,
then re-enable SIP: reboot to Recovery, Utilities > Terminal, 'csrutil enable', reboot. The change persists.
Backups of the original Info.plist are in backup/$STAMP/.
MSG

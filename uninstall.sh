#!/bin/zsh
# Removes the G7 Pro entry and personality added by install.sh. Requires SIP disabled.
set -e
HERE=${0:A:h}
source "$HERE/lib.sh"
require_sip_off

for B in $(find_bundles); do
  PLIST="$B/Info.plist"
  TMP=$(mktemp -t g7pro).plist
  cp "$PLIST" "$TMP"
  IDX=$(entry_index "$TMP")
  if [ -n "$IDX" ]; then
    info "Removing entry from $B"
    plutil -remove "Devices.$IDX" "$TMP"
    plutil -lint "$TMP" >/dev/null
    sudo install -m 644 -o root -g wheel "$TMP" "$PLIST"
  else
    info "No entry in $B"
  fi
  rm -f "$TMP"
  sudo rm -rf "$B/${PERSONALITY_REL:h}"
done
restart_daemon
info "Removed."

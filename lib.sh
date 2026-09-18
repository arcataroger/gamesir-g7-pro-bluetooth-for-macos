# Shared helpers for install.sh / uninstall.sh / check.sh. Sourced, not executed.

IDENTIFIER="com.GameSir.G7Pro.Bluetooth"
VENDOR_ID=13623      # 0x3537 GameSir
PRODUCT_ID=4130      # 0x1022 G7 Pro, Bluetooth mode
DEFAULT_VERSION=283  # firmware 1.1.11 (0x11B); install.sh reads the real value from the connected pad
PERSONALITY_REL="Personalities/GameSir/G7Pro/Bluetooth.plist"
DAEMON="system/com.apple.GameController.gamecontrollerd"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_sip_off() {
  if csrutil status 2>/dev/null | grep -q 'enabled'; then
    die "System Integrity Protection is enabled. The controller database lives in a SIP-protected path.
Reboot to Recovery (hold the power button on Apple Silicon), open Utilities > Terminal, run 'csrutil disable', reboot, and try again.
Re-enable it with 'csrutil enable' afterwards; the installed files stay in place."
  fi
}

# All copies of Apple's third-party controller database on this Mac.
# Normally one (preinstalled). A newer one appears if Apple pushes an update; patch every copy.
find_bundles() {
  find /System/Library/AssetsV2 -maxdepth 7 -type d -name 'GameControllers-Custom.bundle' 2>/dev/null
}

# Firmware "VersionNumber" of the connected pad, from the IOKit registry. Empty if not connected.
pad_version() {
  # Registry entries start with a "+-o" line; properties follow. Match VID/PID, print VersionNumber.
  ioreg -r -c IOHIDDevice -l 2>/dev/null \
    | awk -v vid="$VENDOR_ID" -v pid="$PRODUCT_ID" '
        /\+-o /               { if (!done && v==vid && p==pid && ver!="") { print ver; done=1 } ; v=""; p=""; ver="" }
        /"VendorID" = /       { v=$NF }
        /"ProductID" = /      { p=$NF }
        /"VersionNumber" = /  { ver=$NF }
        END                   { if (!done && v==vid && p==pid && ver!="") print ver }'
}

# Index of our entry in a bundle's Devices array, or empty.
entry_index() {
  local plist="$1" i=0 id
  while id=$(plutil -extract "Devices.$i.Identifier" raw -o - "$plist" 2>/dev/null); do
    [ "$id" = "$IDENTIFIER" ] && { echo "$i"; return; }
    i=$((i+1))
  done
}

restart_daemon() {
  info "Restarting gamecontrollerd so it re-evaluates connected controllers"
  sudo launchctl kickstart -k "$DAEMON"
}

#!/bin/zsh
# Reports whether macOS's GameController framework currently sees the pad. No sudo, no SIP change needed.
HERE=${0:A:h}
source "$HERE/lib.sh"

if command -v swiftc >/dev/null 2>&1; then
  BIN="$HERE/tools/gclist"
  if [ ! -x "$BIN" ] || [ "$HERE/tools/gclist.swift" -nt "$BIN" ]; then
    info "Compiling tools/gclist.swift"
    swiftc -O "$HERE/tools/gclist.swift" -o "$BIN" 2>&1 | grep -v warning || true
  fi
  "$BIN"
else
  info "swiftc not found (install Xcode Command Line Tools for the live check); reading the daemon's log instead"
  /usr/bin/log show --last 2m --predicate 'process == "gamecontrollerd"' --style compact 2>/dev/null \
    | grep -E 'is (NOT )?a supported game controller' | tail -3 || echo "no verdict logged in the last 2 minutes"
fi

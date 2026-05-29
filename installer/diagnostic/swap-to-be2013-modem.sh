#!/usr/bin/env bash
# One-shot: swap from BE82CB modem -> BE2013 (Global) modem.
# Fully reversible: BE82CB image stays on disk; run swap-to-be82cb-modem.sh
# to revert in ~1 min.
#
# Goal: determine empirically whether BE2013 modem now works with our
# patched ofono (it returned iccIOForApp INTERNAL_ERR before any ofono
# patches were in place — maybe that was downstream of the PIN-auth
# blocker, maybe it's a real modem-firmware issue).

set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib/common.sh"

BE2013_MODEM="$CROSSFLASH_DIR/firmware/extracted/bengal_14_O.06_201113/extract/NON-HLOS.bin"
[[ -f "$BE2013_MODEM" ]] || die "BE2013 modem not found at $BE2013_MODEM"
say "BE2013 modem: $BE2013_MODEM ($(stat -f%z "$BE2013_MODEM") bytes)"

# 1. Reboot to bootloader
say "waiting for adb"
wait_for adb 300
say "rebooting to bootloader"
adb reboot bootloader
wait_for fastboot 60

UNLOCKED="$(fastboot getvar unlocked 2>&1 | grep -oE 'unlocked: [a-z]+' | cut -d' ' -f2)"
[[ "$UNLOCKED" == "yes" ]] || die "bootloader locked"

# 2. Flash to both slots
for slot in a b; do
  say "flashing modem_$slot (BE2013)"
  fastboot flash "modem_$slot" "$BE2013_MODEM" 2>&1 | tail -2
done

# 3. Re-flash patched vbmeta
VBM="$STATE_DIR/vbmeta-patched.img"
if [[ -f "$VBM" ]]; then
  for part in vbmeta vbmeta_a vbmeta_b; do
    fastboot flash "$part" "$VBM" 2>&1 | tail -1
  done
else
  say "no patched vbmeta cached — assuming current vbmeta has verification off"
fi

say "rebooting"
fastboot reboot
ok "BE2013 modem flashed. Wait ~60s for UT, then diagnose."

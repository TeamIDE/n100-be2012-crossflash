#!/usr/bin/env bash
# Rollback: BE2013 modem -> BE82CB modem (the known-good combo).

set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib/common.sh"

BE82CB_MODEM="$CROSSFLASH_DIR/firmware/be82cb_extracted/bengal_14_O.04_201221/extract/NON-HLOS.bin"
[[ -f "$BE82CB_MODEM" ]] || die "BE82CB modem not found at $BE82CB_MODEM"

say "waiting for adb"
wait_for adb 300
adb reboot bootloader
wait_for fastboot 60

for slot in a b; do
  say "flashing modem_$slot (BE82CB)"
  fastboot flash "modem_$slot" "$BE82CB_MODEM" 2>&1 | tail -2
done

VBM="$STATE_DIR/vbmeta-patched.img"
if [[ -f "$VBM" ]]; then
  for part in vbmeta vbmeta_a vbmeta_b; do
    fastboot flash "$part" "$VBM" 2>&1 | tail -1
  done
fi

fastboot reboot
ok "BE82CB modem restored."

#!/usr/bin/env bash
# Step 2b: replace the BE2013 (Global) modem firmware with the BE82CB
# (T-Mobile US) modem.
#
# Why: after the cross-flash in step 1, the Global BE2013 NON-HLOS.bin
# from 2020 is on the device. Against modern Halium-9 + ofono, this modem
# returns INTERNAL_ERR to every iccIOForApp request — SimManager can read
# nothing past the ICCID, Features stays at ['sim'] even after the ofono
# patches from step 5.
#
# The BE82CB modem (bengal_14_O.04_201221, the T-Mobile US OnePlus N100
# firmware from Dec 2021) is binary-compatible with the BE2013-cross-
# flashed device — it's the SAME chipset (Qualcomm SM4350 / Snapdragon
# 480), same RFFE config — and it responds to iccIOForApp correctly.
#
# We did the cross-flash *away from* BE82CB-stock specifically to escape
# the carrier-locked bootloader. Now that we're unlocked, we put the
# modem firmware BACK to BE82CB while keeping the Global OOS android side.
#
# Prereqs:
#   - 02-unlock-bootloader.sh complete (bootloader unlocked)
#   - The post-unlock OOS first-boot is done
#   - USB debugging is on, adb sees the phone
#   - You have the BE82CB.zip downloaded somewhere on disk
#
# Run BEFORE 03-bootstrap-recovery.sh — the modem swap is much easier
# with the device on stock OOS than after the recovery/partition reshape.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
state_done unlock || die "run ./02-unlock-bootloader.sh first"

BE82CB_ZIP="${BE82CB_ZIP:-$DL_DIR/BE82CB.zip}"
EXTRACT_DIR="$STATE_DIR/be82cb_extracted"
NON_HLOS="$EXTRACT_DIR/NON-HLOS.bin"

if [[ ! -f "$BE82CB_ZIP" ]]; then
  die "BE82CB.zip not found at $BE82CB_ZIP — set BE82CB_ZIP=<path> and re-run.
       This is the OnePlus N100 T-Mobile US firmware (~2.5 GB). It is not
       redistributable; obtain it from a OnePlus N100 BE82CB device or
       firmware archive (search: bengal_14_O.04_201221)."
fi

# --- 1. Extract NON-HLOS.bin from the BE82CB firmware -----------------------
if [[ ! -f "$NON_HLOS" ]]; then
  say "extracting NON-HLOS.bin from BE82CB.zip (this is the modem firmware)"
  mkdir -p "$EXTRACT_DIR"
  # The BE82CB.zip contains a nested .ops which contains the actual partitions.
  # We use the same opscrypto tooling as 00-prep.sh / 01-cross-flash.sh.
  python3 "$CROSSFLASH_DIR/tools/oppo_decrypt/opscrypto.py" decrypt \
    "$BE82CB_ZIP" --output "$EXTRACT_DIR" 2>&1 | tail -5
  [[ -f "$NON_HLOS" ]] || die "extraction failed — NON-HLOS.bin not present in $EXTRACT_DIR"
fi
ok "BE82CB modem firmware: $NON_HLOS ($(stat -f%z "$NON_HLOS") bytes)"

# --- 2. Reboot to bootloader-fastboot ---------------------------------------
say "waiting for adb"
wait_for adb 600
say "rebooting to bootloader"
adb reboot bootloader
wait_for fastboot 60

UNLOCKED="$(fastboot getvar unlocked 2>&1 | grep -oE 'unlocked: [a-z]+' | cut -d' ' -f2)"
[[ "$UNLOCKED" == "yes" ]] || die "bootloader locked — finish step 2 first"

# --- 3. Determine active slot, flash BE82CB modem to both slots -------------
CURRENT_SLOT="$(fastboot getvar current-slot 2>&1 | grep -oE 'current-slot: [a-z]+' | cut -d' ' -f2)"
say "current slot: $CURRENT_SLOT — flashing BE82CB modem to both slots"

# Flash to both slots so subsequent slot switches still get the BE82CB modem.
for slot in a b; do
  say "flashing modem_$slot"
  fastboot flash "modem_$slot" "$NON_HLOS" 2>&1 | tail -3
done
ok "BE82CB modem flashed to modem_a + modem_b"

# --- 4. Re-flash vbmeta with verification disabled --------------------------
# Without this, the device refuses to boot because the new modem doesn't
# match the original vbmeta digest. (This is the same vbmeta-patching step
# 03-bootstrap-recovery.sh does — we do it here too so that a user who runs
# step 2b standalone gets a bootable device.)
if [[ -f "$DL_DIR/bootstrap/vbmeta.img" ]]; then
  say "patching vbmeta to disable verification (modem firmware now mismatches stock digest)"
  VBM="$STATE_DIR/vbmeta-patched.img"
  cp "$DL_DIR/bootstrap/vbmeta.img" "$VBM"
  python3 - <<PY
import struct
data = bytearray(open("$VBM", "rb").read())
flags = struct.unpack(">I", data[120:124])[0]
struct.pack_into(">I", data, 120, flags | 0x3)
open("$VBM", "wb").write(data)
PY
  for part in vbmeta vbmeta_a vbmeta_b; do
    fastboot flash "$part" "$VBM" 2>&1 | tail -1
  done
  ok "vbmeta verification disabled"
else
  say "skipping vbmeta patch (no bootstrap/vbmeta.img yet — step 3 will handle it)"
fi

# --- 5. Reboot ---------------------------------------------------------------
say "rebooting"
fastboot reboot
ok "BE82CB modem in place. Next: ./03-bootstrap-recovery.sh"
state_mark modem_swap

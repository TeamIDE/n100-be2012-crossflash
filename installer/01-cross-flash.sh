#!/usr/bin/env bash
# Step 1: cross-flash the BE2012 T-Mobile firmware to BE2013 Global via EDL.
#
# This is the *destructive* step that converts the device's identity from
# OnePlusN100TMO → OnePlusN100. Everything below uses flash_xml.py from the
# parent crossflash directory.
#
# Prereqs:
#   - 00-prep.sh has run (firmware downloaded)
#   - phone is in EDL (Qualcomm 9008) mode at the moment 01a/01b are called
#
# Sub-steps:
#   01a backup device-unique partitions  (~30s)
#   01b dry-run the flash plan           (~1 min)
#   01c real flash                       (~10 min — destroys the device's
#       T-Mobile system and all userdata, but is fully recoverable from
#       backup or by re-running the patched MSM on Windows)

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
state_done prep || die "run ./00-prep.sh first"

FW_ZIP="$CROSSFLASH_DIR/firmware/OnePlus_Nord_N100_Global_OxygenOS_10.5.3.zip"
EXTRACT_DIR="$CROSSFLASH_DIR/firmware/extracted/bengal_14_O.06_201113/extract"

# Decrypt the .ops if not done yet.
if [[ ! -d "$EXTRACT_DIR" ]]; then
  say "extracting + decrypting the OnePlus .ops (~2 minutes, one-time)"
  cd "$CROSSFLASH_DIR"
  source venv/bin/activate
  ./flash.py prep "$FW_ZIP"
fi
ok "BE2013 firmware extracted: $EXTRACT_DIR"

# --- Sanity check: device must be in EDL ------------------------------------
say "waiting for device in EDL (Qualcomm 9008)"
echo "    To enter EDL from a working phone with USB debugging on:"
echo "        adb reboot edl"
echo "    Or hold Vol-Up + Vol-Down while plugging in USB on a powered-off phone."
wait_for edl 300

# --- Backup -----------------------------------------------------------------
if ! state_done backup; then
  say "backing up device-unique partitions (persist, modemst, carrier, etc.)"
  cd "$CROSSFLASH_DIR"
  source venv/bin/activate
  ./flash_xml.py backup
  state_mark backup
fi
ok "backup saved to $CROSSFLASH_DIR/backup/be2012_pre_crossflash/"

# Phone resets out of EDL after the backup. Wait for it to come back, then
# re-enter EDL for the actual flash.
sleep 4
say "phone is rebooting after backup. When it's back at the Android home screen:"
echo "    adb reboot edl"
echo "    (the next step waits for EDL again)"
wait_for edl 600

# --- Dry-run flash plan -----------------------------------------------------
if ! state_done dryrun; then
  say "dry-run the flash plan (no writes — validates the partition map)"
  cd "$CROSSFLASH_DIR"
  source venv/bin/activate
  ./flash_xml.py flash "$EXTRACT_DIR" --only-lun 0,1,4 --dry-run --yes
  state_mark dryrun
fi
ok "dry-run clean"

# --- Real flash -------------------------------------------------------------
echo
echo "About to overwrite the bootchain (xbl/abl/boot/modem/etc.) and system."
echo "This is the irreversible-without-MSM-on-Windows step. Backups are saved."
read -rp "Type YES to commit: " ans
[[ "$ans" == "YES" ]] || die "aborted by user"

cd "$CROSSFLASH_DIR"
source venv/bin/activate
./flash_xml.py flash "$EXTRACT_DIR" --only-lun 0,1,4 --yes

ok "cross-flash complete"
state_mark crossflash
echo
echo "Next steps:"
echo "  1. Phone reboots into Global OOS first-boot (~5-10 min)"
echo "  2. Walk through the wizard, sign into a Google account"
echo "  3. Run ./02-unlock-bootloader.sh"

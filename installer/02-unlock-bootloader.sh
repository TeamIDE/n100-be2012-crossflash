#!/usr/bin/env bash
# Step 2: unlock the bootloader.
#
# After the cross-flash the device runs Global OOS but `fastboot flashing
# unlock` still returns "Flashing Unlock is not allowed" because of
# Android-side carrier-shim apps holding `sys.oem_unlock_allowed=0`.
#
# Removing five specific packages via `pm uninstall --user 0` flips the
# property to 1, which lets the bootloader accept the unlock command.
#
# Prereqs:
#   - 01-cross-flash.sh completed
#   - The user has walked through OOS first-boot, signed into a Google
#     account, enabled Developer options + USB debugging
#   - Phone is plugged in, adb sees the device, RSA fingerprint accepted

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
state_done crossflash || die "run ./01-cross-flash.sh first"

say "waiting for phone in adb (USB debugging on, RSA fingerprint accepted)"
wait_for adb 600

# --- Sanity check that we're on Global OOS, not still on T-Mobile -----------
PRODUCT_NAME="$(adb shell getprop ro.product.name | tr -d '\r')"
if [[ "$PRODUCT_NAME" != "OnePlusN100" ]]; then
  die "ro.product.name is $PRODUCT_NAME — expected OnePlusN100.
       Cross-flash did not stick. Re-run 01-cross-flash.sh."
fi
ok "device identifies as $PRODUCT_NAME (Global)"

# --- Carrier-shim app removal -----------------------------------------------
CARRIER_PACKAGES=(
  cn.oneplus.oemtcma
  com.example.tmo
  com.qualcomm.qti.remoteSimlockAuth
  com.qualcomm.qti.uim
  com.oneplus.carrierlocation
)
say "removing carrier-shim apps that gate sys.oem_unlock_allowed"
for pkg in "${CARRIER_PACKAGES[@]}"; do
  printf '    pm uninstall --user 0 %s ... ' "$pkg"
  adb shell pm uninstall --user 0 "$pkg" 2>/dev/null | tr -d '\r' || true
done

# --- Verify the gate flipped -----------------------------------------------
ALLOWED="$(adb shell getprop sys.oem_unlock_allowed | tr -d '\r')"
if [[ "$ALLOWED" != "1" ]]; then
  die "sys.oem_unlock_allowed is still $ALLOWED (want 1).
       The carrier-shim trick may have changed on a newer OOS build.
       Manual fallback: enable OEM Unlocking toggle from Developer options."
fi
ok "sys.oem_unlock_allowed = 1"

echo
echo "On the phone:"
echo "  Settings → System → Developer options → OEM unlocking"
echo "  the toggle should now be live. Flip it ON."
echo
read -rp "Press ENTER when the OEM unlocking toggle is ON: " _

# --- Fastboot unlock --------------------------------------------------------
say "rebooting to bootloader"
adb reboot bootloader
wait_for fastboot 60

say "fastboot flashing unlock"
fastboot flashing unlock || die "unlock rejected — toggle may not be on"

ok "unlock command accepted — confirm on the phone (Vol-Down to select, Power to confirm)"
echo
echo "After confirming, the phone factory-wipes and reboots. Wait through OOS"
echo "first-boot again (~5 min), then re-enable USB Debugging (settings are"
echo "wiped). When adb sees the phone again, run ./03-bootstrap-recovery.sh."

state_mark unlock

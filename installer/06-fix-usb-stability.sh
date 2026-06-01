#!/usr/bin/env bash
# Step 6: stop adb from dropping every few seconds while the phone is
# plugged in via USB.
#
# Symptom: while charging from a USB host, the kernel logs a tight
# cycle in dmesg —
#   USB_STATE=CONNECTED → CONFIGURED → DISCONNECTED → CONNECTED → CONFIGURED
# every few seconds, always immediately after the PMI632 charger
# renegotiates its input current limit (e.g. 1.35A → 1.5A). adb on
# the host sees this as a connection drop.
#
# Cause: two subsystems are simultaneously managing the configfs USB
# gadget on Halium-based UT —
#   - host-side `usb-moded`
#   - Android container's `android.hardware.usb@1.1-service-qti`
# When the charger renegotiates and the Android HAL emits a USB-state
# change, usb-moded mistakes it for a disconnect, tears down the
# gadget, and renegotiates from scratch.
#
# Fix: pass `-i` (`--android_usb_broken_udev_events`) to usb-moded so
# it ignores spurious disconnect events after a mode is set. Dropped
# as a systemd EnvironmentFile override.
#
# Critical naming gotcha: the billie2 port already ships
# /etc/default/usb-moded.d/device-specific-config.conf which sets
# USB_MODED_ARGS=`` (empty) to disable rescue mode. systemd's
# EnvironmentFile loader processes files alphabetically; later files
# override earlier ones for the same variable. Our override must sort
# AFTER `device-specific-config.conf`, so the filename starts with
# `zzz-`, NOT `99-` (digit `9` (0x39) sorts before letter `d` (0x64)).
#
# Prereqs:
#   - UT is installed and booted (steps 00-05 complete or device is
#     simply a working UT install on billie2 — this fix is independent
#     of cellular/recovery/modem work)
#   - You've set a UT lock-screen PIN (sudo on UT uses it)
#
# Run once. Idempotent on re-run.

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

say "waiting for adb"
wait_for adb 300

PRODUCT="$(adb shell cat /etc/os-release 2>/dev/null | grep '^NAME=' | head -1 || true)"
[[ "$PRODUCT" == *Ubuntu* ]] || die "device doesn't look like UT (got: $PRODUCT)"

if [[ -n "${UT_PIN:-}" ]]; then
  PIN="$UT_PIN"
else
  read -rp "UT lock-screen PIN (used for sudo on device): " -s PIN
  echo
fi

CONF_NAME="zzz-android-broken-udev-events.conf"
TMP="$STATE_DIR/usb-stability"
mkdir -p "$TMP"

cat > "$TMP/$CONF_NAME" <<'CONF'
# Halium-aware override: the Android container also drives the USB
# gadget via android.hardware.usb HAL. Charger renegotiation events
# from the Android side look like disconnects to usb-moded, which
# then tears the gadget down and renegotiates — causing adb to drop
# every few seconds while the phone is charging from a USB host.
#
# -i (--android_usb_broken_udev_events) tells usb-moded to ignore
# these spurious disconnect events and keep the configured gadget up.
USB_MODED_ARGS=-i
CONF

say "pushing override + install helper"
adb push "$TMP/$CONF_NAME" "/tmp/$CONF_NAME" >/dev/null

# The install + restart needs to happen in a single sudo call (mount-rw +
# install + remount-ro + daemon-reload + restart). The restart drops adb
# because that's the very bug we're fixing — so we expect adb to die
# mid-command and we don't rely on its exit code. We verify after reconnect.
cat > "$TMP/install.sh" <<SH
#!/bin/sh
PIN="\$1"
[ -z "\$PIN" ] && { echo "usage: \$0 <pin>"; exit 1; }
echo "\$PIN" | sudo -S sh -c '
  set -e
  mount -o remount,rw /
  install -m 0644 -o root -g root /tmp/$CONF_NAME /etc/default/usb-moded.d/$CONF_NAME
  mount -o remount,ro /
  systemctl daemon-reload
  systemctl restart usb-moded &
  exit 0
'
SH
adb push "$TMP/install.sh" /tmp/install-usb-fix.sh >/dev/null
adb shell -T "chmod +x /tmp/install-usb-fix.sh && /tmp/install-usb-fix.sh $PIN" || true

say "waiting for adb to come back after usb-moded restart"
sleep 5
wait_for adb 60

say "verifying -i is live in usb_moded cmdline"
CMD="$(adb shell -T 'tr "\0" " " < /proc/$(pgrep usb_moded)/cmdline')"
echo "  usb_moded cmdline: $CMD"
case "$CMD" in
  *" -i "*|*" -i") ok "applied. adb should now hold steady across charger renegotiations." ;;
  *) die "-i not in cmdline — override file may not be sorting last. Check /etc/default/usb-moded.d/" ;;
esac
state_mark usb_stability

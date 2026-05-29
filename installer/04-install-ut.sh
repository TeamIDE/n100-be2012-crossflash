#!/usr/bin/env bash
# Step 4: install Ubuntu Touch.
#
# The recovery flashed in step 3 (rubencarneiro/billie2 1.0 from Oct 2023)
# ships with gpg 1.4.13 from 2012, which cannot verify the SHA512 signatures
# UBports has been using on system-image files since at least early 2025.
# Every install attempt with the stock recovery fails at the signature step.
#
# Workaround: use magiskboot on-device to repack the recovery image with
# patched `/sbin/system-image-upgrader` (verify_signature() => return 0) and
# stubbed `/system/bin/gpg`. Then push the UT system-image files and reboot
# to recovery — the auto-process script picks them up and applies the install
# with signature checks bypassed.
#
# This works end-to-end on macOS without ever leaving the host.
#
# Prereqs:
#   - 03-bootstrap-recovery.sh complete
#   - Phone is currently in bootloader-fastboot (last action of step 3)

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
state_done bootstrap || die "run ./03-bootstrap-recovery.sh first"

UT_DIR="$DL_DIR/ubports-systemimage"
BS_DIR="$DL_DIR/bootstrap"
MB_BIN="$DL_DIR/magiskboot/magiskboot.arm64"

# Re-derive the patched system-image-upgrader. We do this every run rather
# than caching, in case the script has been edited.
SIU_PATCHED="$STATE_DIR/system-image-upgrader.patched"
mkdir -p "$STATE_DIR"

say "waiting for fastboot (from step 3 end-state)"
wait_for fastboot 60

# Reboot to recovery to put the stock binaries in memory, then we'll yank
# system-image-upgrader, patch it, and reflash the recovery.
say "rebooting to recovery to extract on-device toolchain"
fastboot reboot recovery
wait_for recovery 60

# Wait for the recovery's adbd to come up as root (it transitions from auto-
# process root to menu-mode shell uid=2000 after the auto-install attempt
# fails; only the early root window can write to /sbin or /system/bin).
say "waiting for recovery adb (root)"
for _ in $(seq 1 60); do
  if adb shell id 2>/dev/null | grep -q "uid=0"; then break; fi
  sleep 2
done
adb shell id | grep -q "uid=0" || die "could not get root adb in recovery"

# --- Patch system-image-upgrader on the host --------------------------------
say "pulling stock system-image-upgrader from device"
adb pull /sbin/system-image-upgrader "$STATE_DIR/system-image-upgrader.orig" >/dev/null

python3 - <<PY
import re
s = open("$STATE_DIR/system-image-upgrader.orig").read()
patched = re.sub(
    r"verify_signature\(\) \{.*?\n\}\n",
    "verify_signature() { return 0; }\n",
    s, count=1, flags=re.DOTALL,
)
open("$SIU_PATCHED", "w").write(patched)
PY
ok "patched verify_signature() => return 0"

# Stub gpg — verify_signature already returns 0, but the install-keyring
# code path also calls gpg directly. Stub it as a defense-in-depth.
echo '#!/system/bin/sh
exit 0' > "$STATE_DIR/gpg-stub"

# --- Push magiskboot + the original recovery, patch on-device ---------------
say "pushing magiskboot + recovery + patches to device"
adb push "$MB_BIN" /tmp/magiskboot >/dev/null
adb shell chmod +x /tmp/magiskboot
adb push "$BS_DIR/recovery.img" /tmp/recovery_orig.img >/dev/null
adb push "$SIU_PATCHED" /tmp/siu-patched >/dev/null
adb push "$STATE_DIR/gpg-stub" /tmp/gpg-stub >/dev/null

say "repacking recovery image on-device with patches baked in"
adb shell '
  set -e
  cd /tmp
  ./magiskboot unpack recovery_orig.img >/dev/null
  ./magiskboot cpio ramdisk.cpio \
      "add 0755 sbin/system-image-upgrader /tmp/siu-patched" \
      "add 0755 system/bin/gpg /tmp/gpg-stub" >/dev/null
  ./magiskboot repack recovery_orig.img recovery_patched.img >/dev/null
  ls -la recovery_patched.img
'
ok "patched recovery built on device"

say "dd-flashing patched recovery to recovery_a (slot A is active)"
adb shell "dd if=/tmp/recovery_patched.img of=/dev/block/by-name/recovery_a bs=4096" 2>&1 | tail -2

# --- Push the UT system-image files + ubuntu_command into /cache/recovery ---
say "preparing /cache/recovery"
adb shell "mount -a 2>/dev/null; rm -rf /cache/recovery; mkdir -p /cache/recovery"

say "pushing Ubuntu Touch system-image artifacts (~500 MB total)"
cd "$UT_DIR"
for f in *.tar.xz *.tar.xz.asc; do
  printf '    push %-110s ' "$f"
  adb push "$f" /cache/recovery/ 2>&1 | tail -1 | awk '{print $1, $5, $6}'
done
adb push ubuntu_command /cache/recovery/ubuntu_command >/dev/null

# Verify the largest file landed at the right size — adb push has been
# observed to truncate the rootfs tarball on macOS; the install will fail
# with "xzcat: corrupted data" if so.
ROOTFS_LOCAL="$(stat -f%z rootfs-*.tar.xz)"
ROOTFS_REMOTE="$(adb shell wc -c /cache/recovery/rootfs-*.tar.xz | awk '{print $1}' | tr -d '\r')"
[[ "$ROOTFS_LOCAL" == "$ROOTFS_REMOTE" ]] || \
  die "rootfs push truncated: local=$ROOTFS_LOCAL remote=$ROOTFS_REMOTE — re-run step 4"
ok "rootfs verified ($ROOTFS_LOCAL bytes)"

# --- Reboot to recovery — auto-process runs the patched upgrader ------------
say "rebooting to recovery to apply the install"
adb reboot recovery

ok "install in progress — watch the phone screen"
echo
echo "What's happening now:"
echo "  1. Recovery boots, sees /cache/recovery/ubuntu_command"
echo "  2. Auto-runs /sbin/system-image-upgrader (our patched version)"
echo "  3. Formats system_a (3 GB), mounts it"
echo "  4. Extracts each .tar.xz update into the mounted system root"
echo "  5. Formats userdata"
echo "  6. Reboots into Ubuntu Touch first-run (~5 min for halium-9 init)"
echo
echo "Expected on-screen progression:"
echo "  • UBports recovery banner"
echo "  • 'System Image Upgrader for Ubuntu Touch'"
echo "  • 'Applying update: rootfs-…' (largest, takes ~30s)"
echo "  • 'Applying update: device-…'"
echo "  • 'Applying update: boot-…'"
echo "  • 'Applying update: keyring-…'"
echo "  • 'Applying update: version-…'"
echo "  • 'Done upgrading…'"
echo "  • Auto-reboot → UT setup wizard"
echo
echo "Once you reach the UT lock screen / welcome wizard:"
echo "  • Wi-Fi will be broken on the FIRST boot (Halium firmware-load"
echo "    timing). Long-press Power → Restart and Wi-Fi works after the"
echo "    second boot."
echo
echo "To pull the live log: adb pull /cache/ubuntu_updater.log"
state_mark install

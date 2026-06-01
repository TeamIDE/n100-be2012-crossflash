#!/usr/bin/env bash
# Step 3: bootstrap recovery + logical partition layout.
#
# Flashes the rubencarneiro UBports boot/recovery/dtbo/vbmeta images, sets
# slot to 'a', deletes unused logical partitions and resizes system_a to 3 GB
# to fit Ubuntu Touch's rootfs.
#
# Also flashes vbmeta with verification disabled (flags 0x3) — required
# because step 4 dd-flashes a magiskboot-repacked recovery whose hash will
# not match the stock vbmeta digest.
#
# Prereqs:
#   - 02-unlock-bootloader.sh complete (`fastboot flashing unlock` worked)
#   - The phone has finished the post-unlock factory wipe + OOS first-boot
#   - USB debugging is on again, adb sees the phone

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
state_done unlock || die "run ./02-unlock-bootloader.sh first"

say "waiting for adb"
wait_for adb 600

# Reboot path differs by source OS:
#   - From OOS (Android): `adb reboot bootloader` works as the unprivileged
#     shell user. Only used the first time through the installer.
#   - From UT (Ubuntu): adb runs as `phablet`, which doesn't own the
#     bootloader trigger file. Need sudo. The UT lock-screen PIN is the
#     sudo password (export UT_PIN to skip the prompt).
reboot_to_bootloader() {
  if adb reboot bootloader 2>&1 | grep -q "Permission denied"; then
    if [[ -z "${UT_PIN:-}" ]]; then
      read -rp "UT lock-screen PIN (sudo on the device): " -s UT_PIN
      echo
      export UT_PIN
    fi
    adb shell -T "echo '$UT_PIN' | sudo -S reboot bootloader" >/dev/null 2>&1 || true
  fi
}

# --- Reboot to bootloader-fastboot ------------------------------------------
say "rebooting to bootloader"
reboot_to_bootloader
wait_for fastboot 60

UNLOCKED="$(fastboot getvar unlocked 2>&1 | grep -oE 'unlocked: [a-z]+' | cut -d' ' -f2)"
[[ "$UNLOCKED" == "yes" ]] || die "bootloader is locked. Re-run 02-unlock-bootloader.sh."

say "setting active slot to a"
fastboot --set-active=a

# --- Flash bootstrap images -------------------------------------------------
BS_DIR="$DL_DIR/bootstrap"
for f in boot recovery dtbo; do
  say "flashing $f"
  fastboot flash "$f" "$BS_DIR/$f.img"
done

# Flash vbmeta with verification disabled (flags 0x3 — hashtree + verification).
say "patching vbmeta flags to disable verification (lets us boot the repacked recovery)"
VBM="$STATE_DIR/vbmeta-patched.img"
cp "$BS_DIR/vbmeta.img" "$VBM"
python3 - <<PY
import struct
data = bytearray(open("$VBM", "rb").read())
flags = struct.unpack(">I", data[120:124])[0]
struct.pack_into(">I", data, 120, flags | 0x3)
open("$VBM", "wb").write(data)
PY
for part in vbmeta vbmeta_a vbmeta_b; do
  say "flashing $part"
  fastboot flash "$part" "$VBM"
done
ok "bootstrap firmware flashed"

# --- Enter fastbootd and reshape the super partition ------------------------
say "rebooting to fastbootd (userspace fastboot, needed for logical partition ops)"
fastboot reboot fastboot
sleep 5
wait_for fastboot 60

IS_USERSPACE="$(fastboot getvar is-userspace 2>&1 | grep -oE 'is-userspace: [a-z]+' | cut -d' ' -f2)"
[[ "$IS_USERSPACE" == "yes" ]] || die "expected fastbootd; got bootloader fastboot"

say "deleting unused logical partitions"
for p in system_ext_a system_ext_b product_a product_b system_b vendor_b odm_b; do
  fastboot delete-logical-partition "$p" || true
done

say "recreating tiny product_a + odm_a (recovery fstab expects them)"
fastboot create-logical-partition product_a 4096 || true
fastboot create-logical-partition odm_a 4096 || true

say "resizing system_a to 3 GB (3221225472 bytes)"
fastboot resize-logical-partition system_a 3221225472

# --- Wipe userdata + reboot to bootloader -----------------------------------
say "back to bootloader-fastboot"
fastboot reboot bootloader
sleep 5
wait_for fastboot 60

say "wiping userdata"
fastboot erase userdata || true
fastboot format:ext4 userdata

ok "bootstrap done — next: ./04-install-ut.sh"
state_mark bootstrap

#!/usr/bin/env bash
# Step 7: keep Wi-Fi alive across reboots on the BE2012.
#
# Symptom: after a reboot, `nmcli device` shows wlan0 as `unavailable`
# and no networks are reachable. `dmesg` shows:
#   icnss ... loading wlan/qca_cld/wlan_mac.bin failed with error -22
#   wlan: ... hdd_initialize_mac_address: using default MAC address
#   wlan: ... MAC is Multicast (via hdd_open_adapter)
#   wlan: ... Failed to open interfaces: -28
# `/android/mnt/vendor/persist/wlan_mac.bin` is 0 bytes.
#
# Cause: an Android-side wifi HAL service at boot opens
# `/mnt/vendor/persist/wlan_mac.bin` for write and truncates it, then
# fails to write the regenerated MAC table. The next driver probe
# defaults to an all-zero (multicast) MAC, which the kernel refuses
# for station mode, and wlan0 never comes up.
#
# Fix: stash a known-good copy of wlan_mac.bin in
# /var/lib/wlan-mac-fix/, install a systemd oneshot that runs before
# NetworkManager and restores the file (then reloads
# qca_cld3_wlan.ko so the driver re-reads the MAC).
#
# Source for the known-good wlan_mac.bin: extracted from the device's
# own persist partition backup taken before the cross-flash —
# `backup/be2012_pre_crossflash/persist.img` in this repo. The file
# inside is 120 bytes of ASCII MAC entries; the MAC is hardware-tied
# to the unit.
#
# Prereqs:
#   - UT is installed and booted (steps 00–06 complete OR UT installed
#     via the upstream UBports installer)
#   - You've set a UT lock-screen PIN
#   - This repo's `backup/be2012_pre_crossflash/persist.img` is on the
#     host (created by `flash_xml.py backup` during step 01)

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

PERSIST_IMG="$REPO_DIR/backup/be2012_pre_crossflash/persist.img"
if [[ ! -f "$PERSIST_IMG" ]]; then
  die "missing $PERSIST_IMG — re-run step 01 backup first, or copy
       a previously-saved persist.img to that path."
fi

# debugfs is in e2fsprogs. macOS ships it via brew; Linux distros ship
# it in base. Find one.
DEBUGFS=""
for cand in /opt/homebrew/opt/e2fsprogs/sbin/debugfs \
            /usr/local/opt/e2fsprogs/sbin/debugfs \
            /sbin/debugfs /usr/sbin/debugfs; do
  if [[ -x "$cand" ]]; then DEBUGFS="$cand"; break; fi
done
if [[ -z "$DEBUGFS" ]] && command -v debugfs >/dev/null 2>&1; then
  DEBUGFS="$(command -v debugfs)"
fi
[[ -n "$DEBUGFS" ]] || die "debugfs not found.
    macOS: brew install e2fsprogs   (binary in /opt/homebrew/opt/e2fsprogs/sbin/)
    Linux: usually preinstalled; otherwise apt install e2fsprogs"

say "waiting for adb"
wait_for adb 300

PRODUCT="$(adb shell cat /etc/os-release 2>/dev/null | grep '^NAME=' | head -1 || true)"
[[ "$PRODUCT" == *Ubuntu* ]] || die "device doesn't look like UT (got: $PRODUCT)"

read -rp "UT lock-screen PIN (used for sudo on device): " -s PIN
echo

# --- 1. Extract the good wlan_mac.bin from the persist.img backup ----------
TMP="$STATE_DIR/wifi-mac-fix"
mkdir -p "$TMP"
say "extracting wlan_mac.bin from $PERSIST_IMG"
"$DEBUGFS" -R "dump /wlan_mac.bin $TMP/wlan_mac.bin" "$PERSIST_IMG" 2>&1 | tail -1
SIZE=$(stat -f%z "$TMP/wlan_mac.bin" 2>/dev/null || stat -c%s "$TMP/wlan_mac.bin")
[[ "$SIZE" -gt 0 ]] || die "extracted wlan_mac.bin is empty — backup may be incomplete"
ok "extracted $SIZE bytes; first line: $(head -c40 "$TMP/wlan_mac.bin")…"

# --- 2. Build the recovery script + systemd unit on the host --------------
cat > "$TMP/wlan-mac-fix" <<'SHELL'
#!/bin/sh
# wlan-mac-fix: restore the WCN3680 MAC table file and reload the wlan
# kernel module if a boot-time service zeroed it.
set -e
SRC=/var/lib/wlan-mac-fix/wlan_mac.bin
TARGET=/android/mnt/vendor/persist/wlan_mac.bin
KO=/android/system/vendor/lib/modules/qca_cld3_wlan.ko
LOG=/usr/bin/logger

note() { echo "wlan-mac-fix: $*"; "$LOG" -t wlan-mac-fix "$*" 2>/dev/null || true; }

[ -r "$SRC" ] || { note "source $SRC missing"; exit 0; }

# Wait briefly for the lxc-android persist mount to appear.
for i in $(seq 1 60); do
    [ -d "$(dirname "$TARGET")" ] && break
    sleep 1
done
[ -d "$(dirname "$TARGET")" ] || { note "persist mount never appeared"; exit 1; }

EXPECTED=$(stat -c%s "$SRC")
SIZE=$(stat -c%s "$TARGET" 2>/dev/null || echo 0)

if [ "$SIZE" = "$EXPECTED" ]; then
    note "wlan_mac.bin already $SIZE bytes — driver should be fine"
else
    note "restoring wlan_mac.bin ($SIZE -> $EXPECTED)"
    cp "$SRC" "$TARGET"
    chown 1010:1010 "$TARGET"
    chmod 0600 "$TARGET"

    if [ -f "$KO" ]; then
        note "reloading qca_cld3_wlan"
        rmmod wlan 2>/dev/null || true
        sleep 1
        insmod "$KO" 2>/dev/null || note "insmod returned non-zero (may already be loaded)"
        sleep 3
    fi

    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set wlan0 managed yes 2>/dev/null || true
    fi
fi

if ip link show wlan0 >/dev/null 2>&1; then
    ip link set wlan0 up 2>/dev/null || true
fi
note "done"
SHELL

cat > "$TMP/wlan-mac-fix.service" <<'UNIT'
[Unit]
Description=Restore wlan_mac.bin + reload wlan driver if zeroed at boot
DefaultDependencies=no
After=local-fs.target
Before=NetworkManager.service network-pre.target
Wants=network-pre.target
ConditionPathExists=/var/lib/wlan-mac-fix/wlan_mac.bin

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wlan-mac-fix
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# --- 3. Push to device, install via sudo, enable ---------------------------
say "pushing bundle to device"
adb push "$TMP/wlan_mac.bin"        /tmp/wlan_mac.bin        >/dev/null
adb push "$TMP/wlan-mac-fix"        /tmp/wlan-mac-fix        >/dev/null
adb push "$TMP/wlan-mac-fix.service" /tmp/wlan-mac-fix.service >/dev/null

cat > "$TMP/install.sh" <<'SH'
#!/bin/sh
set -e
PIN="$1"
[ -z "$PIN" ] && { echo "usage: $0 <pin>"; exit 1; }
echo "$PIN" | sudo -S sh -c '
  set -e
  mount -o remount,rw /
  install -d -m 0755                 /var/lib/wlan-mac-fix
  install -m 0644 -o root -g root    /tmp/wlan_mac.bin         /var/lib/wlan-mac-fix/wlan_mac.bin
  install -m 0755 -o root -g root    /tmp/wlan-mac-fix         /usr/local/sbin/wlan-mac-fix
  install -m 0644 -o root -g root    /tmp/wlan-mac-fix.service /etc/systemd/system/wlan-mac-fix.service
  mount -o remount,ro /
  systemctl daemon-reload
  systemctl enable wlan-mac-fix.service
  # Run it once now to recover the current boot if needed.
  systemctl start wlan-mac-fix.service || true
  echo "installed + enabled. Will run on every boot before NetworkManager."
'
SH
adb push "$TMP/install.sh" /tmp/install-wlan-mac-fix.sh >/dev/null
adb shell "chmod +x /tmp/install-wlan-mac-fix.sh && /tmp/install-wlan-mac-fix.sh $PIN"

ok "Wi-Fi MAC persistence in place. Reboot to confirm wlan0 stays up."
state_mark wifi_mac_persistence

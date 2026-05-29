#!/usr/bin/env bash
# Step 5: fix the ofono SIM-init blockers that keep Features stuck at ['sim'].
#
# On a fresh UT install on the BE2012 (post-cross-flash) with the BE82CB
# modem in place, ofonod 1.29+git12 logs three SIM-init complaints:
#
#   1. "Requested file structure differs from SIM: 6fb7"  ← cosmetic
#      EF_ECC double-read; ofono reads it once transparent + once
#      linear-fixed because the file type differs between SIM/USIM.
#      Always logs a "structure differs" on one of the two. Launchpad
#      bug #1229566: known noise, not a real bug.
#   2. "Facility lock query error: INVALID_ARGUMENTS"     ← cosmetic
#      ofono treats the error as locked=FALSE and continues.
#   3. "Querying PIN authentication state failed"        ← BLOCKS
#      sim_pin_query_cb early-returns on error before advancing
#      sim->state. SimManager never publishes IMSI/SubscriberNumbers,
#      NetworkRegistration never starts, Features stays at ['sim'].
#
# Fix: two binary patches against /usr/sbin/ofonod (1824688 bytes).
#
#   FUNCTIONAL (this is what unblocks Features):
#     0xe1e94    adrp x0,'Querying PIN...' -> mov w23,#0
#                60030090 -> 17008052
#     0xe1e98    add  x0,x0,#0x8b8 -> b #0xe1cc8   (jump to success path)
#                00e02291 -> 8cffff17
#
#     The PIN-auth error path is hijacked: instead of logging+returning,
#     set pin_type to OFONO_SIM_PASSWORD_NONE and jump into the success
#     continuation. SIM state machine advances, IMSI gets read, Features
#     rolls out to ['gprs','rat','ussd','net','cbs','stk','sms','sim'].
#
#   COSMETIC (optional — just silences a noisy warning):
#     0x10b8f4   b.ne -> nop                   (skip EF_ECC structure check)
#                81020054 -> 1f2003d5
#
# What this does NOT fix:
#   - SIM/carrier band compat with the BE82CB modem firmware. The modem
#     firmware is T-Mobile US tuned. Verizon-provisioned SIMs (e.g. some
#     Straight Talk SIMs with ICCID 891480 / MCC+MNC 311+480) will read
#     correctly through the patched stack and even appear in a Scan as
#     "current" briefly — but they won't sustain registration because the
#     modem doesn't camp on Verizon bands. T-Mobile-network SIMs (Mint,
#     T-Mobile direct, Straight Talk T-Mo flavor) attach normally.
#
# Re-running this script is safe — it always restores ofonod from the
# original backup stored on first run, then re-applies the patches.
#
# Prereqs:
#   - 04-install-ut.sh complete, UT booted, USB debugging on
#   - You've set a UT lock-screen PIN (sudo on UT uses it)

set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
state_done install || die "run ./04-install-ut.sh first"

say "waiting for adb (UT booted, USB debugging on)"
wait_for adb 300

# Sanity: we expect UT, not Android, and the same ofonod build
PRODUCT="$(adb shell cat /etc/os-release 2>/dev/null | grep '^NAME=' | head -1 || true)"
[[ "$PRODUCT" == *Ubuntu* ]] || die "device doesn't look like UT (got: $PRODUCT)"

read -rp "UT lock-screen PIN (used for sudo on device): " -s PIN
echo

TMP="$STATE_DIR/cellular-fix"
mkdir -p "$TMP"

# --- 1. Pull stock ofonod ---------------------------------------------------
say "pulling stock ofonod"
adb pull /usr/sbin/ofonod "$TMP/ofonod.orig" >/dev/null
SIZE="$(stat -f%z "$TMP/ofonod.orig")"
[[ "$SIZE" == "1824688" ]] || \
  die "ofonod size $SIZE != 1824688 — UT updated, offsets need re-derivation"

# --- 2. Apply patches on host ------------------------------------------------
say "patching ofonod (EHPLMN soft-fail + PIN-auth-error hijack)"
python3 - <<PY
data = bytearray(open("$TMP/ofonod.orig", "rb").read())

# Patch A: EHPLMN strict structure mismatch — b.ne -> nop
o = 0x10b8f4
assert bytes(data[o:o+4]) == bytes.fromhex("81020054"), \
    f"unexpected bytes at 0x{o:x}: {bytes(data[o:o+4]).hex()} — binary changed?"
data[o:o+4] = bytes.fromhex("1f2003d5")

# Patch B: PIN-auth-error hijack
# In the error branch of sim_pin_query_cb, instead of calling ofono_error()
# and returning, set w23 (pin_type) to 0 (NONE) and jump into the success
# continuation at 0xe1cc8.
o = 0xe1e94
assert bytes(data[o:o+4]) == bytes.fromhex("60030090"), \
    f"unexpected bytes at 0x{o:x}: {bytes(data[o:o+4]).hex()} — binary changed?"
data[o:o+4] = bytes.fromhex("17008052")   # mov w23, #0

o = 0xe1e98
assert bytes(data[o:o+4]) == bytes.fromhex("00e02291"), \
    f"unexpected bytes at 0x{o:x}: {bytes(data[o:o+4]).hex()} — binary changed?"
# b #0xe1cc8 from 0xe1e98 = delta -0x1d0 -> imm26 0x3FFFF8C
data[o:o+4] = bytes.fromhex("8cffff17")

open("$TMP/ofonod.patched", "wb").write(data)
print("ofonod patched OK")
PY

# --- 3. Install via on-device helper (PIN never leaves the device) ----------
say "pushing patched ofonod + install helper"
adb push "$TMP/ofonod.patched" /tmp/ofonod.patched >/dev/null

cat > "$TMP/install.sh" <<'SH'
#!/bin/sh
set -e
PIN="$1"
[ -z "$PIN" ] && { echo "usage: $0 <pin>"; exit 1; }
echo "$PIN" | sudo -S sh -c '
  set -e
  mount -o remount,rw /
  systemctl stop ofono
  if [ ! -f /usr/sbin/ofonod.preCellularFix ]; then
    cp /usr/sbin/ofonod /usr/sbin/ofonod.preCellularFix
  fi
  cp /tmp/ofonod.patched /usr/sbin/ofonod
  chmod 755 /usr/sbin/ofonod
  mount -o remount,ro /
  systemctl start ofono
' 2>&1 | tail -3
SH
adb push "$TMP/install.sh" /tmp/install-cellular-fix.sh >/dev/null
adb shell chmod +x /tmp/install-cellular-fix.sh
adb shell "/tmp/install-cellular-fix.sh $PIN"
sleep 8
ok "ofonod patched + ofono restarted"

# --- 4. Diagnose --------------------------------------------------------------
FEATS="$(adb shell gdbus call -y -d org.ofono -o /ril_0 -m org.ofono.Modem.GetProperties \
  2>&1 | grep -oE "'Features':\\s*<\\[[^]]*\\]>" || true)"
IMSI="$(adb shell gdbus call -y -d org.ofono -o /ril_0 -m org.nemomobile.ofono.SimInfo.GetSubscriberIdentity \
  2>&1 | tr -d "()',")"
echo
echo "Modem features: $FEATS"
echo "IMSI:           ${IMSI:-<empty>}"
echo

case "$FEATS" in
  *gprs*|*net*)
    ok "Software stack fixed — Features advanced past 'sim'."
    echo
    echo "Network registration now depends on SIM ↔ BE82CB-modem band compat:"
    echo "  • T-Mobile-network SIMs (Mint, T-Mo direct, etc.) should attach"
    echo "  • Verizon-provisioned SIMs read fine but won't sustain registration"
    echo "  • Settings → Cellular → APN if data doesn't auto-configure"
    ;;
  *)
    echo "Features still stuck. Check 'journalctl -u ofono' and re-verify"
    echo "the ofonod patch offsets match this build."
    ;;
esac

state_mark cellular_fix

# --- Rollback ---
echo
echo "To revert:"
echo "  echo \$PIN | adb shell sudo -S sh -c \\"
echo "    'mount -o remount,rw / && systemctl stop ofono &&\\"
echo "     cp /usr/sbin/ofonod.preCellularFix /usr/sbin/ofonod &&\\"
echo "     mount -o remount,ro / && systemctl start ofono'"

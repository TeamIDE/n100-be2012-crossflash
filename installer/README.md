# N100 BE2012 → Ubuntu Touch — reproducible installer

End-to-end installer, all driven from macOS. No Windows needed.
Captures every step we actually went through to land Ubuntu Touch on a
**carrier-locked OnePlus Nord N100 BE2012 (T-Mobile US)**.

## What this installer does

1. **Cross-flash** stock T-Mobile OxygenOS 10.5.8 (BE82CB) → Global
   OxygenOS 10.5.3 (BE2013) via Qualcomm Firehose / EDL.
2. **Bootloader unlock** via OnePlus carrier-shim app removal —
   `pm uninstall --user 0` on the five apps that gate
   `sys.oem_unlock_allowed`.
3. **Modem re-flash** — put the BE82CB (T-Mobile US) NON-HLOS.bin back
   over the BE2013 modem. The Global 2020 modem returns INTERNAL_ERR
   to every `iccIOForApp` call against modern Halium-9 + ofono; the
   BE82CB modem doesn't.
4. **UBports installer bootstrap** — flash boot/recovery/dtbo/vbmeta
   and resize logical partitions for UT's 3 GB system_a.
5. **Custom system-image upgrade** — patch the recovery's
   `system-image-upgrader` to skip GPG signature verification
   (necessary because the recovery's gpg 1.4.13 from 2012 can't verify
   modern SHA512 signatures), then drive the auto-install with our
   patched recovery.
6. **Cellular software-stack patch** — three-byte binary patch on
   `/usr/sbin/ofonod` so SIM-init advances past the PIN-auth-error
   early-return, taking modem `Features` from `['sim']` to the full
   set (`gprs`, `rat`, `net`, etc.).

## What you need before starting

| Requirement | Why |
| --- | --- |
| **OnePlus Nord N100, model BE2012** | This installer is specific to this SKU. BE2013/BE83BA users should use the stock UBports installer. |
| **macOS** (tested on Apple Silicon, macOS 26.2) **or Linux** (designed to work, untested end-to-end — scripts auto-detect OS) | Underlying Python tooling is cross-platform. |
| **Python 3.10+** + libusb (`brew install libusb` on macOS; `apt install libusb-1.0-0-dev` on Debian/Ubuntu; `dnf install libusbx` on Fedora) | For the EDL Firehose client. |
| **USB-C data cable** (not charge-only) | EDL + fastboot. |
| **~13 GB free disk** | BE2013 firmware + BE82CB firmware + UT system-image cache. |
| **Network** | Downloads BE2013 OOS ZIP + Ubuntu Touch system-image files. |
| **BE82CB.zip** (T-Mobile OnePlus N100 firmware, `bengal_14_O.04_201221`) | Needed by step 2b for the modem re-flash. The .zip itself is not redistributable — obtain it from a BE82CB device or a firmware archive. Place at `downloads/BE82CB.zip` or set `BE82CB_ZIP=<path>`. |

## Installation order

Each script is idempotent — safe to re-run.

```bash
# 1. One-time prerequisites: clones, brew installs, python deps, downloads.
./00-prep.sh

# 2. Cross-flash BE2012 → BE2013 (~10 minutes, requires EDL entry).
./01-cross-flash.sh

# 3. Unlock the bootloader (Android-side carrier-shim removal).
#    Requires the user to manually add a Google account in OOS first-boot.
./02-unlock-bootloader.sh

# 4. Re-flash BE82CB modem (~1 minute, fastboot only).
#    Without this, ofono will never advance past Features=['sim'] later.
./02b-fix-modem.sh

# 5. Bootstrap recovery + partition layout (~2 minutes).
./03-bootstrap-recovery.sh

# 6. Install Ubuntu Touch (~5 minutes).
./04-install-ut.sh

# 7. Fix the SIM-init blockers in ofono (~30 seconds).
#    Run after UT first-boot, after you've set a UT lock-screen PIN.
./05-fix-cellular.sh

# 8. Stop adb from dropping every few seconds while plugged in (~10 seconds).
#    Halium's Android USB HAL races with usb-moded on charger renegotiation
#    events. Pass -i to usb-moded so it ignores them.
./06-fix-usb-stability.sh

# 9. Keep Wi-Fi alive across reboots (~10 seconds).
#    An Android wifi HAL service zeroes /vendor/persist/wlan_mac.bin at
#    every boot; the kernel driver then defaults to a multicast MAC and
#    refuses to bring wlan0 up. A systemd oneshot restores the file +
#    reloads qca_cld3_wlan before NetworkManager runs.
./07-fix-wifi-mac-persistence.sh
```

After step 6, the device boots into Ubuntu Touch first-run.
Steps 7-9 fix cellular, USB stability, and Wi-Fi persistence —
without them, the post-install daily-use experience is broken.

### Post-install: reboot once before using Wi-Fi

On the **first** boot into UT, Wi-Fi will be broken — the toggle either
won't turn on or won't see any networks. This is a firmware-load
timing issue in halium-9's first boot, not anything specific to our
install path.

**Fix: long-press Power → Restart.** Wi-Fi works normally after the
second boot. Confirmed on our BE2012 unit; widely reported across
halium devices.

### Wi-Fi MAC persistence (step 9)

After a reboot, `nmcli device` shows wlan0 as `unavailable` and no
networks are reachable. `dmesg` shows:

```
icnss ... loading wlan/qca_cld/wlan_mac.bin failed with error -22
wlan: ... hdd_initialize_mac_address: using default MAC address
wlan: ... MAC is Multicast (via hdd_open_adapter)
wlan: ... Failed to open interfaces: -28
```

`/android/mnt/vendor/persist/wlan_mac.bin` is 0 bytes — an Android
wifi HAL service opens it for write at boot and truncates it, but
fails to write the regenerated MAC table. The next driver probe
defaults to an all-zero (multicast) MAC, which the kernel refuses
for station mode, and wlan0 never comes up.

`./07-fix-wifi-mac-persistence.sh` extracts the original 120-byte
`wlan_mac.bin` from `backup/be2012_pre_crossflash/persist.img`
(captured before the cross-flash), stashes it at
`/var/lib/wlan-mac-fix/`, and installs a systemd oneshot
(`wlan-mac-fix.service`) that runs before NetworkManager. The unit:

1. Compares the device's `wlan_mac.bin` size against the stashed copy.
2. If different, copies the stashed copy back, then `rmmod wlan` and
   `insmod /android/system/vendor/lib/modules/qca_cld3_wlan.ko` so the
   driver re-reads the MAC.
3. `ip link set wlan0 up` for good measure.

> **Don't `chattr +i` the file.** Locking it works as a "stop the
> truncation" fix on the surface, but the Android wifi HAL's boot
> sequence then aborts when its truncate fails, and wlan0 never gets
> brought up properly. The systemd-restore approach lets the HAL do
> its (broken) thing, then fixes things up before NM cares.

### USB adb stability (step 8)

After install, `adb devices` may show the phone briefly then drop
every few seconds, repeatedly. `dmesg` on the device shows tight
cycles:

```
USB_STATE=CONNECTED → CONFIGURED → DISCONNECTED → CONNECTED → CONFIGURED
```

always immediately after the PMI632 charger renegotiates the input
current limit (e.g. 1.35A → 1.5A).

Two subsystems are simultaneously managing the configfs USB gadget:
host-side `usb-moded` and the Halium Android container's
`android.hardware.usb@1.1-service-qti`. When the charger renegotiates
and the Android HAL emits a USB-state change event, usb-moded
mistakes it for a disconnect, tears the gadget down, and renegotiates
from scratch. adb on the host sees that as a connection drop.

`./06-fix-usb-stability.sh` drops `/etc/default/usb-moded.d/zzz-android-broken-udev-events.conf`
which sets `USB_MODED_ARGS=-i`. The `-i` flag
(`--android_usb_broken_udev_events`) tells usb-moded to ignore these
spurious events.

> **Filename gotcha:** the billie2 port ships
> `device-specific-config.conf` which sets `USB_MODED_ARGS=` (empty).
> systemd's `EnvironmentFile` processes files alphabetically;
> later files override earlier ones. Our override must sort *after*
> `device-`, hence `zzz-`, not `99-` (digit `9` sorts before letter `d`).

### Cellular: software stack fix (step 5)

UT's ofono on Halium logs three SIM-init complaints on a fresh
install against the BE82CB modem firmware:

```
Requested file structure differs from SIM: 6fb7   ← cosmetic
Facility lock query error: INVALID_ARGUMENTS     ← cosmetic
Querying PIN authentication state failed         ← the actual blocker
```

The first two are noise. `6fb7` is `EF_ECC` (Emergency Call Codes) —
ofono reads it twice (once transparent, once linear-fixed) because
the file type differs between SIM and USIM apps, so one of the two
calls always reports a structure mismatch (Launchpad bug #1229566:
not a real bug). The Facility lock `INVALID_ARGUMENTS` is similar —
ofono treats it as `locked=FALSE` and continues.

The third one is fatal: `sim_pin_query_cb` early-returns on error
before advancing `sim->state`, so SimManager never publishes IMSI,
NetworkRegistration never starts, and `Features` stays at `['sim']`.

`./05-fix-cellular.sh` binary-patches `/usr/sbin/ofonod` (~1.8 MB,
ofono 1.29+git12) at three offsets:

| Offset | Was | Now | Effect |
| --- | --- | --- | --- |
| `0x10b8f4` | `b.ne` | `nop` | silence the cosmetic EF_ECC structure-mismatch warning |
| `0xe1e94`  | `adrp x0, "Querying PIN…"` | `mov w23, #0` | **fix:** pin_type ← NONE on error |
| `0xe1e98`  | `add x0, x0, #0x8b8`       | `b #0xe1cc8`  | **fix:** jump into success continuation |

The first patch is optional cleanup. The second + third together are
the actual functional fix.

After patching, on our test unit:

- `Features`: `['gprs', 'rat', 'ussd', 'net', 'cbs', 'stk', 'sms', 'sim']`
- `IMSI`, `MobileCountryCode`, `MobileNetworkCode`, `SubscriberNumbers` all populated
- `NetworkRegistration` interface exposed and actively scanning
- APNs auto-provisioned from the matched MCC/MNC
- `PinRequired` stays `'none'` (uncorrupted — earlier patch attempts
  that hit `0xe1cc4`/`0xe1e90` did corrupt this)

The script keeps a backup at `/usr/sbin/ofonod.preCellularFix` and the
rollback command is printed at the end.

### Cellular: SIM ↔ modem-band caveat (carrier issue, not software)

Even with `Features` advanced and the modem actively `'searching'`,
sustained network registration depends on the SIM's home network
matching the bands the BE82CB modem firmware supports. The BE82CB
modem is T-Mobile US tuned (B71/B66/etc.).

**What works:** T-Mobile-network SIMs — T-Mobile direct, Mint Mobile,
Straight Talk's T-Mobile flavor, US Mobile T-Mobile.

**What doesn't:** Verizon-provisioned SIMs (Straight Talk's Verizon
flavor with ICCID `891480…` / MCC+MNC `311+480`, Visible, US Mobile
Verizon). The SIM authenticates fine and even shows Verizon as
`Status: 'current'` in a Scan, but the modem can't sustain a Verizon
attachment because:
- The T-Mobile modem firmware doesn't cover Verizon's primary LTE
  bands (B13, B5, B2 NR n2/n5/n66/n77).
- The device's IMEI isn't whitelisted with Verizon for Straight Talk.

If you bought the wrong-flavor Straight Talk SIM by mistake, calling
Straight Talk support to re-activate the line on T-Mobile network
(they'll mail a new SIM kit) gets you working data. Or swap to any
T-Mobile-network MVNO.

**VoLTE separately:** even on a working T-Mobile SIM, voice calls
need T-Mobile to whitelist the device's IMEI for VoLTE (US 3G is gone,
all voice routes through VoLTE). Plan on a T-Mobile support chat
after the cross-flash if you intend to use the phone as a voice driver.

## Why this is more complex than the stock UBports installer

The stock UBports installer assumes a device that already has:
- A bootloader-unlockable OEM device (`fastboot flashing unlock` works)
- A `ro.product.name` that matches one of the device aliases in `billie2.yml`
- A recovery whose `system-image-upgrader` can verify modern signatures

The BE2012 fails all three. This installer bridges the gap.

## Reproducibility notes

- All downloadable artifacts (firmware ZIPs, system-image tarballs,
  Magisk APK) are **gitignored**. They're fetched fresh by `00-prep.sh`.
- Per-step state is kept in `state/` (also gitignored) so re-runs can
  skip completed work.
- Signature-bypass recovery patching uses `magiskboot` extracted from
  the upstream Magisk APK at run time — we don't redistribute it.

## Open known issues / caveats

- Patched-recovery signature bypass is a **security weakening** — only
  necessary while UBports recovery's gpg remains at 1.4.13. If a newer
  community recovery for billie2 is published, prefer it.
- After the cross-flash, T-Mobile B71 (600 MHz) band is gone — daily
  driver coverage drops slightly. VoLTE may need a T-Mobile IMEI
  whitelist call.
- The Global BE2013 firmware is from 2020. OnePlus stopped Global
  updates for the N100 at OOS 10.5.3, so the device will not auto-update.
  Don't enable system updates — they'll try to push you to a newer
  region-locked build.

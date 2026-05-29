# BE2012 → BE2013 → Ubuntu Touch — macOS recipe (historical)

> **Superseded by [`installer/README.md`](installer/README.md) and the
> numbered `installer/*.sh` scripts.** This file is the original by-hand
> recipe that informed the design. The installer now does all of this
> idempotently, including two steps the original recipe didn't have:
> the BE82CB modem re-flash (step 2b) and the ofono SIM-init binary
> patch (step 5). Kept here for background — the project-ID tables and
> the ABL-exploit reference detail are still useful reading.

End-to-end runbook for cross-flashing a OnePlus Nord N100 BE2012
(T-Mobile US carrier SKU) to Global BE2013 firmware **without Windows**,
then installing Ubuntu Touch via the UBports installer. All steps run
from this macOS workstation.

This sidesteps the Windows-only MSMDownloadTool by driving the Qualcomm
Firehose protocol directly via `bkerler/edl`. The "project ID" check
that the patched-MSM trick exists to defeat is **host-side only** — by
not implementing it in our Python flasher, we walk past the gate.

> **Status (May 2026):** tested end-to-end on a BE2012 unit. The
> macOS-native flasher works. Brick risk turned out to be exactly as
> low as predicted — EDL recovers from every observed failure mode.

---

## Inventory (what `00-prep.sh` lays down at the repo root)

```
n100-be2012-crossflash/
├── flash.py                                       # the orchestrator (legacy)
├── flash_xml.py                                   # XML-driven cross-flash driver
├── venv/                                          # Python 3.10+ + edl + opscrypto
├── tools/
│   ├── edl/                                       # bkerler EDL client
│   │   └── Loaders/oneplus/0000000000515192_37cf317812121fed_fhprg_opn100.bin
│   └── oppo_decrypt/                              # OnePlus .ops decryptor
├── firmware/
│   └── OnePlus_Nord_N100_Global_OxygenOS_10.5.3.zip   # ~2.5 GB
├── host-tools/
│   └── platform-tools/                            # adb, fastboot
└── installer/
    ├── 00-prep.sh ... 05-fix-cellular.sh          # the actual install pipeline
    └── README.md                                  # per-step detail
```

---

## Step 0 — Pre-flight on the workstation (offline)

```bash
cd n100-be2012-crossflash
source venv/bin/activate
./flash.py --help          # sanity check the orchestrator
edl --help | head          # sanity check the EDL client
```

Add `host-tools/platform-tools` to your PATH for adb/fastboot:

```bash
export PATH="$PWD/host-tools/platform-tools:$PATH"
adb version                 # should print "Android Debug Bridge version 35.x"
```

---

## Step 1 — Prep the firmware payload (offline)

This unzips the OOS distribution, decrypts the `.ops` container, and
stages a clean directory of partition images for the flasher.

```bash
./flash.py prep firmware/OnePlus_Nord_N100_Global_OxygenOS_10.5.3.zip
```

Expected end output: `staged N partition images into:
.../firmware/extracted/.../flash_payload`. Note that path — you'll
need it for step 4.

Time: a couple of minutes. Decryption is the slow part.

If `prep` fails, the next steps cannot work. Re-run with the same zip
to retry (it idempotently wipes and rebuilds the extract dir).

---

## Step 2 — Save the current BE2012 product name (last chance)

If the phone still boots, capture the diagnostic baseline so we can
prove the cross-flash worked:

```bash
adb shell getprop ro.product.name      # expect: OnePlusN100TMO
adb shell getprop ro.build.version.ota # expect: a BE82CB tag
adb shell getprop ro.boot.bootloader   # bootloader version string
```

If the phone no longer boots, skip this step.

---

## Step 3 — Drop the phone into EDL

Pick one — they're equivalent if the phone still boots.

**Software (preferred):**
```bash
adb reboot edl
```
The screen will go black. On the Mac, run `system_profiler SPUSBDataType
| grep -A 4 -i qualcomm` and confirm a Qualcomm device with PID `9008`
appears. **PID 9008** is the right state; **9006** or **900E** mean
something else (recovery / partial bootrom).

**Hardware (works when phone is bricked):** unplug, power off, hold
**Vol-Up + Vol-Down**, plug in USB. Same Qualcomm 9008 should appear.

On macOS you do **not** need to install special drivers — Qualcomm
9008 is a standard USB-CDC device the kernel handles. If it doesn't
appear, try a different cable (must be USB-A or C *data* cable, not
charge-only) and a USB 2.0 port directly on the Mac (no hubs).

---

## Step 4 — Sanity-check the device sees us

```bash
./flash.py info
```

This uploads the OnePlus-signed Firehose loader and asks the device
to print its GPT. **Expected output:** a partition table listing
`xbl_a/b`, `boot_a/b`, `modem_a/b`, `super`, `vbmeta`, `userdata`,
etc. on LUN 0.

**Bad outputs and what they mean:**

| Symptom | Meaning | Recovery |
| --- | --- | --- |
| "Sahara: invalid command" or hangs at upload | Loader signature rejected | Try the extracted loader from `firmware/extracted/.../extract/prog_firehose_*.elf` via `--loader` |
| `printgpt` returns no partitions | Wrong `--memory` (UFS instead of eMMC) | We default to `--memory emmc`; SDM460 is eMMC, so this should not happen |
| Phone disappears mid-handshake | USB hub / cable flake | Reseat, retry; try USB-A on the Mac directly |
| "Project ID mismatch" or region rejection | The on-device check exists after all | We're stuck without Windows. Plan B was always going to be cross-flashing modem-only via raw partition writes |

If `info` succeeds, the workaround works in principle and the next
step is the actual flash.

---

## Step 5 — Dry-run the flash

```bash
./flash.py flash firmware/extracted/.../flash_payload --dry-run
```

(Use the `flash_payload` path that `prep` printed in step 1.)

This runs the full flash pipeline with `edl --skipwrite`, which goes
through every motion but writes nothing. It validates:

- the loader connects
- every partition image's basename matches a real GPT partition
- every image fits its target partition

If dry-run errors with "Couldn't write partition X. Either wrong
memorytype given or no gpt partition", an extracted file's name
doesn't match any GPT entry. Likely culprits: auxiliary files
opscrypto extracted alongside the real partition images. Fix by
filtering the staging dir; rerun `prep` after editing
`list_partitions()` in `flash.py` to exclude the offender.

---

## Step 6 — Do the cross-flash

```bash
./flash.py flash firmware/extracted/.../flash_payload
```

Confirm with `YES` when prompted. The script will print a progress
line per partition. Total time: **5–10 minutes** for ~2 GB across
the eMMC.

Do not unplug, do not let the Mac sleep, do not touch the cable.

When complete, the phone will reboot automatically into the new
firmware. First boot of Global OOS 10.5.3 takes another 5–10
minutes (it's regenerating dalvik caches).

---

## Step 7 — Verify the cross-flash took

After OOS boots and finishes the welcome wizard (Wi-Fi can be a
dummy SSID — we don't need network):

```bash
adb shell getprop ro.product.name      # expect: OnePlusN100  (was OnePlusN100TMO)
adb shell getprop ro.build.version.ota # expect: Global tag, not BE82CB
```

If `ro.product.name` is still `OnePlusN100TMO`, the system partition
didn't take. Likely cause: super partition writes need to go to both
A and B slots; check that prep staged both `super.img` variants and
they wrote successfully in the edl log.

---

## Step 8 — Unlock the bootloader

**The actual unlock gate on N100 BE2012 is Android-side carrier shim
apps, not partition bytes.** Confirmed end-to-end on 2026-05-29 — this
device was unlocked entirely from macOS using this procedure:

1. Walk through OOS first-boot. Connect to Wi-Fi, complete the wizard.
2. *Settings → System → System Update* → **disable automatic updates**.
3. *Settings → Accounts* → **add a Google account** and sign in.
   (Without an account some carrier services don't initialize, and the
   shim apps stay in the way.)
4. *Settings → About phone → Build number* — tap ×7 to enable Developer
   options. (Settings search for `developer` works too if tap-7 is
   broken on your build.)
5. *Settings → System → Developer options* → enable **USB Debugging**.
6. Plug into the Mac, accept the RSA fingerprint prompt on the phone.
7. **Uninstall the carrier-shim apps** that hold `sys.oem_unlock_allowed`
   at 0. From the Mac:
   ```bash
   for pkg in cn.oneplus.oemtcma com.example.tmo \
              com.qualcomm.qti.remoteSimlockAuth com.qualcomm.qti.uim \
              com.oneplus.carrierlocation; do
       adb shell pm uninstall --user 0 "$pkg"
   done
   ```
   All five should print `Success`. (`pm uninstall --user 0` is a soft
   uninstall — the APKs stay in `/system`, a factory reset restores
   them. Non-destructive.)
8. Verify the gate flipped:
   ```bash
   adb shell getprop sys.oem_unlock_allowed   # expect: 1 (was 0)
   ```
   The OEM Unlocking toggle in Developer options should now be
   **responsive**. Flip it on.
9. Unlock:
   ```bash
   adb reboot bootloader
   fastboot flashing unlock
   ```
   Phone prompts with **Vol-Down to select UNLOCK / Power to confirm**.
   Device wipes userdata and reboots into unlocked Global OOS.

**Why the shim uninstall is the gate, not the Google account alone:**
the BE2015 forum reports say "add a Google account, then it ungreys"
— our experience says that's actually downstream of these carrier
packages getting into a particular state once an account is present,
or just a coincidence of order. Skipping the shim uninstall on BE2012
leaves the toggle greyed even with a Google account signed in
(empirically confirmed on our unit; before-and-after props attached
to the win).

**Reference:** nylar357/nord_oem ships the same `pm uninstall` flow for
the N10 BE2028 (same OnePlus build family, same shim packages on a
sibling device). <https://github.com/nylar357/nord_oem>

---

## Step 9 — Install Ubuntu Touch

Open `host-tools/ubports-installer_0.11.2_mac_x64.dmg`, drag the app
to Applications, launch it.

(On Apple Silicon: the DMG is x86_64; macOS will run it via Rosetta.
First launch may take a few seconds.)

In the installer:
1. Plug the phone in, USB debugging enabled.
2. It should auto-detect **OnePlus Nord N100 (billie2)**.
3. Pick channel **24.04 (noble) — stable**.
4. Follow the prompts. The installer puts the phone into fastboot,
   downloads the right images, and flashes boot/recovery/system/userdata.
5. First UT boot: 5–10 minutes.

---

## Recovery and rollback

**If the phone is in EDL but unresponsive to `flash.py info`:**

```bash
# try the per-firmware loader extracted by prep:
./flash.py info --loader firmware/extracted/.../extract/prog_firehose_ddr.elf

# or talk to it raw to confirm it's there at all:
edl --loader tools/edl/Loaders/oneplus/0000000000515192_37cf317812121fed_fhprg_opn100.bin printgpt --debugmode
```

**If the phone boot-loops after the cross-flash:**

The cross-flash succeeded but Android-Verified-Boot is unhappy with
the new vbmeta. Re-enter EDL (vol-up + vol-down + USB) and:

```bash
./flash.py flash firmware/extracted/.../flash_payload   # re-run; idempotent
```

If that still fails, manually push a vbmeta with verification disabled
(after step 8, in fastboot):

```bash
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img
fastboot --disable-verity --disable-verification flash vbmeta_b vbmeta.img
```

`vbmeta.img` is in `firmware/extracted/.../extract/`.

**If you want to bail out and go back to BE2012 OOS:**

You can't — at least not from this rig. You'd need the BE82CB MSM tool
from the OnePlus mirror, which is Windows-only. Once you're in Global
OOS, OTAs will keep you on Global. This is fine for our goal (UT).

---

## What we now know (post-attempt 1, 2026-05-29)

1. **Project-ID check is purely host-side.** Confirmed by direct
   replication. `bkerler/edl` doesn't implement it; our 48 partition
   writes all succeeded on the BE2012 device, ending in clean Global
   BE2013 OOS boot, vbmeta green, `ro.product.name` = `OnePlusN100`.
2. **The `--devicemodel 20882` (T-Mobile projid) flag on every `edl w`
   call is required** for signed-partition writes (xbl_a, abl_a,
   boot_a, modem_a, vbmeta_a, etc.). Without it, the OnePlus signing
   module init returns None and writes crash with
   `AttributeError: NoneType.generatetoken`. With it, all writes
   succeed.
3. **`PrimaryGPT`/`BackupGPT` are not real edl partition labels.**
   They appear in the firmware's `settings.xml` because MSM uses them
   as conceptual names. `edl` rejects them with "Couldn't detect
   partition" and corrupts subsequent Sahara state. The script must
   skip these — they are listed in the `SKIP_LABELS` constant in
   `flash_xml.py`. The on-device GPT is identical between BE2012 and
   BE2013 (same hardware), so skipping is correctness-preserving.
4. **Cross-flash alone does NOT unlock the bootloader.** Confirmed on
   our BE2012: `fastboot flashing unlock` returns
   `Flashing Unlock is not allowed` even after a successful flash, and
   the OEM Unlock toggle in Developer options stays greyed. The
   documented fix is **add a Google account during first-boot**
   (per BE2015 forum reports). If that doesn't ungrey the toggle,
   plan B is the ABL/param exploit in `notes.md` §4b — untested on N100
   as of this writing.
5. **VoLTE on T-Mobile after Global modem.img is in place** — separate
   from UT install success; likely needs a T-Mobile IMEI whitelisting
   call. Track separately.
6. **Anti-rollback fuses** — not triggered on our flash; device boots
   clean, no SBL_ARB issues reported.

---

## References

See `notes.md` in this directory for the full citation list.

Most relevant:
- UBports BE2012 reimage success (Windows path): https://forums.ubports.com/topic/10766/reimage
- BE2015 install success (same patched-MSM technique): https://forums.ubports.com/topic/11194/oneplus-nord-n100-metropcs-be2015-install-success
- bkerler/edl: https://github.com/bkerler/edl
- oppo_decrypt: https://github.com/bkerler/oppo_decrypt

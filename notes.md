# N100 BE2012 → BE2013 cross-flash → Ubuntu Touch

> **macOS-native flasher built — see [`RECIPE.md`](RECIPE.md) for the step-by-step
> runbook and [`flash.py`](flash.py) for the orchestrator.** The notes below
> are the original investigation that informed the design. The recipe is
> the source of truth for "what to do."

Goal: take a **OnePlus Nord N100, model BE2012** (T-Mobile US carrier SKU)
and end up on stable Ubuntu Touch 24.04 (`billie2` / noble).

Short version: BE2012 hardware is identical to the Global BE2013. The
"not supported" verdict comes from three firmware-level locks layered on
top of the same SoC:

1. **Carrier OEM-Unlock policy** — the toggle in Developer Options is
   greyed out on T-Mobile firmware. Needs a token from OnePlus (~180-day
   wait) OR a cross-flash to wipe the carrier policy partition.
2. **Product name mismatch** — `ro.product.name` on BE2012 is
   `OnePlusN100TMO`, but `installer-configs/v2/devices/billie2.yml`
   only lists `aliases: [OnePlusN100]`. The UBports Installer therefore
   refuses to recognise the device.
3. **Partition / signed-image layout** — boot, recovery, dtbo, vbmeta
   images in `github.com/rubencarneiro/billie2/releases` are built for
   the Global BE2013 partition table and signing chain; pushing them
   straight onto T-Mobile firmware soft-bricks.

All three resolve when you cross-flash the device to Global BE2013
OxygenOS via Qualcomm MSMDownloadTool in EDL mode. There is at least
one explicit BE2012-on-UT success report (`bdomecq` in UBports forum
topic 10766/reimage) plus the well-documented BE2015 (Metro) path
(`topic 11194`) which uses the same patched MSM package.

---

## The path

### 0. Prep

- Bare-metal Windows host. VMs break the MSM Sahara handshake mid-flash
  and leave the phone in Qualcomm CrashDump mode (recoverable, but
  annoying). Confirmed by `rocket2nfinity` in UBports topic 11840.
- **Qualcomm HS-USB QDLoader 9008** driver installed. Do NOT install the
  Quectel 9008 driver — it presents the same VID/PID and silently breaks
  Sahara (XDA thread 4770012).
- USB 2.0 port. USB 3 hubs are flaky during the 9008 stage.
- Backup nothing — the device is going to be wiped to factory.

### 1. Drop into EDL

Two options:

- Software (from working OOS, USB debugging on): `adb reboot edl`
- Hardware (works even on a bricked phone): power off, hold **Vol-Up +
  Vol-Down**, plug in USB. Screen stays black; Windows should detect
  "Qualcomm HS-USB QDLoader 9008".
- Last resort: PCB test point, mapped at
  <https://gsmxblog.com/oneplus-nord-n100-edl-point/>.

### 2. Cross-flash to Global BE2013 via patched MSM

You need the **patched** MSM, not the stock BE82CB one. The stock BE82CB
tool will only put you back on T-Mobile firmware. The patched version
(rocket2nfinity, distributed in the BE2015 install-success thread, also
works for BE2012) is **purely a host-side `settings.xml` edit** — no
device-side magic, no extra Firehose commands.

The four fields the patch rewrites (verbatim from `dugen`'s post in
the BE2015 thread):

```xml
Project="20880"
Version="bengal_14_O.04_201221"
ModelVerifyPrjName="6ccf5913"
ModelVerifyRandom="0S5ul8diroerEa2h"
ModelVerifyHashToken="61D90BD1E63098DEF7424C5FF14EBF097AE1802709F585F05670B2B7B02B31E7"
```

Project ID table from public `bkerler/edl` source
(`edlclient/Library/Modules/oneplus.py` lines 93-100):

| Project ID | Variant | `ModelVerifyPrjName` hash | Codename |
| --- | --- | --- | --- |
| **20880** | N100 Metro (BE2015) | `6ccf5913` | billie2t |
| **20881** | N100 Global (BE2013) | `fa9ff378` | billie2 |
| **20882** | N100 T-Mobile (BE2012) | `4ca1e84e` | billie2t |
| **20883** | N100 Europe (BE83BA) | `ad9dba4a` | billie2 |

So the patched MSM tells MSM.exe "you're flashing a Metro device" while
the `.ops` actually contains BE2013 Global firmware. The host-side
project-ID guard inside `MsmDownloadTool.exe` matches Metro's signing
hash, so the partition writes are allowed to proceed.

**Implication for the macOS-native rewrite:** `bkerler/edl` doesn't
implement the host-side project-ID guard at all, so we skip the patch
entirely. The actual partition writes are equivalent. See `flash_xml.py`.

Underlying tooling is `oppo_decrypt` (bkerler) to unwrap the `.ops`,
manual XML edit, repack — only needed if you're going through MSM.exe.

Run `MsmDownloadTool.exe` → Start. Phone goes through partition wipe +
flash + auto-reboot. Total time ~5 min when it works.

Failure modes:

- "Sahara communication failed" → wrong USB driver. Re-install Qualcomm
  HS-USB QDLoader 9008.
- "Qualcomm CrashDump Mode" → flash was interrupted. Hold Vol-Up + Power
  ~10s to re-enter EDL, re-run MSM.
- Baseband / IMEI blank post-flash → not a brick. Repaired by Halab or
  UMT service files (paid, but recoverable).

### 3. Verify the cross-flash took

After first boot of OOS 10.5.3/10.5.5 Global:

```bash
adb shell getprop ro.product.name      # expect: OnePlusN100  (was OnePlusN100TMO)
adb shell getprop ro.build.version.ota # expect: a Global tag, not BE82CB
```

If `ro.product.name` is still `OnePlusN100TMO`, the patched XML didn't
apply — re-do step 2.

### 4. Unlock the bootloader

**Critical:** after the cross-flash, the OEM Unlock toggle in Developer
Options stays **greyed** until you complete first-boot account setup.
Verbatim from BE2015 install-success thread (user `Joko`):

> "The OEM unlock is greyed out until you add a Google account on the
> phone."

Exact sequence the successful BE2015 owners followed:

1. Walk through OOS first-boot wizard (don't skip it).
2. Connect to **Wi-Fi**.
3. Settings → System → System Update → **disable automatic updates**.
4. Settings → Accounts → **add a Google account** (sign in with one).
5. Settings → About phone → tap **Build number** ×7.
6. Settings → System → Developer options → enable **USB Debugging**
   AND **OEM Unlocking** (toggle is now responsive).
7. From the Mac:
   ```bash
   adb reboot bootloader
   fastboot oem unlock     # or: fastboot flashing unlock
   ```

If the OEM Unlock toggle is **still greyed after the Google account
step**, fall through to the ABL/`param` carrier-flag exploit (next
subsection). Don't skip the Google account step — it is the documented
gate on every reported BE2012/BE2015 unlock success.

### 4b. Plan B: ABL carrier-flag exploit via `param` partition

If the toggle stays greyed and `fastboot flashing unlock` keeps
returning `Flashing Unlock is not allowed`, the bootloader (ABL) is
still reading T-Mobile SWID from RPMB. The N10 BE2028 unlock guide
documents the mechanism (very likely identical on the N100 — same
SoC family, same OnePlus build system):

> "The ABL performs a carrier check by comparing a Software Project ID
> (SWID) stored in RPMB against the T-Mobile model hash (0x142F1BD7).
> The technique writes a non-TMO model's SWID (0xB8BD9E39 for model
> 20886) into the param partition at specific encrypted SID blocks
> (0x13C primary, 0x33C backup), along with a magic trigger value
> (0xDC9EF893) in the proc field. When the device reboots, the ABL
> detects this magic value and writes the alternate SWID to RPMB,
> bypassing the carrier lock check."
>
> "The param partition uses AES-128-CBC encryption with a static key
> (`000OnePlus818000`) and specific IV, requiring MD5 verification at
> multiple layers."

For the N100, the SWID we want to inject is **`0xfa9ff378`** (Global,
projid 20881). The TMO SWID currently in RPMB is **`0x4ca1e84e`**
(projid 20882). Trigger magic stays `0xDC9EF893`.

Implementation outline (not yet built):

1. Read current `param` from device (`edl r param param_now.bin --lun 0`).
2. AES-128-CBC decrypt the SID blocks at 0x13C and 0x33C using key
   `000OnePlus818000`.
3. Replace SWID `0x4ca1e84e` → `0xfa9ff378` at both offsets.
4. Write `0xDC9EF893` at the "proc" field offset.
5. Recompute MD5 checksums at each verification layer.
6. AES re-encrypt.
7. Flash via `edl w param param_patched.bin --lun 0`.
8. Reboot — ABL writes Global SWID to RPMB on next boot.
9. Reboot again — bootloader's carrier check now passes, OEM Unlock
   toggle becomes responsive, `fastboot flashing unlock` succeeds.

This is real work (~hours) and untested on the N100 specifically.
Reference implementation is nylar357/nord_oem for the N10 — same
mechanism, different SWID/proc-field offsets.

### 5. Run the UBports Installer

Standard flow per `install.md` from this repo. The device should now
match `aliases: [OnePlusN100]` and the installer pulls noble images
normally. First boot 5-10 min.

---

## Why BE2012 reads as "not supported" in installer-configs

From the cloned subrepo `installer-configs/v2/devices/billie2.yml`:

- Device record uses `aliases: [OnePlusN100]`.
- Installer's device-resolution path
  (`ubports-installer/src/core/helpers/api.js` →
  `ubports-installer/src/core/core.js`) calls `getDevice(codename)`
  against the UBports devices API. Stock BE2012 reports
  `OnePlusN100TMO`, which 404s → "device unsupported" popup.

A trivial PR to add `OnePlusN100TMO` and `OnePlusN100MPCS` aliases would
silence the popup but **not** produce a working install — the prebuilt
boot/recovery/dtbo/vbmeta images at
`github.com/rubencarneiro/billie2/releases/download/1.0/` are signed for
the Global BE2013 partition layout. Cross-flashing the firmware first
is the only correctness-preserving path.

---

## Carrier-band consequences

After cross-flash, the modem firmware is Global, not T-Mobile-tuned. From
the LTE table already in `install.md`:

- Lose **B71 (600 MHz)** — weaker rural / indoor coverage on T-Mobile.
- Keep B2/4/12 — core T-Mobile LTE coverage still works.
- VoLTE may need a T-Mobile support call to whitelist the IMEI. Data
  often works while voice fails silently until that's done.

If the daily-driver carrier was T-Mobile and rural coverage matters, the
post-crack phone will still cover T-Mobile metro areas but not match a
US-spec phone. Realistic outcome for a dev/secondary device.

---

## Risk summary

| Failure | Likelihood | Recoverable? |
| --- | --- | --- |
| MSM "Sahara failed" (wrong driver) | medium | yes — fix driver, retry |
| Qualcomm CrashDump mid-flash | low-medium | yes — re-enter EDL, retry |
| Baseband / IMEI blank post-flash | low | yes — paid service file |
| Stuck in EDL forever | very low | yes — PCB test point + bkerler/edl |
| Hard brick (no EDL) | ~0 | no — but not observed on N100 |

EDL is rooted in the Qualcomm SoC ROM and survives every software state
short of physical damage, so genuine paperweight risk is negligible.

---

## Reference URLs

**UBports threads**

- BE2012 reimage success (the smoking gun): <https://forums.ubports.com/topic/10766/reimage>
- BE2015 install success (same method): <https://forums.ubports.com/topic/11194/oneplus-nord-n100-metropcs-be2015-install-success>
- BE2012 "not supported" diagnosis thread: <https://forums.ubports.com/topic/11571/oneplus-nord-100-be2012-device-not-supported>
- BE83BA manual install ref: <https://forums.ubports.com/topic/10839/oneplus-nord-n100-be83ba-b2013-ubuntu-touch-manual-install>
- VM/MSM failure thread: <https://forums.ubports.com/topic/11840/difficulties-with-downgrading-my-oneplus-nord>
- N100 category: <https://forums.ubports.com/category/120/oneplus-nord-n100>
- billie2 porting (GitLab): <https://gitlab.com/ubports/porting/community-ports/android10/oneplus-nord-n100/oneplus-billie2>

**XDA**

- Global stock for BE2012/BE2015 conversion ROM: <https://xdaforums.com/t/rom-global-stock-be2013-for-be2012-be2015-models-android-oxygenos-10-5-3.4769390/>
- BE82CB (T-Mobile) unbrick tool: <https://xdaforums.com/t/opn100-oos-tmo-be82cb-unbrick-tool-to-restore-your-device-to-oxygenos.4245495/>
- BE82CF (Metro) unbrick tool: <https://xdaforums.com/t/opn100-oos-metro-be82cf-unbrick-tool-to-restore-your-device-to-oxygenos.4245499/>
- BE81AA/BE83BA (Global/EU) unbrick tool: <https://xdaforums.com/t/opn100-oos-81aa-83ba-unbrick-tool-to-restore-your-device-to-oxygenos.4217855/>
- OOS builds repo (every .zip): <https://xdaforums.com/t/oneplus-nord-n100-rom-ota-oxygenos-repo-of-oxygenos-builds.4253501/>
- TMO/MPCS OEM-unlock master guide: <https://xdaforums.com/t/oneplus-nord-n10-n100-tmo-mpcs-network-unlock-enable-oem-unlocking-april-19th-2021.4264593/>
- Termux/Linux/macOS unlock variant: <https://xdaforums.com/t/guide-termux-linux-wsl-mac-os-network-unlock-and-enable-oem-unlocking-for-the-oneplus-nord-n100.4264609/>
- Stable EDL / Qualcomm vs Quectel driver: <https://xdaforums.com/t/solved-unstable-edl-mode-cause-install-quectel-9008-instead-of-qualcomm-9008.4770012/>
- Firehose / EDL loader identification: <https://xdaforums.com/t/identifying-edl-firehose-loaders.4525079/>
- "Advice before flashing OnePlus Nord N100 T-Mobile": <https://xdaforums.com/t/advice-before-flashing-a-oneplus-nord-n100-t-mobile.4677278/>
- N100 root 10.5.4 (post-crack Magisk path): <https://xdaforums.com/t/oneplus-nord-n100-root-10-5-4.4233467/>

**Tooling**

- `oppo_decrypt`: <https://github.com/bkerler/oppo_decrypt>
- `bkerler/edl` (cross-platform EDL client): <https://github.com/bkerler/edl>
- `bkerler/Loaders` (Firehose `prog_emmc_firehose_*.mbn`): <https://github.com/bkerler/Loaders>
- DroidWin MSM mirror: <https://droidwin.com/download-msm-download-tool-unbrick-any-oneplus-device/>
- OnePlus Community Server N100 mirror: <https://onepluscommunityserver.com/list/Unbrick_Tools/OnePlus_Nord_N100/>
- OnePlus unlock-token portal: <https://www.oneplus.com/unlock_token?type=2>
- N100 EDL test point map: <https://gsmxblog.com/oneplus-nord-n100-edl-point/>

---

## Open questions / things to verify before flashing

- [ ] Confirm the rocket2nfinity patched MSM ZIP is still hosted on the
      BE2015 thread (mirror may have rotted — check before downtime).
- [ ] Get the host onto a Windows box with USB 2.0 and Qualcomm 9008
      drivers in advance, not at flash time.
- [ ] Check `ro.product.name` and `ro.build.version.ota` on the BE2012
      device as-shipped, before doing anything, so the diff after the
      cross-flash is unambiguous.
- [ ] If a T-Mobile SIM is going in this thing daily, call T-Mobile
      after the cross-flash to whitelist the IMEI for VoLTE.

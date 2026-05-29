# n100-be2012-crossflash

> A [TeamIDE](https://teamide.dev) project. If this saved you a phone, [chip in](https://teamide.dev/support).

Join the community on [Discord](https://discord.gg/YVcsHXSCYG) · Follow on [X](https://x.com/TeamIDElab) · Subreddit: [r/TeamIDELabs](https://www.reddit.com/r/TeamIDELabs/) · YouTube: [@TeamIDElabs](https://www.youtube.com/@TeamIDElabs).

> **Read this before you do anything.** This is not a user-friendly
> installer. It is a research record of how we cracked one specific
> carrier-locked SKU, written up so other people with the same model
> and the same problem don't have to start from zero. Several steps
> require manual judgment, comfort with a terminal, the ability to
> read an error message and reason about what it means, and a tolerance
> for steps that don't always work the first time. If `adb`, `fastboot`,
> `sudo`, `dd`, and `EDL mode` aren't already familiar concepts to
> you, this is not the project to learn them on. The actual hard-brick
> risk is low (EDL is hardware-rooted in the Qualcomm SoC and survives
> almost every software state), but you can absolutely:
>
> - lose all data on the device, multiple times
> - void any remaining manufacturer or carrier warranty
> - lose your line on T-Mobile until you call support and get the IMEI
>   re-whitelisted for VoLTE
> - end up with a phone that runs Ubuntu Touch but won't attach to your
>   current SIM (the modem/SIM/carrier match is its own problem — see
>   the "Cellular caveats" section)
> - spend a weekend on it
>
> This installer is provided as-is under [GPL-2.0-or-later](LICENSE).
> No warranty, no support contract, no obligation on us to fix it for
> your specific device. If you brick your phone, it's your phone.
> If you don't have the skills to recover from a step going sideways,
> stop here and either pay someone who does (see [HIRE.md](HIRE.md))
> or use a phone with an officially supported UBports path. We are
> sharing this because it took real work to figure out and other people
> with the same locked SKU shouldn't have to repeat it — not because
> we recommend it as a path for anyone in particular.

Reproducible installer that takes a **carrier-locked OnePlus Nord N100
BE2012 (T-Mobile US)** and lands it on **Ubuntu Touch 24.04 (noble)**.

**Built and tested on macOS** (Apple Silicon, macOS 26.2). Linux should
also work — the underlying tooling (`bkerler/edl`, `oppo_decrypt`,
`fastboot`, `magiskboot`) is cross-platform, and the wrapper scripts
auto-detect OS where it matters. Linux hasn't been independently
verified end-to-end yet; success reports welcome.

**No Windows.** No MSMDownloadTool, no borrowed PC, no VM.

If you have a BE2013 (Global) or BE83BA (EU) N100, **use the stock
[UBports installer](https://devices.ubuntu-touch.io/installer/)
instead.** This repo exists for the BE2012 SKU specifically, which the
stock installer rejects as "device not supported."

## Why this is a separate installer

The BE2012 trips four locks the stock UBports installer doesn't handle:

1. **`ro.product.name` is `OnePlusN100TMO`** — the stock installer
   only recognises `OnePlusN100`, so it refuses to start.
2. **`fastboot flashing unlock` is gated** by T-Mobile carrier shim
   apps holding `sys.oem_unlock_allowed=0`.
3. **The recovery's gpg 1.4.13 (2012) can't verify modern SHA512 sigs
   on UT system images** — every install attempt with stock recovery
   fails at the keyring step.
4. **Modem firmware ↔ ofono SIM-init incompatibility** — even after
   the steps above, ofono `sim_pin_query_cb` early-returns on a PIN
   auth error from the modem, leaving `Modem.Features` stuck at
   `['sim']`: no IMSI, no `NetworkRegistration`, no cellular.

This installer walks past all four:

| Step | What | How |
| --- | --- | --- |
| 1 | Cross-flash to BE2013 Global | macOS-native EDL/Firehose driver (`flash_xml.py`) using `bkerler/edl` + OnePlus's signed Firehose loader. Skips the patched-MSM project-ID hack because we never implement the host-side guard. |
| 2 | Bootloader unlock | Remove five OnePlus carrier-shim apps via `pm uninstall --user 0`. Flips `sys.oem_unlock_allowed` from 0 → 1; `fastboot flashing unlock` then works. |
| 2b | Modem re-flash | Put the BE82CB (T-Mobile US) `NON-HLOS.bin` back over the BE2013 modem. The BE2013 Global modem returns `iccIOForApp INTERNAL_ERR` against modern Halium-9 ofono until the patches in step 5 are in place — easier to just keep the T-Mobile-tuned modem from the start. Optional: skip this and use BE2013 modem (works fine with step 5 patches in place — see `installer/diagnostic/`). |
| 3 | Recovery + partition layout | Flash rubencarneiro UBports boot/recovery/dtbo, patched vbmeta (flags 0x3, verification off), resize `system_a` to 3 GB. |
| 4 | Install Ubuntu Touch | `magiskboot` (extracted from Magisk APK) repacks the recovery on-device with `system-image-upgrader` patched to skip GPG verification and `gpg` stubbed. Auto-install proceeds normally. |
| 5 | Cellular fix | Three-byte binary patch on `/usr/sbin/ofonod` (ofono-sailfish 1.29+git12). Hijacks the `sim_pin_query_cb` error path: instead of "log error and return," set `pin_type = OFONO_SIM_PASSWORD_NONE` and jump to the success continuation. SIM state machine advances, IMSI reads, `Features` → `['gprs','rat','ussd','net','cbs','stk','sms','sim']`. |

After step 5 the device runs Ubuntu Touch with a complete SIM stack.
Cellular *attach* additionally depends on SIM ↔ carrier ↔ band match
(see "Cellular caveats" in `installer/README.md`).

## Requirements

| Need | Why |
| --- | --- |
| **OnePlus Nord N100, model BE2012** | This installer is specific to this SKU. |
| **macOS** (Apple Silicon ok) | Tested on macOS 26.2; Intel Macs should work but untested. |
| **Python 3.10+**, `brew install libusb` | EDL Firehose client. |
| **USB-C data cable** (not charge-only) | EDL + fastboot. |
| **~13 GB free disk** | BE2013 firmware (~2.5 GB) + BE82CB firmware (~2.5 GB) + UT system-image (~600 MB) + scratch. |
| **Network** | Downloads firmware + UT system-image files. |
| **BE82CB.zip** (T-Mobile OnePlus N100 firmware, `bengal_14_O.04_201221`) | Needed by step 2b. The .zip is not redistributable — obtain it from a BE82CB device or a firmware archive. Place at `firmware/BE82CB.zip` or set `BE82CB_ZIP=<path>`. |

## Usage

```bash
git clone https://github.com/dcherrera/n100-be2012-crossflash
cd n100-be2012-crossflash

# Step 0 — install deps, clone bkerler/edl + oppo_decrypt, fetch firmware
./installer/00-prep.sh

# Step 1 — cross-flash BE2012 → BE2013 (EDL mode, ~10 min)
./installer/01-cross-flash.sh

# Step 2 — unlock bootloader (after OOS first-boot + Google account)
./installer/02-unlock-bootloader.sh

# Step 2b — re-flash BE82CB modem (after post-unlock OOS first-boot)
./installer/02b-fix-modem.sh

# Step 3 — recovery + partition reshape
./installer/03-bootstrap-recovery.sh

# Step 4 — install Ubuntu Touch (~5 min)
./installer/04-install-ut.sh

# Step 5 — fix the SIM-init blocker (after UT first-boot + lock PIN set)
./installer/05-fix-cellular.sh
```

Each script is idempotent. See `installer/README.md` for per-step
detail (entering EDL, what to do during OOS first-boot, Wi-Fi reboot
fix, cellular caveats, etc.).

## What's in the repo

```
.
├── README.md                          # you are here
├── LICENSE                            # GPL-2.0-or-later
├── notes.md                           # original investigation notes
├── RECIPE.md                          # early macOS recipe (superseded by installer/)
├── flash.py                           # firmware-prep helper (legacy)
├── flash_xml.py                       # cross-flash driver — XML-driven EDL/Firehose
└── installer/
    ├── README.md                      # per-step detail + cellular notes
    ├── 00-prep.sh ... 05-fix-cellular.sh
    ├── lib/common.sh                  # shared helpers
    └── diagnostic/                    # research scripts (not part of normal install)
        ├── swap-to-be2013-modem.sh    # switch the modem to BE2013 Global
        └── swap-to-be82cb-modem.sh    # switch back to BE82CB T-Mobile
```

External tools (`tools/edl`, `tools/oppo_decrypt`), the Python venv
(`venv/`), the Android platform-tools (`host-tools/platform-tools/`),
and large firmware downloads (`firmware/`, `downloads/`) are all
fetched by `00-prep.sh` at runtime and gitignored.

## Reverse path — getting back to stock

Each step is reversible up to a point:

- **Before step 1:** unplug the cable. The phone is unchanged.
- **After step 1, before step 2:** flash BE82CB stock via the BE82CB
  unbrick tool (XDA: `opn100-oos-tmo-be82cb-unbrick-tool`).
- **After step 2 (bootloader unlocked):** same, plus you may need to
  re-lock the bootloader manually.
- **After step 4 (UT installed):** flash BE82CB unbrick tool. UT is
  wiped, you're back on T-Mobile OOS.

The original device-unique partitions (`modemst1`, `modemst2`, `fsg`,
`fsc`, `keystore`, `persist`, etc.) are backed up by step 1 to
`backup/be2012_pre_crossflash/` and can be re-flashed via
`flash_xml.py` if needed.

## Status of common features after this install

| Feature | Works? |
| --- | --- |
| Wi-Fi | Yes (long-press Power → Restart after first boot, then fine) |
| Bluetooth | Yes |
| Cellular SIM read (IMSI, ICCID, SubscriberNumbers) | Yes, with step 5 patches |
| Cellular network registration | Depends on SIM ↔ modem-band match. T-Mobile-network SIMs work; Verizon-provisioned SIMs read fine but won't sustain attach (IMEI not on Verizon's CDLC + modem firmware is T-Mobile-band tuned). |
| Mobile hotspot | Should work post-cellular (UT 24.04-1.1+ has the Halium-9 hotspot fix). Not yet empirically tested on this device — pending a working SIM. |
| Camera, audio, sensors | Yes (per upstream billie2 noble port) |
| VoLTE | Needs T-Mobile to whitelist the device IMEI. Plan on a support chat. |

## Acknowledgements

- **`bkerler/edl`** and **`bkerler/oppo_decrypt`** — the EDL Firehose
  client and OnePlus `.ops` decoder. This installer is essentially a
  driver around these tools.
- **`rubencarneiro/billie2`** — the boot/recovery/dtbo images the
  bootstrap step flashes.
- The **BE2015 (Metro) UBports forum thread** —
  [forums.ubports.com/topic/11194](https://forums.ubports.com/topic/11194/oneplus-nord-n100-metropcs-be2015-install-success)
  — for documenting the same install path on the sibling carrier SKU.
- **UBports** — for Ubuntu Touch, including the billie2 community port
  and the 24.04 noble channel.

## Known-good snapshot

| Component | Pinned to | Notes |
| --- | --- | --- |
| Host OS | macOS 26.2 (Apple Silicon) | Intel Macs should work but untested. |
| Python | 3.10+ | venv built into stdlib. |
| Ubuntu Touch channel | `24.04-1.x/arm64/android9plus/daily` | Set in `installer/lib/common.sh`. Switch to `release` for less drift if/when stable. |
| UT build tested | 543, 2026-05-28 | ofonod size 1,824,688 bytes (ofono-sailfish 1.29+git12). |
| `bkerler/edl` | tip of `main` at install time | The OnePlus N100 Firehose loader is in the `Loaders` submodule — `00-prep.sh` clones with `--recurse-submodules`. |
| `bkerler/oppo_decrypt` | tip of `main` at install time | OnePlus `.ops` unpacker. |
| `rubencarneiro/billie2` | release `1.0` | boot/recovery/dtbo/vbmeta images. |
| `Magisk` | `v28.1` | only used for the `magiskboot.arm64` binary inside the APK. |
| BE2013 firmware | OnePlus_Nord_N100_Global_OxygenOS_10.5.3.zip (~2.5 GB) | Mirror: `onepluscommunityserver.com`. XDA backup at `4769390`. |
| BE82CB firmware | `bengal_14_O.04_201221` (~2.5 GB) | Not redistributable — user supplies. |

### What rots first

The `05-fix-cellular.sh` ofonod offsets (`0x10b8f4`, `0xe1e94`,
`0xe1e98`) are valid only for the specific ofono build above. The
script asserts the file size and the bytes at each offset before
patching — if either differs, it refuses rather than corrupt the
binary. If you hit that, either:

1. Pin UT to the build above by editing `SYSIMG_CHANNEL` in
   `installer/lib/common.sh` (rough — locks you out of UT updates), or
2. Re-derive the offsets against the new ofonod binary. The patch
   sites are:
   - **EHPLMN (cosmetic):** `simfs_op_check_structure_cb` xref to the
     "Requested file structure differs from SIM: %x" string. The b.ne
     that takes the error path. Replace with `nop`.
   - **PIN-auth (functional):** `sim_pin_query_cb` xref to the
     "Querying PIN authentication state failed" string. Find the
     `adrp x0, <string>` + `add x0, x0, <off>` pair at the error path
     entry. Replace those two instructions with `mov w23, #0` and `b
     <success-continuation>`. The success continuation is the
     immediately-following success-path label that loads
     `[x21, #0x24]` (sim->pin_type). See inline comments in
     `installer/05-fix-cellular.sh` for the full rationale.

The cleaner long-term fix is to land the same logic upstream in
`ofono-binder-plugin` (treat the QMI/binder INTERNAL_ERR response on
QueryPinAuthState as `pin_type=NONE` rather than propagating the
error). PRs welcome.

## Status

Tested end-to-end on a single BE2012 unit (T-Mobile US, Apple Silicon
host, macOS 26.2). Reproductions, issue reports, and PRs welcome.

## Support the work

If this installer saved you from buying another phone, kept your BE2012
out of a drawer, or unblocked a port you were stuck on — back the
ongoing [TeamIDE](https://teamide.dev) work at
[teamide.dev/support](https://teamide.dev/support). Sustains research
into the next variant, the next carrier-locked SKU, the next
ofono-on-Halium quirk.

Bug reports and pull requests for *this* repo go in
[GitHub issues](https://github.com/dcherrera/n100-be2012-crossflash/issues).

## Hire TeamIDE

Need work like this for your device, your fleet, your port? See
[HIRE.md](HIRE.md) for what we work on and engagement options, or
go straight to [teamide.dev/contact](https://teamide.dev/contact).
Browse our [products](https://teamide.dev/products) and
[portfolio](https://dcherrera-portfolio-main.teamide.dev/) for the
shape of what we ship.

---

<sub>A [TeamIDE](https://teamide.dev) project &nbsp;·&nbsp;
[Discord](https://discord.gg/YVcsHXSCYG) &nbsp;·&nbsp;
[Products](https://teamide.dev/products) &nbsp;·&nbsp;
[Portfolio](https://dcherrera-portfolio-main.teamide.dev/) &nbsp;·&nbsp;
[Contact](https://teamide.dev/contact) &nbsp;·&nbsp;
[Back it](https://teamide.dev/support) &nbsp;·&nbsp;
[Hire](HIRE.md) &nbsp;·&nbsp;
[GPL-2.0-or-later](LICENSE)</sub>
